import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Tests de `AddCoordinator`: la cola **síncrona** de "Añadir" (arrastre o botón) sobre el
/// árbol del documento, con su diálogo de conflicto de nombre (sobrescribir / conservar ambos
/// / cancelar) y el conteo de elementos omitidos por la política de ocultos/sistema.
@MainActor
final class AddCoordinatorTests: XCTestCase {

    private var temps: [URL] = []

    override func tearDown() {
        for url in temps { try? FileManager.default.removeItem(at: url) }
        temps = []
        super.tearDown()
    }

    /// Escribe un fichero con nombre **exacto** `name` en una carpeta temporal única (el UUID
    /// va en la carpeta, no en el nombre, para que el nodo importado conserve `name`).
    private func writeTemp(_ name: String, _ contents: String = "x") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        temps.append(dir)
        return url
    }

    // MARK: - Lote sin conflicto

    func testAddDistinctFilesSelectsThem() throws {
        let a = try writeTemp("a.txt")
        let b = try writeTemp("b.txt")
        let doc = ArchiveDocument()
        let coord = AddCoordinator()

        coord.start([a, b], into: nil, doc: doc)

        XCTAssertEqual(Set(doc.roots.map(\.name)), ["a.txt", "b.txt"])
        XCTAssertEqual(doc.selectedIDs, Set(doc.roots.map(\.id)))
        XCTAssertNil(coord.conflict)
    }

    // MARK: - Conflicto de nombre

    func testDuplicateNameTriggersConflict() throws {
        let doc = ArchiveDocument()
        let coord = AddCoordinator()
        coord.start([try writeTemp("dup.txt")], into: nil, doc: doc)

        coord.start([try writeTemp("dup.txt")], into: nil, doc: doc)
        XCTAssertEqual(coord.conflict?.name, "dup.txt")
    }

    func testOverwriteReplacesExisting() throws {
        let doc = ArchiveDocument()
        let coord = AddCoordinator()
        coord.start([try writeTemp("dup.txt", "viejo")], into: nil, doc: doc)
        let newURL = try writeTemp("dup.txt", "nuevo")
        coord.start([newURL], into: nil, doc: doc)

        let conflict = try XCTUnwrap(coord.conflict)
        coord.overwrite(conflict, doc: doc)

        XCTAssertNil(coord.conflict)
        XCTAssertEqual(doc.roots.map(\.name), ["dup.txt"])
        // El nodo resultante apunta al fichero nuevo (se reemplazó, no se conservó el viejo).
        if case .diskFile(let url) = try XCTUnwrap(doc.roots.first).source {
            XCTAssertEqual(url, newURL)
        } else { XCTFail("se esperaba un nodo de disco") }
    }

    func testKeepBothAddsUniqueName() throws {
        let doc = ArchiveDocument()
        let coord = AddCoordinator()
        coord.start([try writeTemp("dup.txt")], into: nil, doc: doc)
        coord.start([try writeTemp("dup.txt")], into: nil, doc: doc)

        let conflict = try XCTUnwrap(coord.conflict)
        coord.keepBoth(conflict, doc: doc)

        XCTAssertNil(coord.conflict)
        XCTAssertEqual(Set(doc.roots.map(\.name)), ["dup.txt", "dup 2.txt"])
    }

    func testCancelStopsRestOfBatch() throws {
        let doc = ArchiveDocument()
        let coord = AddCoordinator()
        coord.start([try writeTemp("dup.txt")], into: nil, doc: doc)
        // Lote: el primero choca (abre conflicto y pausa), el segundo queda pendiente en cola.
        coord.start([try writeTemp("dup.txt"), try writeTemp("after.txt")], into: nil, doc: doc)

        _ = try XCTUnwrap(coord.conflict)
        coord.cancel(doc: doc)

        XCTAssertNil(coord.conflict)
        XCTAssertFalse(doc.roots.contains { $0.name == "after.txt" }, "cancelar no procesa el resto")
    }

    // MARK: - Política de ocultos/sistema

    func testExcludedSystemFilesAreReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = dir.appendingPathComponent("carpeta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("visible.txt"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        temps.append(dir)

        let doc = ArchiveDocument()
        let coord = AddCoordinator()
        var reported = 0
        coord.start([folder], into: nil, doc: doc,
                    hiddenPolicy: .excludeSystemFiles, onFinish: { reported = $0 })

        XCTAssertEqual(reported, 1, "el .DS_Store debe contarse como omitido")
        let added = try XCTUnwrap(doc.roots.first)
        XCTAssertEqual(added.children.map(\.name), ["visible.txt"])
    }
}
