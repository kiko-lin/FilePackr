import XCTest
@testable import ArchiveBrowser

/// Tests de la compresión en **streaming** (memoria constante): CRC incremental,
/// runner de `compression_stream` y las variantes fichero→fichero de gz/xz/bz2.
final class StreamingCompressionTests: XCTestCase {

    // MARK: - Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Datos mixtos (texto compresible + bloque pseudoaleatorio incompresible) de
    /// tamaño suficiente para cruzar varios trozos del streaming (64 KB).
    private func sampleData(_ size: Int) -> Data {
        var d = Data(capacity: size)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let line = Data("FilePackr streaming compression test line — repetible y compresible.\n".utf8)
        while d.count < size {
            if d.count % 3 == 0 {
                d.append(line)
            } else {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                withUnsafeBytes(of: seed.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d.prefix(size)
    }

    // MARK: - CRC32 incremental

    func testCRC32AccumulatorMatchesOneShot() {
        let data = sampleData(200_000)
        let oneShot = CRC32.checksum(data)

        var acc = CRC32.Accumulator()
        var i = 0
        while i < data.count {
            let n = min(7919, data.count - i)   // trozos de tamaño irregular
            acc.update(data.subdata(in: i..<(i + n)))
            i += n
        }
        XCTAssertEqual(acc.final, oneShot)
    }

    func testCRC32AccumulatorEmpty() {
        var acc = CRC32.Accumulator()
        acc.update(Data())
        XCTAssertEqual(acc.final, CRC32.checksum(Data()))
    }

    // MARK: - Streaming fichero→fichero (gz/xz/bz2)

    /// Escribe `data` a un fichero, lo comprime en streaming con `compress` y devuelve
    /// el resultado comprimido leído de disco.
    private func streamCompress(_ data: Data,
                                _ compress: (FileHandle, FileHandle) throws -> Void) throws -> Data {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.bin")
        let dst = dir.appendingPathComponent("out.bin")
        try data.write(to: src)
        FileManager.default.createFile(atPath: dst.path, contents: nil)

        let inH = try FileHandle(forReadingFrom: src)
        let outH = try FileHandle(forWritingTo: dst)
        try compress(inH, outH)
        try inH.close()
        try outH.close()
        return try Data(contentsOf: dst)
    }

    func testGzipStreamingRoundTrip() throws {
        for size in [0, 100, 200_000] {
            let data = sampleData(size)
            let gz = try streamCompress(data) { try Gzip.compress(from: $0, to: $1, filename: "in.bin") }
            XCTAssertEqual(try Gzip.decompress(gz), data, "tamaño \(size)")
            XCTAssertEqual(Gzip.storedFilename(gz), "in.bin")
        }
    }

    func testXzStreamingRoundTrip() throws {
        for size in [0, 100, 200_000] {
            let data = sampleData(size)
            let xz = try streamCompress(data) { try Xz.compress(from: $0, to: $1) }
            XCTAssertEqual(try Xz.decompress(xz), data, "tamaño \(size)")
        }
    }

    func testBzip2StreamingRoundTrip() throws {
        for size in [0, 100, 200_000] {
            let data = sampleData(size)
            let bz = try streamCompress(data) { try Bzip2.compress(from: $0, to: $1) }
            XCTAssertEqual(try Bzip2.decompress(bz), data, "tamaño \(size)")
        }
    }

    // MARK: - ZIP en streaming desde fichero de disco (Etapa B)

    func testZipStreamedFileRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(300_000)   // cruza varios trozos de 64 KB
        let file = dir.appendingPathComponent("big.bin")
        try payload.write(to: file)

        let zip = try ZipWriter().build([
            ZipEntryInput(path: "big.bin", modifiedAt: nil, source: .file(file)),
            ZipEntryInput(path: "dir/", modifiedAt: nil, source: .directory),
            ZipEntryInput(path: "dir/mem.txt", modifiedAt: nil, source: .data(Data("en memoria".utf8))),
        ])

        let reader = ZipReader()
        let extractor = ZipExtractor()
        let entries = try reader.listEntries(in: zip)

        let big = try XCTUnwrap(entries.first { $0.path == "big.bin" })
        XCTAssertEqual((big.zip?.flags ?? 0) & 0x0008, 0x0008, "la entrada en streaming usa descriptor de datos")
        XCTAssertEqual(big.zip?.compressionMethod, 8)
        XCTAssertEqual(big.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(big.zip?.crc32, CRC32.checksum(payload))
        XCTAssertEqual(try extractor.extractedData(for: big, in: zip), payload)

        let mem = try XCTUnwrap(entries.first { $0.path == "dir/mem.txt" })
        XCTAssertEqual(try extractor.extractedData(for: mem, in: zip), Data("en memoria".utf8))
    }

    // MARK: - TAR en streaming (Hueco 1)

    /// Acumula en un `Data` lo que produzca `produce` por su `sink` (para los compresores
    /// de núcleo pull).
    private func collect(_ produce: (_ sink: (Data) throws -> Void) throws -> Void) rethrows -> Data {
        var out = Data(); try produce { out.append($0) }; return out
    }

    /// Ítems de prueba: una carpeta, un fichero de disco grande (cruza trozos) y un fichero
    /// en memoria. Crea el fichero grande en `dir`.
    private func tarItems(in dir: URL, payload: Data) throws -> [Tar.WriteItem] {
        let file = dir.appendingPathComponent("big.bin")
        try payload.write(to: file)
        return [
            Tar.WriteItem(path: "dir/", data: Data(), modifiedAt: nil, isDirectory: true),
            Tar.WriteItem(path: "dir/big.bin", fileURL: file, modifiedAt: nil),
            Tar.WriteItem(path: "mem.txt", data: Data("en memoria".utf8), modifiedAt: nil, isDirectory: false),
        ]
    }

    private func assertTarContents(_ tar: Data, payload: Data) throws {
        let entries = try Tar.listEntries(in: tar)
        let big = try XCTUnwrap(entries.first { $0.path == "dir/big.bin" })
        XCTAssertEqual(big.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(try Tar.entryData(for: big, in: tar), payload)
        let mem = try XCTUnwrap(entries.first { $0.path == "mem.txt" })
        XCTAssertEqual(try Tar.entryData(for: mem, in: tar), Data("en memoria".utf8))
    }

    func testTarStreamingFromDiskFile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(300_000)
        try assertTarContents(Tar.write(try tarItems(in: dir, payload: payload)), payload: payload)
    }

    func testTarGzipStreamingRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(300_000)
        let items = try tarItems(in: dir, payload: payload)
        let gz = try collect { sink in try Gzip.compress(next: Tar.reader(items), sink: sink, filename: "a.tar") }
        try assertTarContents(try Gzip.decompress(gz), payload: payload)
    }

    func testTarXzStreamingRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(300_000)
        let items = try tarItems(in: dir, payload: payload)
        let xz = try collect { sink in try Xz.compress(next: Tar.reader(items), sink: sink) }
        try assertTarContents(try Xz.decompress(xz), payload: payload)
    }

    func testTarBzip2StreamingRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(300_000)
        let items = try tarItems(in: dir, payload: payload)
        let bz = try collect { sink in try Bzip2.compress(next: Tar.reader(items), sink: sink) }
        try assertTarContents(try Bzip2.decompress(bz), payload: payload)
    }

