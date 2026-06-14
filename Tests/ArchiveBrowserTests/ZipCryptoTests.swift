import XCTest
@testable import ArchiveBrowser

/// Tests de ZipCrypto ("Débil"), incluyendo interoperabilidad con el `zip`/`unzip`
/// del sistema (Info-ZIP), que usan exactamente este cifrado clásico.
final class ZipCryptoTests: XCTestCase {

    private let writer = ZipWriter()
    private let reader = ZipReader()
    private let extractor = ZipExtractor()

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func run(_ path: String, _ args: [String], cwd: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    func testRoundTrip() throws {
        let payload = Data("ida y vuelta con ZipCrypto ñ áé".utf8)
        let zip = try writer.build([ZipEntryInput(path: "a.txt", modifiedAt: nil, source: .data(payload))],
                                   encryption: .zipCrypto, password: "clave")
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertFalse(entry.isAESEncrypted)
        XCTAssertEqual(try extractor.extractedData(for: entry, in: zip, password: "clave"), payload)
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: zip, password: "incorrecta"))
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: zip)) { error in
            XCTAssertEqual(error as? ExtractError, .needsPassword)
        }
    }

    func testReadsZipCryptoFromSystemZip() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plaintext = "contenido cifrado por el zip del sistema"
        try plaintext.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/zip", ["-q", "-P", "clave", "enc.zip", "f.txt"], cwd: dir)

        let archive = try Data(contentsOf: dir.appendingPathComponent("enc.zip"))
        let entry = try XCTUnwrap(try reader.listEntries(in: archive).first { $0.path == "f.txt" })
        XCTAssertTrue(entry.isEncrypted)
        let data = try extractor.extractedData(for: entry, in: archive, password: "clave")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), plaintext)
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: archive, password: "mala"))
    }

    func testSystemUnzipReadsOurZipCrypto() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip"))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(String(repeating: "datos cifrados FilePackr ", count: 40).utf8)
        let zip = try writer.build([ZipEntryInput(path: "doc.txt", modifiedAt: nil, source: .data(payload))],
                                   encryption: .zipCrypto, password: "secreta")
        let zipURL = dir.appendingPathComponent("out.zip")
        try zip.write(to: zipURL)

        let out = try run("/usr/bin/unzip", ["-P", "secreta", "-p", zipURL.path, "doc.txt"])
        XCTAssertEqual(out, payload, "el unzip del sistema debe descifrar nuestro ZipCrypto")
    }
}
