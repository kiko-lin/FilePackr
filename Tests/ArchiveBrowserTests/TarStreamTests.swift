import XCTest
@testable import ArchiveBrowser

/// Fase 1 del streaming de tar comprimido (`docs/diseno-streaming-tar.md`): el indexador
/// incremental `Tar.StreamIndexer` debe producir **las mismas entradas** que `Tar.listEntries`
/// (que tiene el tar entero en RAM), con cualquier troceado de los chunks del flujo.
final class TarStreamTests: XCTestCase {

    private func sampleTar() -> Data {
        let longName = "carpeta/" + String(repeating: "n", count: 160) + ".txt"   // > 100 → PAX
        return Tar.write([
            Tar.WriteItem(path: "a.txt", data: Data("hola".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "carpeta/", data: Data(), modifiedAt: nil, isDirectory: true),
            Tar.WriteItem(path: "carpeta/b.bin", data: Data(count: 1000), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "vacio.txt", data: Data(), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: longName, data: Data("largo".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "c.txt", data: Data("fin".utf8), modifiedAt: nil, isDirectory: false),
        ])
    }

    private func index(_ tar: Data, chunkSize: Int) -> [ArchiveEntry] {
        let indexer = Tar.StreamIndexer()
        var i = tar.startIndex
        while i < tar.endIndex {
            let end = Swift.min(i + chunkSize, tar.endIndex)
            indexer.consume(tar.subdata(in: i..<end))
            i = end
        }
        return indexer.finish()
    }

    func testStreamIndexerMatchesListEntriesAcrossChunkSizes() throws {
        let tar = sampleTar()
        let expected = try Tar.listEntries(in: tar)
        XCTAssertFalse(expected.isEmpty)

        // Trozos no alineados a 512 a propósito (1, 7, 513…) para forzar cabeceras a caballo.
        for chunkSize in [1, 7, 100, 512, 513, 1024, 4096, tar.count] {
            let got = index(tar, chunkSize: chunkSize)
            XCTAssertEqual(got.map(\.path), expected.map(\.path), "paths con chunk \(chunkSize)")
            XCTAssertEqual(got.map(\.uncompressedSize), expected.map(\.uncompressedSize), "sizes con chunk \(chunkSize)")
            XCTAssertEqual(got.map(\.dataOffset), expected.map(\.dataOffset), "offsets con chunk \(chunkSize)")
            XCTAssertEqual(got.map(\.isDirectory), expected.map(\.isDirectory), "isDir con chunk \(chunkSize)")
        }
    }

    /// El `dataOffset` indexado en streaming debe permitir recuperar el contenido correcto
    /// del tar (mismo resultado que `Tar.entryData`, que usa el mismo offset sobre el tar en RAM).
    func testStreamIndexerOffsetsLocateContent() throws {
        let tar = sampleTar()
        let entries = index(tar, chunkSize: 7)
        let a = try XCTUnwrap(entries.first { $0.path == "a.txt" })
        XCTAssertEqual(try Tar.entryData(for: a, in: tar), Data("hola".utf8))
        let c = try XCTUnwrap(entries.first { $0.path == "c.txt" })
        XCTAssertEqual(try Tar.entryData(for: c, in: tar), Data("fin".utf8))
    }

    func testEmptyTarIndexesToNothing() {
        XCTAssertTrue(index(Data(count: 1024), chunkSize: 512).isEmpty)   // dos bloques cero
    }
}
