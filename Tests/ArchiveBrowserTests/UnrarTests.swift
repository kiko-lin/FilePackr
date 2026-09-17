import XCTest
@testable import ArchiveBrowser

/// Motor `Unrar` (unrar de RARLAB vendorizado) contra los mismos fixtures RAR que
/// `LibArchiveFixtureTests`, más lo que libarchive no sabe hacer: **descifrar**.
final class UnrarTests: XCTestCase {

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "falta el fixture \(name).\(ext)")
    }

    private func extract(_ path: String, from url: URL, passphrase: String? = nil) throws -> Data {
        var out = Data()
        try Unrar.extractEntry(path: path, at: url, passphrase: passphrase) { out.append($0) }
        return out
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Sin cifrar

    func testRar4StoredListsAndExtracts() throws {
        let url = try fixtureURL("sample", "rar")
        let (entries, encrypted, truncated) = try Unrar.listEntries(at: url)
        XCTAssertFalse(encrypted)
        XCTAssertFalse(truncated)
        XCTAssertEqual(Set(entries.map(\.path)), ["hola.txt", "config.json"])
        XCTAssertEqual(entries.first { $0.path == "hola.txt" }?.uncompressedSize, 14)
        XCTAssertEqual(try extract("hola.txt", from: url), Data("Hola mundo rar".utf8))
        XCTAssertEqual(try extract("config.json", from: url), Data(#"{"clave":"valor"}"#.utf8))
    }

    func testRar5CompressedListsAndExtracts() throws {
        let url = try fixtureURL("comp-rar5", "rar")
        let (entries, encrypted, _) = try Unrar.listEntries(at: url)
        XCTAssertFalse(encrypted)
        XCTAssertEqual(Set(entries.map(\.path)), ["hola.txt", "config.json", "anidado.txt", "repetido.txt"])
        XCTAssertNotNil(entries.first { $0.path == "hola.txt" }?.modificationDate)
        XCTAssertEqual(try extract("repetido.txt", from: url), Data(String(repeating: "ABCD", count: 5000).utf8))
    }

    func testExtractEntriesSinglePassReportsSkips() throws {
        let url = try fixtureURL("comp-rar5", "rar")
        let (entries, _, _) = try Unrar.listEntries(at: url)
        let target = try XCTUnwrap(entries.last { !$0.isDirectory })
        let expectedSkipped = entries.filter { $0.path != target.path }.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }

        var skipped: Int64 = 0
        var extracted = Data()
        try Unrar.extractEntries([target.path], at: url, onSkip: { skipped += $0 }) { _ in { extracted.append($0) } }
        XCTAssertEqual(extracted.count, Int(target.uncompressedSize))
        XCTAssertEqual(skipped, expectedSkipped)
    }

    func testMissingEntryThrows() throws {
        let url = try fixtureURL("sample", "rar")
        XCTAssertThrowsError(try extract("no-existe.txt", from: url)) {
            XCTAssertEqual($0 as? UnrarError, .entryNotFound(path: "no-existe.txt"))
        }
    }

    /// Un error lanzado por el sink (p. ej. cancelación) aborta unrar y sale tal cual.
    func testSinkErrorPropagates() throws {
        struct Stop: Error {}
        let url = try fixtureURL("comp-rar5", "rar")
        XCTAssertThrowsError(try Unrar.extractEntry(path: "repetido.txt", at: url) { _ in throw Stop() }) {
            XCTAssertTrue($0 is Stop, "esperado Stop, no \($0)")
        }
        // El motor sigue usable después.
        XCTAssertEqual(try extract("hola.txt", from: url), Data("Hola mundo rar".utf8))
    }

    func testNonRarFailsToOpen() throws {
        let url = tempDir.appendingPathComponent("falso.rar")
        try Data(repeating: 0x41, count: 100).write(to: url)
        XCTAssertThrowsError(try Unrar.listEntries(at: url)) { XCTAssertEqual($0 as? UnrarError, .openFailed) }
    }

    // MARK: - Cifrado (clave real "clave123")

    func testEncryptedHeadersNeedPassword() throws {
        let url = try fixtureURL("enc-rar5-headers", "rar")
        XCTAssertThrowsError(try Unrar.listEntries(at: url)) { XCTAssertEqual($0 as? UnrarError, .passphraseRequired) }
        XCTAssertThrowsError(try Unrar.listEntries(at: url, passphrase: "mala")) { XCTAssertEqual($0 as? UnrarError, .wrongPassword) }
    }

    func testEncryptedHeadersDecryptWithCorrectPassword() throws {
        let url = try fixtureURL("enc-rar5-headers", "rar")
        let (entries, encrypted, _) = try Unrar.listEntries(at: url, passphrase: "clave123")
        XCTAssertTrue(encrypted)
        XCTAssertTrue(entries.contains { $0.path == "hola.txt" })
        XCTAssertEqual(try extract("hola.txt", from: url, passphrase: "clave123"), Data("Hola mundo rar".utf8))
    }

    /// Solo datos cifrados: lista sin clave y **marca** las entradas cifradas (libarchive no).
    func testEncryptedDataListsAndMarksEncrypted() throws {
        let url = try fixtureURL("enc-rar5-data", "rar")
        let (entries, encrypted, _) = try Unrar.listEntries(at: url)
        XCTAssertTrue(encrypted)
        XCTAssertEqual(entries.first { $0.path == "hola.txt" }?.isEncrypted, true)
    }

    func testEncryptedDataExtraction() throws {
        let url = try fixtureURL("enc-rar5-data", "rar")
        XCTAssertThrowsError(try extract("hola.txt", from: url)) { XCTAssertEqual($0 as? UnrarError, .passphraseRequired) }
        XCTAssertThrowsError(try extract("hola.txt", from: url, passphrase: "mala")) { XCTAssertEqual($0 as? UnrarError, .wrongPassword) }
        XCTAssertEqual(try extract("hola.txt", from: url, passphrase: "clave123"), Data("Hola mundo rar".utf8))
    }

    // MARK: - Multivolumen nativo (unrar encuentra solo los siguientes volúmenes)

    func testVolumesListFromFirstPart() throws {
        let url = try fixtureURL("volumes.part1", "rar")
        let (entries, _, truncated) = try Unrar.listEntries(at: url)
        XCTAssertFalse(truncated)
        XCTAssertEqual(Set(entries.map(\.path)), ["partido.txt", "entero.txt"])
        XCTAssertEqual(entries.first { $0.path == "partido.txt" }?.uncompressedSize, 61)
    }

    func testVolumesExtractAcrossBoundary() throws {
        let url = try fixtureURL("volumes.part1", "rar")
        XCTAssertEqual(try extract("partido.txt", from: url),
                       Data("Contenido partido entre dos volumenes RAR nativos, de verdad.".utf8))
        XCTAssertEqual(try extract("entero.txt", from: url),
                       Data("Este fichero vive entero en el segundo volumen.".utf8))
    }

    func testVolumesLegacyNaming() throws {
        let url = try fixtureURL("volumes", "rar")
        let (entries, _, _) = try Unrar.listEntries(at: url)
        XCTAssertEqual(Set(entries.map(\.path)), ["partido.txt", "entero.txt"])
    }

    /// Falta el segundo volumen: se devuelve lo leído, marcado `truncated`.
    func testVolumesMissingPartIsTruncated() throws {
        let part1 = tempDir.appendingPathComponent("solo.part1.rar")
        try FileManager.default.copyItem(at: fixtureURL("volumes.part1", "rar"), to: part1)
        let (entries, _, truncated) = try Unrar.listEntries(at: part1)
        XCTAssertTrue(truncated)
        XCTAssertEqual(entries.map(\.path), ["partido.txt"])
    }
}