    /// Interop: el `tar` del sistema debe leer nuestro TAR escrito en streaming.
    func testTarStreamingReadBySystemTar() throws {
        let tarTool = "/usr/bin/tar"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tarTool), "sin tar del sistema")
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(250_000)
        let items = try tarItems(in: dir, payload: payload)

        let tarURL = dir.appendingPathComponent("out.tar")
        try Tar.write(items).write(to: tarURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tarTool)
        p.arguments = ["-xOf", tarURL.path, "dir/big.bin"]   // -O: a stdout
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run()
        let extracted = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(extracted, payload)
    }

    // MARK: - ZIP cifrado en streaming (Etapa C)

    /// Comprime `payload` en streaming como única entrada `.file` cifrada y la devuelve.
    private func streamedEncryptedZip(_ payload: Data, encryption: ZipEncryption,
                                      password: String) throws -> Data {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secreto.bin")
        try payload.write(to: file)
        return try ZipWriter().build([ZipEntryInput(path: "secreto.bin", modifiedAt: nil, source: .file(file))],
                                     encryption: encryption, password: password)
    }

    func testZipStreamedFileWithZipCrypto() throws {
        let payload = sampleData(250_000)
        let zip = try streamedEncryptedZip(payload, encryption: .zipCrypto, password: "secreto")

        let entry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertFalse(entry.isAESEncrypted)
        let extractor = ZipExtractor()
        XCTAssertEqual(try extractor.extractedData(for: entry, in: zip, password: "secreto"), payload)
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: zip, password: "malo")) {
            XCTAssertEqual($0 as? ExtractError, .wrongPassword)
        }
    }

    func testZipStreamedFileWithAES256() throws {
        let payload = sampleData(250_000)
        let zip = try streamedEncryptedZip(payload, encryption: .aes256, password: "secreto")

        let entry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertTrue(entry.isAESEncrypted)
        XCTAssertEqual(entry.zip?.crc32, 0, "AE-2 pone CRC = 0")
        let extractor = ZipExtractor()
        XCTAssertEqual(try extractor.extractedData(for: entry, in: zip, password: "secreto"), payload)
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: zip, password: "malo")) {
            XCTAssertEqual($0 as? ExtractError, .wrongPassword)
        }
    }

    // MARK: - Descompresión / extracción en streaming (Hueco 2)

    func testGzipXzBzip2DecompressToSink() throws {
        let payload = sampleData(300_000)
        XCTAssertEqual(try collect { try Gzip.decompress(Gzip.compress(payload), sink: $0) }, payload)
        XCTAssertEqual(try collect { try Xz.decompress(Xz.compress(payload), sink: $0) }, payload)
        XCTAssertEqual(try collect { try Bzip2.decompress(Bzip2.compress(payload), sink: $0) }, payload)
    }

    /// Extracción ZIP en streaming (sin cifrar) = mismos bytes que `extractedData`.
    func testZipExtractStreamingUnencrypted() throws {
        let payload = sampleData(300_000)
        let zip = try ZipWriter().build([ZipEntryInput(path: "f.bin", modifiedAt: nil, source: .data(payload))])
        let entry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertEqual(try collect { try ZipExtractor().extract(entry, in: zip, sink: $0) }, payload)
    }

    func testZipExtractStreamingZipCrypto() throws {
        let payload = sampleData(200_000)
        let zip = try ZipWriter().build([ZipEntryInput(path: "f.bin", modifiedAt: nil, source: .data(payload))],
                                        encryption: .zipCrypto, password: "clave")
        let entry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertEqual(try collect { try ZipExtractor().extract(entry, in: zip, password: "clave", sink: $0) }, payload)
        XCTAssertThrowsError(try collect { try ZipExtractor().extract(entry, in: zip, password: "mala", sink: $0) })
    }

    func testZipExtractStreamingAES256() throws {
        let payload = sampleData(200_000)
        let zip = try ZipWriter().build([ZipEntryInput(path: "f.bin", modifiedAt: nil, source: .data(payload))],
                                        encryption: .aes256, password: "clave")
        let entry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertEqual(try collect { try ZipExtractor().extract(entry, in: zip, password: "clave", sink: $0) }, payload)
        XCTAssertThrowsError(try collect { try ZipExtractor().extract(entry, in: zip, password: "mala", sink: $0) }) {
            XCTAssertEqual($0 as? ExtractError, .wrongPassword)
        }
    }

    /// Interop: el `unzip` del sistema debe leer y extraer una entrada escrita en streaming.
    func testZipStreamedFileReadBySystemUnzip() throws {
        let unzip = "/usr/bin/unzip"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: unzip), "sin unzip del sistema")

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = sampleData(250_000)
        let file = dir.appendingPathComponent("data.bin")
        try payload.write(to: file)

        let zipURL = dir.appendingPathComponent("out.zip")
        FileManager.default.createFile(atPath: zipURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipURL)
        try ZipWriter().write([ZipEntryInput(path: "data.bin", modifiedAt: nil, source: .file(file))], to: handle)
        try handle.close()

        // unzip -p extrae a stdout sin recomprimir; comparamos con el original.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: unzip)
        p.arguments = ["-p", zipURL.path, "data.bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let extracted = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "unzip debe terminar sin error")
        XCTAssertEqual(extracted, payload)
    }
}
