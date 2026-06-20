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

    private func dataInput(_ path: String, _ data: Data, date: Date? = nil) -> ZipEntryInput {
        ZipEntryInput(path: path, modifiedAt: date, source: .data(data))
    }
    private func dirInput(_ path: String) -> ZipEntryInput {
        ZipEntryInput(path: path, modifiedAt: nil, source: .directory)
    }

    func testCreateReadAndExtractRoundTrip() throws {
        let texto = Data(String(repeating: "contenido repetido ", count: 100).utf8)
        let binario = Data((0..<32).map { UInt8($0) })

        let zip = try writer.build([
            dataInput("nota.txt", texto),
            dirInput("datos/"),
            dataInput("datos/raw.bin", binario),
        ])

        let entries = try reader.listEntries(in: zip)
        XCTAssertEqual(Set(entries.map(\.path)), ["nota.txt", "datos/", "datos/raw.bin"])

        let nota = try XCTUnwrap(entries.first { $0.path == "nota.txt" })
        XCTAssertEqual(nota.zip?.compressionMethod, 8, "el texto repetido debe comprimirse con deflate")
        XCTAssertEqual(try extractor.extractedData(for: nota, in: zip), texto)

        let raw = try XCTUnwrap(entries.first { $0.path == "datos/raw.bin" })
        XCTAssertEqual(try extractor.extractedData(for: raw, in: zip), binario)
    }

    func testCrcMatchesAfterRoundTrip() throws {
        let data = Data("verificación de integridad".utf8)
        let zip = try writer.build([dataInput("x.txt", data)])
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        XCTAssertEqual(entry.zip?.crc32, CRC32.checksum(data))
    }

    func testWritesAndReadsBackModificationDate() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-1)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reference)
        let zip = try writer.build([dataInput("f.txt", Data("x".utf8), date: reference)])
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        let read = try XCTUnwrap(entry.modificationDate)
        let readComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: read)
        XCTAssertEqual(components, readComponents, "la fecha debe sobrevivir al guardar y releer")
    }

    func testExtractFromExternalZip() throws {
        let archive = try Data(contentsOf: sampleURL())
        let entries = try reader.listEntries(in: archive)
        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(try extractor.extractedData(for: hola, in: archive), Data("Hola mundo cifrado".utf8))
    }

    func testReadsZip64Archive() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zip64", withExtension: "zip", subdirectory: "Fixtures"))
        let archive = try Data(contentsOf: url)
        let entries = try reader.listEntries(in: archive)

        let big = try XCTUnwrap(entries.first { $0.path == "grande.txt" })
        XCTAssertEqual(big.uncompressedSize, 520)
        XCTAssertNotEqual(big.compressedSize, 0xFFFF_FFFF)
        XCTAssertEqual(try extractor.extractedData(for: big, in: archive).count, 520)
        XCTAssertTrue(entries.contains { $0.path == "docs/normal.txt" })
    }

    func testCopyRawEntryIntoNewZip() throws {
        let archive = try Data(contentsOf: sampleURL())
        let entries = try reader.listEntries(in: archive)
        let source = try XCTUnwrap(entries.first { $0.path == "docs/anidado.txt" })

        let rawBytes = try extractor.rawCompressedData(for: source, in: archive)
        let rebuilt = try writer.build([
            ZipEntryInput(path: source.path, modifiedAt: source.modificationDate,
                          source: .rawEntry(method: source.zip!.compressionMethod, crc32: source.zip!.crc32,
                                            compressed: rawBytes, uncompressedSize: source.uncompressedSize))
        ])

        let copied = try XCTUnwrap(try reader.listEntries(in: rebuilt).first)
        XCTAssertEqual(copied.path, "docs/anidado.txt")
        XCTAssertEqual(try extractor.extractedData(for: copied, in: rebuilt),
                       try extractor.extractedData(for: source, in: archive))
    }

    // MARK: - Streaming y ZIP64 (escritura)

    func testFileSourceIsReadAndCompressed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(String(repeating: "hola ", count: 300).utf8)
        let file = dir.appendingPathComponent("src.txt")
        try payload.write(to: file)

        let zip = try writer.build([ZipEntryInput(path: "src.txt", modifiedAt: nil, source: .file(file))])
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        XCTAssertEqual(try extractor.extractedData(for: entry, in: zip), payload)
    }

    func testStreamingWriteMatchesBuild() throws {
        let inputs = [
            dataInput("a.txt", Data(String(repeating: "x", count: 500).utf8)),
            dirInput("dir/"),
            dataInput("dir/b.bin", Data((0..<200).map { UInt8($0 & 0xFF) })),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try writer.write(inputs, to: handle)
        try handle.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data, try writer.build(inputs), "streaming y build deben producir bytes idénticos")
        let a = try XCTUnwrap(try reader.listEntries(in: data).first { $0.path == "a.txt" })
        XCTAssertEqual(try extractor.extractedData(for: a, in: data).count, 500)
    }

    func testWritesZip64ForManyEntries() throws {
        // >65535 entradas obliga a emitir el registro ZIP64 EOCD.
        let inputs = (0..<70_000).map { ZipEntryInput(path: "f\($0).txt", modifiedAt: nil, source: .data(Data())) }
        let zip = try writer.build(inputs)
        let entries = try reader.listEntries(in: zip)
        XCTAssertEqual(entries.count, 70_000, "el EOCD ZIP64 permite leer >65535 entradas")
        XCTAssertEqual(entries.last?.path, "f69999.txt")
    }
}
