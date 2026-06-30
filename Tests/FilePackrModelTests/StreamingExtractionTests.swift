import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Fase 4: `ExportPlan.writeContents` extrae un plan completo (carpetas + entradas de un tar
/// comprimido) en **un solo recorrido** del archivo, colocando cada fichero en su destino con
/// la estructura de carpetas correcta y atomicidad por fichero. Aquí se valida el resultado a
/// disco; el invariante de "un solo pase" lo cubre `ArchiveCodecTests`.
final class StreamingExtractionTests: XCTestCase {

    private func makeTarGz() throws -> (container: Data, entries: [ArchiveEntry]) {
        let big = Data((0..<150_000).map { UInt8(($0 * 7) & 0xFF) })
        let tar = Tar.write([
            Tar.WriteItem(path: "raiz.txt", data: Data("raíz".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "sub/hoja.txt", data: Data("hoja".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "sub/grande.bin", data: big, modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tarGzip.codec.open(Gzip.compress(tar), fallbackName: "p")
        return (result.container, result.entries)
    }

    private func entry(_ entries: [ArchiveEntry], _ path: String) throws -> ArchiveEntry {
        try XCTUnwrap(entries.first { $0.path == path })
    }

    func testWriteContentsExtractsTreeFromCompressedTar() throws {
        let (container, entries) = try makeTarGz()
        func leaf(_ name: String, _ path: String) throws -> ExportPlan {
            ExportPlan(name: name, payload: .archiveEntry(
                entry: try entry(entries, path), archive: container, password: nil, format: .tarGzip))
        }
        let plan = ExportPlan(name: "root", payload: .folder([
            try leaf("raiz.txt", "raiz.txt"),
            ExportPlan(name: "sub", payload: .folder([
                try leaf("hoja.txt", "sub/hoja.txt"),
                try leaf("grande.bin", "sub/grande.bin"),
            ])),
        ]))

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePackrTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("root")
        try plan.writeContents(to: dest)

        let big = Data((0..<150_000).map { UInt8(($0 * 7) & 0xFF) })
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("raiz.txt")), Data("raíz".utf8))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("sub/hoja.txt")), Data("hoja".utf8))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("sub/grande.bin")), big)
    }

    /// La cancelación a mitad de un lote no deja ficheros a medias: el temporal en curso se
    /// descarta (los ya completados quedan; de esos se ocupa la limpieza de lote del modelo).
    func testWriteContentsCancellationDiscardsPartialFile() throws {
        let (container, entries) = try makeTarGz()
        let plan = ExportPlan(name: "f", payload: .archiveEntry(
            entry: try entry(entries, "sub/grande.bin"), archive: container, password: nil, format: .tarGzip))

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePackrTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("grande.bin")

        var seen = 0
        XCTAssertThrowsError(try plan.writeContents(to: dest, isCancelled: {
            seen += 1; return seen > 1   // cancela tras el primer trozo
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "un fichero cancelado a medias no debe quedar en el destino")
        // Ningún temporal residual en la carpeta.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".filepackr.tmp") }, "no debe quedar temporal")
    }
}
