import XCTest
@testable import ArchiveBrowser

/// Tests del motor de escritura/extracción de ZIP.
final class ZipEngineTests: XCTestCase {

    private let writer = ZipWriter()
    private let reader = ZipReader()
    private let extractor = ZipExtractor()

    private func sampleURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "zip", subdirectory: "Fixtures"))
    }

    func testCreateReadAndExtractRoundTrip() throws {
        // Texto largo para forzar que DEFLATE sí comprima.
        let texto = Data(String(repeating: "contenido repetido ", count: 100).utf8)
        let binario = Data((0..<32).map { UInt8($0) })

        let zip = writer.build([
            .file(path: "nota.txt", data: texto),
            .directory(path: "datos/"),
            .file(path: "datos/raw.bin", data: binario),
        ])

        let entries = try reader.listEntries(in: zip)
        let paths = Set(entries.map(\.path))
        XCTAssertEqual(paths, ["nota.txt", "datos/", "datos/raw.bin"])

        let nota = try XCTUnwrap(entries.first { $0.path == "nota.txt" })
        XCTAssertEqual(nota.compressionMethod, 8, "el texto repetido debe comprimirse con deflate")
        XCTAssertEqual(try extractor.extractedData(for: nota, in: zip), texto)

        let raw = try XCTUnwrap(entries.first { $0.path == "datos/raw.bin" })
        XCTAssertEqual(try extractor.extractedData(for: raw, in: zip), binario)
    }

    func testCrcMatchesAfterRoundTrip() throws {
        let data = Data("verificación de integridad".utf8)
        let zip = writer.build([.file(path: "x.txt", data: data)])
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        XCTAssertEqual(entry.crc32, CRC32.checksum(data))
    }

    func testExtractFromExternalZip() throws {
        let archive = try Data(contentsOf: sampleURL())
        let entries = try reader.listEntries(in: archive)

        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(try extractor.extractedData(for: hola, in: archive), Data("Hola mundo cifrado".utf8))
    }

    func testCopyRawEntryIntoNewZip() throws {
        // Abrimos un zip externo, copiamos una entrada SIN recomprimir a otro zip,
        // y comprobamos que el contenido se conserva.
        let archive = try Data(contentsOf: sampleURL())
        let entries = try reader.listEntries(in: archive)
        let source = try XCTUnwrap(entries.first { $0.path == "docs/anidado.txt" })

        let rawBytes = try extractor.rawCompressedData(for: source, in: archive)
        let rebuilt = writer.build([
            .rawEntry(path: source.path, method: source.compressionMethod,
                      crc32: source.crc32, compressed: rawBytes,
                      uncompressedSize: source.uncompressedSize)
        ])

        let copied = try XCTUnwrap(try reader.listEntries(in: rebuilt).first)
        XCTAssertEqual(copied.path, "docs/anidado.txt")
        XCTAssertEqual(try extractor.extractedData(for: copied, in: rebuilt),
                       try extractor.extractedData(for: source, in: archive))
    }
}
