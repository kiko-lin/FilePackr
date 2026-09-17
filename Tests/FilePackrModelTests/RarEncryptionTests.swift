import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// RAR cifrado vía unrar: el modelo ofrece el mismo flujo de contraseña que ZIP/7z. Con cabeceras
/// cifradas pide la clave **al abrir**; con solo los datos cifrados abre, marca las entradas como
/// bloqueadas y pide la clave **al extraer**. Clave real de los fixtures: "clave123".
@MainActor
final class RarEncryptionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Copia un fixture del bundle a un `.rar` real en disco (openArchive toma una URL).
    private func fixtureURL(_ name: String) throws -> URL {
        let src = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"),
            "falta el fixture \(name).rar")
        let dst = tempDir.appendingPathComponent("\(name).rar")
        try Data(contentsOf: src).write(to: dst)
        return dst
    }

    private func firstFile(in nodes: [FileNode]) -> FileNode? {
        for n in nodes {
            if n.isDirectory { if let f = firstFile(in: n.children) { return f } }
            else { return n }
        }
        return nil
    }

    // MARK: - Caso A: cabeceras cifradas → contraseña al ABRIR

    func testEncryptedHeadersAsksPasswordOnOpenAndDecrypts() async throws {
        let doc = ArchiveDocument()
        let url = try fixtureURL("enc-rar5-headers")
        try await doc.openArchive(url)
        XCTAssertTrue(doc.requiresOpenPassword)

        let wrong = await doc.provideOpenPassword("mala")
        XCTAssertFalse(wrong)
        let right = await doc.provideOpenPassword("clave123")
        XCTAssertTrue(right)
        XCTAssertFalse(doc.requiresOpenPassword)

        let node = try XCTUnwrap(firstFile(in: doc.roots) { $0.name == "hola.txt" })
        let dest = tempDir.appendingPathComponent("hola.txt")
        try await doc.performExtraction(of: doc.exportPlan(for: node), to: dest, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: dest), Data("Hola mundo rar".utf8))
    }

    // MARK: - Caso B: solo datos cifrados → abre y lista, contraseña al EXTRAER

    func testEncryptedDataAsksEntryPasswordAndExtracts() async throws {
        let doc = ArchiveDocument()
        let url = try fixtureURL("enc-rar5-data")
        try await doc.openArchive(url)
        XCTAssertTrue(doc.requiresEntryPassword)

        let wrong = await doc.provideEntryPassword("mala")
        XCTAssertFalse(wrong)
        let right = await doc.provideEntryPassword("clave123")
        XCTAssertTrue(right)

        let node = try XCTUnwrap(firstFile(in: doc.roots) { $0.name == "hola.txt" })
        let dest = tempDir.appendingPathComponent("hola.txt")
        try await doc.performExtraction(of: doc.exportPlan(for: node), to: dest, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: dest), Data("Hola mundo rar".utf8))
    }

    // MARK: - Control: un RAR SIN cifrar no se ve afectado por el mapeo

    func testUnencryptedRarOpensAndExtracts() async throws {
        let doc = ArchiveDocument()
        let url = try fixtureURL("comp-rar5")
        try await doc.openArchive(url)
        XCTAssertFalse(doc.roots.isEmpty)
        XCTAssertFalse(doc.requiresEntryPassword)

        let node = try XCTUnwrap(firstFile(in: doc.roots) { $0.name == "hola.txt" })
        let plan = doc.exportPlan(for: node)
        let dest = tempDir.appendingPathComponent("hola.txt")
        try await doc.performExtraction(of: plan, to: dest, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: dest), Data("Hola mundo rar".utf8))
    }
}

private extension RarEncryptionTests {
    /// Variante que busca el primer fichero que cumpla un predicado (para elegir "hola.txt").
    func firstFile(in nodes: [FileNode], where pred: (FileNode) -> Bool) -> FileNode? {
        for n in nodes {
            if n.isDirectory { if let f = firstFile(in: n.children, where: pred) { return f } }
            else if pred(n) { return n }
        }
        return nil
    }
}
