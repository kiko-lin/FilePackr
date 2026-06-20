import XCTest
import ArchiveBrowser
@testable import FilePackr

/// Tests de la capa de app (el modelo `ArchiveDocument`). Son posibles gracias al item 4
/// de la auditoría: el modelo ya no depende del singleton `Localizer`, así que se puede
/// instanciar y ejercitar sin configurar i18n.
///
/// ⚠️ Requiere un **target de test unitario** en el proyecto (Xcode → File → New → Target →
/// Unit Testing Bundle, host = FilePackr). No se pudo crear desde fuera de Xcode sin
/// arriesgar el `.pbxproj` (objectVersion 77 + synchronized groups). Una vez creado el
/// target, este fichero se compila tal cual.
@MainActor
final class ArchiveDocumentTests: XCTestCase {

    private var temps: [URL] = []

    override func tearDown() {
        for url in temps { try? FileManager.default.removeItem(at: url) }
        temps = []
        super.tearDown()
    }

    /// Escribe `data` en un fichero con nombre **limpio** `name`, dentro de una carpeta
    /// temporal única (el UUID va en la carpeta, no en el nombre, para que el nodo
    /// importado conserve exactamente `name`).
    private func writeTemp(_ data: Data, _ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        temps.append(dir)
        return url
    }

    // MARK: - Apertura

    func testOpenZipBuildsTree() async throws {
        let zip = try ZipWriter().build([
            ZipEntryInput(path: "docs/a.txt", modifiedAt: nil, source: .data(Data("A".utf8))),
            ZipEntryInput(path: "docs/sub/b.txt", modifiedAt: nil, source: .data(Data("B".utf8))),
            ZipEntryInput(path: "c.txt", modifiedAt: nil, source: .data(Data("C".utf8))),
        ])
        let url = try writeTemp(zip, "tree.zip")

        let doc = ArchiveDocument()
        try await doc.openArchive(url)

        XCTAssertEqual(Set(doc.roots.map(\.name)), ["docs", "c.txt"])
        let docs = try XCTUnwrap(doc.roots.first { $0.name == "docs" })
        XCTAssertTrue(docs.isDirectory)
        XCTAssertEqual(Set(docs.children.map(\.name)), ["a.txt", "sub"])
        XCTAssertFalse(doc.hasUnsavedChanges)
    }

    /// Item 7: un fichero con extensión que no delata el formato se abre por su firma.
    func testOpenDetectsZipByMagicWhenExtensionUnknown() async throws {
        let zip = try ZipWriter().build([ZipEntryInput(path: "x.txt", modifiedAt: nil, source: .data(Data("x".utf8)))])
        let url = try writeTemp(zip, "archivo.bin")   // extensión no reconocible

        let doc = ArchiveDocument()
        try await doc.openArchive(url)
        XCTAssertEqual(doc.roots.map(\.name), ["x.txt"])
    }

    // MARK: - Edición (sin i18n: el nombre por defecto se inyecta)

    func testCreateFolderUsesInjectedName() {
        let doc = ArchiveDocument()
        doc.createFolder(defaultName: "Carpeta nueva")
        XCTAssertEqual(doc.roots.map(\.name), ["Carpeta nueva"])
        XCTAssertTrue(doc.hasUnsavedChanges)
    }

    func testRenameAndDelete() {
        let doc = ArchiveDocument()
        doc.createFolder(defaultName: "Tmp")
        let folder = try! XCTUnwrap(doc.roots.first)
        doc.rename(folder, to: "Definitivo")
        XCTAssertEqual(doc.roots.first?.name, "Definitivo")
        doc.delete(folder)
        XCTAssertTrue(doc.isEmpty)
    }

    // MARK: - Guardar y reabrir (round-trip a través del modelo)

    func testSaveThenReopenRoundTrip() async throws {
        let doc = ArchiveDocument()
        let file = try writeTemp(Data("contenido".utf8), "dato.txt")
        doc.addFiles([file])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        temps.append(out)
        try await doc.save(to: out, format: .zip, encryption: .none, password: nil)

        let reopened = ArchiveDocument()
        try await reopened.openArchive(out)
        XCTAssertEqual(reopened.roots.map(\.name), ["dato.txt"])
    }
}
