import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// `provideEntryPassword` valida la clave con la entrada cifrada más pequeña, en segundo plano.
/// Clave incorrecta → `false` y el documento sigue bloqueado; correcta → desbloquea.
@MainActor
final class EntryPasswordTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func encryptedZip(_ encryption: ZipEncryption) throws -> URL {
        let big = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let zip = try ZipWriter().build([
            ZipEntryInput(path: "grande.bin", modifiedAt: nil, source: .data(big)),
            ZipEntryInput(path: "nota.txt", modifiedAt: nil, source: .data(Data("hola".utf8))),
        ], encryption: encryption, password: "secreta")
        let url = tempDir.appendingPathComponent("cifrado.zip")
        try zip.write(to: url)
        return url
    }

    private func assertPasswordFlow(_ encryption: ZipEncryption) async throws {
        let doc = ArchiveDocument()
        try await doc.openArchive(encryptedZip(encryption))
        XCTAssertTrue(doc.requiresEntryPassword)

        let wrong = await doc.provideEntryPassword("mala")
        XCTAssertFalse(wrong)
        XCTAssertTrue(doc.requiresEntryPassword)

        let right = await doc.provideEntryPassword("secreta")
        XCTAssertTrue(right)
        XCTAssertFalse(doc.requiresEntryPassword)
    }

    func testZipCryptoPassword() async throws { try await assertPasswordFlow(.zipCrypto) }

    func testAES256Password() async throws { try await assertPasswordFlow(.aes256) }
}
