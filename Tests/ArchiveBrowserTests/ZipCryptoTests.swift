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

    func testAESRoundTrip() throws {
        let payload = Data(String(repeating: "datos AES-256 de prueba ", count: 60).utf8)
        let zip = try writer.build([ZipEntryInput(path: "secreto.txt", modifiedAt: nil, source: .data(payload))],
                                   encryption: .aes256, password: "claveFuerte")
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        XCTAssertTrue(entry.isAESEncrypted)
        XCTAssertEqual(entry.zip?.aesStrength, 3)              // AES-256
        XCTAssertEqual(entry.zip?.aesRealMethod, 8)            // deflate
        XCTAssertEqual(try extractor.extractedData(for: entry, in: zip, password: "claveFuerte"), payload)
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: zip, password: "mala")) { error in
            XCTAssertEqual(error as? ExtractError, .wrongPassword)
        }
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: zip)) { error in
            XCTAssertEqual(error as? ExtractError, .needsPassword)
        }
    }

    func testAESStoredUncompressible() throws {
        // Datos no comprimibles → método real 0 (almacenado), también cifrado AES.
        let payload = Data((0..<24).map { UInt8($0 &* 7 &+ 3) })
        let zip = try writer.build([ZipEntryInput(path: "r.bin", modifiedAt: nil, source: .data(payload))],
                                   encryption: .aes256, password: "k")
        let entry = try XCTUnwrap(try reader.listEntries(in: zip).first)
        XCTAssertEqual(try extractor.extractedData(for: entry, in: zip, password: "k"), payload)
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

    // MARK: - Interop AES-256 (WinZip) contra `pyzipper`

    private static let python = "/usr/bin/python3"

    /// Salta si no hay forma de verificar AES con una herramienta externa. `pyzipper`
    /// implementa el AES de WinZip (el mismo estándar que nuestro `ZipAES`).
    private func skipUnlessPyzipper() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.python), "python3 no disponible")
        let out = (try? run(Self.python, ["-c", "import pyzipper; print('ok')"])) ?? Data()
        try XCTSkipUnless(String(decoding: out, as: UTF8.self).contains("ok"),
            "Falta pyzipper para verificar la interop AES-256. Instala con `pip3 install pyzipper` y reejecuta `swift test`.")
    }

    /// Nuestro AES-256 debe poder abrirse desde otra implementación estándar (pyzipper).
    func testPyzipperReadsOurAES256() throws {
        try skipUnlessPyzipper()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(String(repeating: "AES-256 interop FilePackr ñ áé ", count: 50).utf8)
        let zip = try writer.build([ZipEntryInput(path: "secreto.txt", modifiedAt: nil, source: .data(payload))],
                                   encryption: .aes256, password: "claveFuerte")
        let zipURL = dir.appendingPathComponent("ours.zip"); try zip.write(to: zipURL)
        let outURL = dir.appendingPathComponent("out.bin")

        let script = """
        import pyzipper, sys
        with pyzipper.AESZipFile(sys.argv[1]) as zf:
            zf.setpassword(b'claveFuerte')
            data = zf.read('secreto.txt')
        open(sys.argv[2], 'wb').write(data)
        """
        _ = try run(Self.python, ["-c", script, zipURL.path, outURL.path])
        XCTAssertEqual(try Data(contentsOf: outURL), payload, "pyzipper debe descifrar nuestro AES-256")
    }

    /// El AES-256 escrito en **streaming** (entrada `.file`, sin cargar en memoria) debe
    /// poder abrirse desde pyzipper igual que la ruta en memoria.
    func testPyzipperReadsOurStreamedAES256() throws {
        try skipUnlessPyzipper()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(String(repeating: "AES-256 streaming interop ñ áé ", count: 5_000).utf8)
        let src = dir.appendingPathComponent("secreto.txt"); try payload.write(to: src)
        let zip = try writer.build([ZipEntryInput(path: "secreto.txt", modifiedAt: nil, source: .file(src))],
                                   encryption: .aes256, password: "claveFuerte")
        let zipURL = dir.appendingPathComponent("ours.zip"); try zip.write(to: zipURL)
        let outURL = dir.appendingPathComponent("out.bin")

        let script = """
        import pyzipper, sys
        with pyzipper.AESZipFile(sys.argv[1]) as zf:
            zf.setpassword(b'claveFuerte')
            data = zf.read('secreto.txt')
        open(sys.argv[2], 'wb').write(data)
        """
        _ = try run(Self.python, ["-c", script, zipURL.path, outURL.path])
        XCTAssertEqual(try Data(contentsOf: outURL), payload, "pyzipper debe descifrar nuestro AES-256 en streaming")
    }

    /// Debemos poder leer un AES-256 de WinZip producido por otra implementación.
    func testReadsAES256FromPyzipper() throws {
        try skipUnlessPyzipper()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(String(repeating: "datos cifrados por pyzipper ", count: 50).utf8)
        let plainURL = dir.appendingPathComponent("plain.bin"); try payload.write(to: plainURL)
        let zipURL = dir.appendingPathComponent("theirs.zip")

        let script = """
        import pyzipper, sys
        data = open(sys.argv[2], 'rb').read()
        with pyzipper.AESZipFile(sys.argv[1], 'w', compression=pyzipper.ZIP_DEFLATED, encryption=pyzipper.WZ_AES) as zf:
            zf.setpassword(b'claveFuerte')
            zf.writestr('doc.txt', data)
        """
        _ = try run(Self.python, ["-c", script, zipURL.path, plainURL.path])

        let archive = try Data(contentsOf: zipURL)
        let entry = try XCTUnwrap(try reader.listEntries(in: archive).first { $0.path == "doc.txt" })
        XCTAssertTrue(entry.isAESEncrypted)
        XCTAssertEqual(try extractor.extractedData(for: entry, in: archive, password: "claveFuerte"), payload,
                       "debemos descifrar el AES-256 de pyzipper")
        XCTAssertThrowsError(try extractor.extractedData(for: entry, in: archive, password: "mala"))
    }
}
