import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// La libarchive del sistema **no descifra RAR** (verificado: ni con la clave correcta; ver
/// `docs/fixtures/`). Estos tests fijan la UX que el modelo ofrece ante un RAR cifrado: en vez de
/// pedir una contraseña que nunca funcionará (bucle sin salida) o fallar con "contraseña
/// incorrecta", se lanza `ArchiveDocumentError.encryptionUnsupported`, que la vista traduce a un
/// mensaje claro. Un RAR **sin** cifrar debe seguir abriéndose y extrayéndose con normalidad.
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

    // MARK: - Caso A: cabeceras cifradas → falla al ABRIR (sin pedir contraseña)

    func testEncryptedHeadersThrowsUnsupportedOnOpen() async throws {
        let doc = ArchiveDocument()
        let url = try fixtureURL("enc-rar5-headers")
        do {
            try await doc.openArchive(url)
            XCTFail("debería lanzar encryptionUnsupported")
        } catch ArchiveDocumentError.encryptionUnsupported(let fmt) {
            XCTAssertEqual(fmt, .rar)
        }
        // No debe quedar pidiendo contraseña de apertura (evita el bucle sin salida).
        XCTAssertFalse(doc.requiresOpenPassword)
    }

    // MARK: - Caso B: solo datos cifrados → abre y lista, falla al EXTRAER

    func testEncryptedDataThrowsUnsupportedOnExtract() async throws {
        let doc = ArchiveDocument()
        let url = try fixtureURL("enc-rar5-data")
        // Se abre sin señal de cifrado (libarchive no lo marca) → no pide contraseña.
        try await doc.openArchive(url)
        XCTAssertFalse(doc.requiresEntryPassword)
        let node = try XCTUnwrap(firstFile(in: doc.roots))

        let plan = doc.exportPlan(for: node)
        let dest = tempDir.appendingPathComponent(node.name)
        do {
            try await doc.performExtraction(of: plan, to: dest, overwrite: true)
            XCTFail("debería lanzar encryptionUnsupported")
        } catch ArchiveDocumentError.encryptionUnsupported(let fmt) {
            XCTAssertEqual(fmt, .rar)
        }
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
