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

    private func index(_ tar: Data, chunkSize: Int) throws -> [ArchiveEntry] {
        let indexer = Tar.StreamIndexer()
        var i = tar.startIndex
        while i < tar.endIndex {
            let end = Swift.min(i + chunkSize, tar.endIndex)
            try indexer.consume(tar.subdata(in: i..<end))
            i = end
        }
        return try indexer.finish()
    }

    func testStreamIndexerMatchesListEntriesAcrossChunkSizes() throws {
        let tar = sampleTar()
        let expected = try Tar.listEntries(in: tar)
        XCTAssertFalse(expected.isEmpty)

        // Trozos no alineados a 512 a propósito (1, 7, 513…) para forzar cabeceras a caballo.
        for chunkSize in [1, 7, 100, 512, 513, 1024, 4096, tar.count] {
            let got = try index(tar, chunkSize: chunkSize)
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
        let entries = try index(tar, chunkSize: 7)
        let a = try XCTUnwrap(entries.first { $0.path == "a.txt" })
        XCTAssertEqual(try Tar.entryData(for: a, in: tar), Data("hola".utf8))
        let c = try XCTUnwrap(entries.first { $0.path == "c.txt" })
        XCTAssertEqual(try Tar.entryData(for: c, in: tar), Data("fin".utf8))
    }

    func testEmptyTarIndexesToNothing() throws {
        XCTAssertTrue(try index(Data(count: 1024), chunkSize: 512).isEmpty)   // dos bloques cero
    }

    // MARK: - Fase 2: extracción por offset (re-descomprimir + saltar + emitir)

    /// Round-trip completo sobre un `.tar.gz` real: indexar el flujo descomprimido (Fase 1) y
    /// extraer cada entrada por su offset re-descomprimiendo (Fase 2) debe dar el mismo contenido
    /// que `Tar.entryData` sobre el tar entero en RAM.
    func testStreamExtractMatchesEntryData() throws {
        let tar = sampleTar()
        let gz = Gzip.compress(tar)

        // Indexar el flujo descomprimido alimentando el indexer con Gzip.decompress (push).
        let indexer = Tar.StreamIndexer()
        try Gzip.decompress(gz) { try indexer.consume($0) }
        let entries = try indexer.finish()
        XCTAssertEqual(entries.map(\.path), try Tar.listEntries(in: tar).map(\.path))

        for e in entries {
            var out = Data()
            try Tar.streamExtract(offset: Int(try XCTUnwrap(e.dataOffset)), length: Int(e.uncompressedSize),
                                  decompressing: gz, with: { try Gzip.decompress($0, sink: $1) },
                                  sink: { out.append($0) })
            XCTAssertEqual(out, try Tar.entryData(for: e, in: tar), "contenido de \(e.path)")
        }
    }

    /// La extracción debe ser exacta también para una entrada grande no alineada a 512.
    func testStreamExtractExactBytesForOddSizedEntry() throws {
        let payload = Data((0..<5000).map { UInt8($0 % 251) })   // 5000 B, no múltiplo de 512
        let tar = Tar.write([
            Tar.WriteItem(path: "x", data: Data("antes".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "big.bin", data: payload, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "z", data: Data("despues".utf8), modifiedAt: nil, isDirectory: false),
        ])
        let gz = Gzip.compress(tar)
        let big = try XCTUnwrap(try Tar.listEntries(in: tar).first { $0.path == "big.bin" })

        var out = Data()
        try Tar.streamExtract(offset: Int(try XCTUnwrap(big.dataOffset)), length: Int(big.uncompressedSize),
                              decompressing: gz, with: { try Gzip.decompress($0, sink: $1) },
                              sink: { out.append($0) })
        XCTAssertEqual(out, payload)
    }

    // MARK: - Fase 3a: recorrido en un solo pase (iterador del motor)

    /// Extraer **todo** en un único pase debe dar el mismo contenido por entrada que `entryData`.
    func testStreamEntriesExtractsAllInOnePass() throws {
        let tar = sampleTar()
        let gz = Gzip.compress(tar)
        let expected = try Tar.listEntries(in: tar)

        var collected: [String: Data] = [:]
        try Tar.streamEntries(decompressing: gz, with: { try Gzip.decompress($0, sink: $1) }) { entry in
            guard !entry.isDirectory else { return nil }
            return { chunk in collected[entry.path, default: Data()].append(chunk) }
        }

        for e in expected where !e.isDirectory {
            XCTAssertEqual(collected[e.path] ?? Data(), try Tar.entryData(for: e, in: tar), "contenido de \(e.path)")
        }
        // No se materializan las carpetas como ficheros.
        XCTAssertFalse(collected.keys.contains("carpeta/"))
    }

    /// El iterador debe **saltar** las entradas no seleccionadas (devolver `nil`) y emitir solo
    /// las elegidas, en un único pase.
    func testStreamEntriesSkipsUnselected() throws {
        let tar = sampleTar()
        let gz = Gzip.compress(tar)
        let wanted: Set<String> = ["a.txt", "c.txt"]

        var collected: [String: Data] = [:]
        var visited: [String] = []
        try Tar.streamEntries(decompressing: gz, with: { try Gzip.decompress($0, sink: $1) }) { entry in
            visited.append(entry.path)
            guard wanted.contains(entry.path) else { return nil }
            return { chunk in collected[entry.path, default: Data()].append(chunk) }
        }

        XCTAssertEqual(Set(collected.keys), wanted)
        XCTAssertEqual(collected["a.txt"], Data("hola".utf8))
        XCTAssertEqual(collected["c.txt"], Data("fin".utf8))
        // Aunque se salten, todas las entradas se visitan (un solo pase ve el archivo entero).
        XCTAssertTrue(visited.contains("vacio.txt"))
    }
}
