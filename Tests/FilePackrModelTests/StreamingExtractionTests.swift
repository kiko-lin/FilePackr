import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Fase 4: `ExportPlan.writeContents` extrae un plan completo (carpetas + entradas de un tar
/// comprimido) en **un solo recorrido** del archivo, colocando cada fichero en su destino con
/// la estructura de carpetas correcta y atomicidad por fichero. Aquí se valida el resultado a
/// disco; el invariante de "un solo pase" lo cubre `ArchiveCodecTests`.
final class StreamingExtractionTests: XCTestCase {

    private func makeTarGz() throws -> (container: ArchiveContainer, entries: [ArchiveEntry]) {
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

    /// Cancelar **a mitad del segundo fichero** de un lote que va por un solo pase (`streamEntries`):
    /// el primero, ya comprometido al empezar el segundo, debe quedar íntegro; el segundo no debe
    /// aparecer (su temporal se descarta) y no debe quedar ningún `.filepackr.tmp`.
    func testWriteContentsCancellationMidBatchKeepsCompletedDiscardsCurrent() throws {
        let a = Data(repeating: 0x41, count: 200_000)
        let b = Data(repeating: 0x42, count: 200_000)
        let tar = Tar.write([
            Tar.WriteItem(path: "a.bin", data: a, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "b.bin", data: b, modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tarGzip.codec.open(Gzip.compress(tar), fallbackName: "p")
        func leaf(_ name: String) throws -> ExportPlan {
            ExportPlan(name: name, payload: .archiveEntry(
                entry: try entry(result.entries, name), archive: result.container, password: nil, format: .tarGzip))
        }
        let plan = ExportPlan(name: "root", payload: .folder([try leaf("a.bin"), try leaf("b.bin")]))

        let base = tempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("root")

        var written = 0
        XCTAssertThrowsError(try plan.writeContents(to: dest,
            onProgress: { _, bytes in written += Int(bytes) },
            isCancelled: { written > a.count + 1000 }))   // ya dentro de b.bin

        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("a.bin")), a, "el 1º debe quedar íntegro")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("b.bin").path),
                       "el 2º cancelado a medias no debe aparecer")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasSuffix(".filepackr.tmp") }, "no debe quedar temporal")
    }

    /// Una entrada de **fichero vacío** (0 bytes) en un lote debe crearse como fichero vacío: el
    /// writer se abre, no recibe trozos y se confirma igualmente.
    func testWriteContentsCreatesEmptyFileEntry() throws {
        let tar = Tar.write([
            Tar.WriteItem(path: "vacio.txt", data: Data(), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "lleno.txt", data: Data("hola".utf8), modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tarGzip.codec.open(Gzip.compress(tar), fallbackName: "p")
        func leaf(_ name: String) throws -> ExportPlan {
            ExportPlan(name: name, payload: .archiveEntry(
                entry: try entry(result.entries, name), archive: result.container, password: nil, format: .tarGzip))
        }
        let plan = ExportPlan(name: "root", payload: .folder([try leaf("vacio.txt"), try leaf("lleno.txt")]))

        let base = tempDir(); defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("root")
        try plan.writeContents(to: dest)

        let vacio = dest.appendingPathComponent("vacio.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vacio.path), "el fichero vacío debe crearse")
        XCTAssertEqual(try Data(contentsOf: vacio), Data())
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("lleno.txt")), Data("hola".utf8))
    }

    /// `writeContents` sobre un archivo libarchive (RAR/7z…) del que solo se pide **una** entrada
    /// debe reportar por `onSkip` el tamaño de las demás: ese recorrido secuencial (sin acceso
    /// aleatorio) tiene coste real aunque no escriba nada, y sin la señal la barra de progreso del
    /// llamador se queda congelada durante todo ese tramo (bug real: arrastrar un solo fichero
    /// fuera de un RAR grande).
    func testWriteContentsReportsSkippedBytesForLibArchivePartialExtraction() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lote.7z")
        let a = Data(repeating: 0x41, count: 30_000)
        let b = Data(repeating: 0x42, count: 40_000)
        try LibArchive.write([
            .init(path: "a.bin", data: a, modifiedAt: nil, isDirectory: false),
            .init(path: "b.bin", data: b, modifiedAt: nil, isDirectory: false),
            .init(path: "c.txt", data: Data("solo esta se pide".utf8), modifiedAt: nil, isDirectory: false),
        ], to: url)
        let result = try ArchiveFormat.sevenZip.codec.open(try Data(contentsOf: url), fallbackName: "lote")

        let plan = ExportPlan(name: "c.txt", payload: .archiveEntry(
            entry: try entry(result.entries, "c.txt"), archive: result.container, password: nil, format: .sevenZip))

        var skipped: Int64 = 0
        let dest = dir.appendingPathComponent("c.txt")
        try plan.writeContents(to: dest, onSkip: { skipped += $0 })

        XCTAssertEqual(try Data(contentsOf: dest), Data("solo esta se pide".utf8))
        XCTAssertEqual(skipped, Int64(a.count) + Int64(b.count), "debe saltar a.bin y b.bin, no pedidas")
    }

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePackrTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
