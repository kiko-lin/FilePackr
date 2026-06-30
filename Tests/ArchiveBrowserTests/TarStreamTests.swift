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

    // MARK: - Sparse no soportado (§10 #3): detectar y fallar limpio, nunca emitir basura

    /// GNU sparse antiguo (tipo `'S'`=`0x53` en el byte 156 de la cabecera): tanto `listEntries`
    /// como el `StreamIndexer` deben lanzar `.unsupportedSparse` en vez de saltarse la entrada en
    /// silencio (y arriesgar a desincronizar el avance del resto del tar).
    func testRejectsOldGnuSparse() throws {
        var tar = Tar.write([Tar.WriteItem(path: "huecos.bin", data: Data("xy".utf8), modifiedAt: nil, isDirectory: false)])
        tar[tar.startIndex + 156] = 0x53   // marcar la primera cabecera como GNU sparse antiguo

        XCTAssertThrowsError(try Tar.listEntries(in: tar)) {
            XCTAssertEqual($0 as? TarError, .unsupportedSparse)
        }
        XCTAssertThrowsError(try index(tar, chunkSize: 512)) {
            XCTAssertEqual($0 as? TarError, .unsupportedSparse)
        }
    }

    /// Sparse PAX (GNU 0.0/0.1/1.0): la cabecera extendida `x` lleva claves `GNU.sparse.*`. Debe
    /// rechazarse igual, por las dos rutas de lectura.
    func testRejectsPaxSparse() throws {
        let record = paxRecord("GNU.sparse.major=1")
        var tar = tarHeader(name: "huecos.bin", size: record.count, type: 0x78)   // 'x' PAX
        tar.append(record)
        tar.append(Data(count: (512 - record.count % 512) % 512))                 // padding del payload
        tar.append(Data(count: 1024))                                             // dos bloques cero = fin

        XCTAssertThrowsError(try Tar.listEntries(in: tar)) {
            XCTAssertEqual($0 as? TarError, .unsupportedSparse)
        }
        XCTAssertThrowsError(try index(tar, chunkSize: 7)) {
            XCTAssertEqual($0 as? TarError, .unsupportedSparse)
        }
    }

    // Constructores de bloques tar crudos (la escritura del motor no genera sparse).
    private func tarHeader(name: String, size: Int, type: UInt8) -> Data {
        var b = [UInt8](repeating: 0, count: 512)
        for (i, c) in name.utf8.prefix(100).enumerated() { b[i] = c }
        let octal = String(size, radix: 8)                                         // tamaño octal en 124 (11 + NUL)
        for (i, c) in (String(repeating: "0", count: max(0, 11 - octal.count)) + octal).utf8.enumerated() { b[124 + i] = c }
        b[156] = type
        for (i, c) in "ustar".utf8.enumerated() { b[257 + i] = c }                 // firma ustar
        return Data(b)
    }

    /// Registro PAX `"<len> key=value\n"`, donde `len` incluye su propia longitud (punto fijo).
    private func paxRecord(_ kv: String) -> Data {
        let body = " " + kv + "\n"
        var total = body.utf8.count + 1
        while total != body.utf8.count + String(total).utf8.count {
            total = body.utf8.count + String(total).utf8.count
        }
        return Data((String(total) + body).utf8)
    }
}
