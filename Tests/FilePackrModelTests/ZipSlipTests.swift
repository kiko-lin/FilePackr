import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Regresión de la vulnerabilidad **ZIP-Slip** (path traversal al extraer): una entrada con
/// componentes ".." escribiría fuera de la carpeta destino. Dos defensas:
///  1. `ArchiveTreeBuilder.build` no incorpora al árbol entradas con "..".
///  2. `ExportPlan.writeContents` rechaza cualquier destino que se salga de la raíz.
@MainActor
final class ZipSlipTests: XCTestCase {

    private func entry(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, compressedSize: 1, uncompressedSize: 1,
                     isDirectory: false, modificationDate: nil, isEncrypted: false)
    }

    // MARK: - Defensa 1: el árbol descarta entradas con ".."

    func testTreeBuilderDropsParentTraversalEntries() {
        let roots = ArchiveTreeBuilder.build(from: [
            entry("../../evil.txt"),         // escapa por completo
            entry("a/../../evil2.txt"),      // traversal interior
            entry("ok.txt"),                 // legítima
            entry("sub/fine.txt"),           // legítima
        ])

        // No hay ningún nodo ".." en ningún nivel.
        func names(_ nodes: [FileNode]) -> [String] {
            nodes.flatMap { [$0.name] + names($0.children) }
        }
        let all = names(roots)
        XCTAssertFalse(all.contains(".."), "ningún nodo debe llamarse \"..\"")
        // Solo sobreviven las entradas legítimas.
        XCTAssertEqual(Set(roots.map(\.name)), ["ok.txt", "sub"])
    }

    // MARK: - Defensa 2: writeContents bloquea un nombre que escapa

    func testWriteContentsBlocksEscapingChildName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Un fichero real de origen que un plan malicioso intentaría colocar fuera del destino.
        let source = base.appendingPathComponent("payload.txt")
        try Data("pwned".utf8).write(to: source)

        // Plan que, saltándose la 1ª defensa, mete un hijo llamado ".." → escaparía a `base`.
        let destination = base.appendingPathComponent("safe")   // raíz de extracción
        let escapeTarget = base.appendingPathComponent("pwned.txt")  // donde caería el "../"
        let malicious = ExportPlan(name: "safe", payload: .folder([
            ExportPlan(name: "..", payload: .folder([
                ExportPlan(name: "pwned.txt", payload: .diskFile(source)),
            ])),
        ]))

        XCTAssertThrowsError(try malicious.writeContents(to: destination)) { error in
            guard case ExportError.pathEscapesDestination("..") = error else {
                return XCTFail("se esperaba pathEscapesDestination(\"..\"), llegó \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget.path),
                       "no debe haberse escrito nada fuera de la carpeta destino")
    }

    // MARK: - Sin falsos positivos: la extracción legítima anidada sigue funcionando

    func testWriteContentsAllowsLegitimateNestedFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = base.appendingPathComponent("origen.txt")
        try Data("hola".utf8).write(to: source)

        let destination = base.appendingPathComponent("out")
        let plan = ExportPlan(name: "out", payload: .folder([
            ExportPlan(name: "sub", payload: .folder([
                ExportPlan(name: "fichero.txt", payload: .diskFile(source)),
            ])),
        ]))

        try plan.writeContents(to: destination)
        let written = destination.appendingPathComponent("sub/fichero.txt")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "hola")
    }
}
