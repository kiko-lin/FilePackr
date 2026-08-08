import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Cierra el círculo del bug reportado: abrir un `.rar` que es la primera parte de un
/// conjunto **multivolumen nativo** (creado por WinRAR/`rar`, no por FilePackr) debía fallar
/// con "No se pudo leer el archivo." porque `VolumeStore` solo reconocía el esquema propio
/// (`nombre_001.ext`). Ahora `ArchiveDocument.openArchive` detecta también los esquemas nativos
/// de RAR (`RarVolumes`) y los abre vía `archive_read_open_filenames`.
@MainActor
final class RarVolumesDocumentTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Copia ambos volúmenes del fixture al mismo directorio temporal con los nombres dados
    /// (`openArchive` busca los "hermanos" junto al fichero que se abre) y devuelve la URL
    /// del primero.
    private func copyVolumes(vol1Name: String, vol2Name: String) throws -> URL {
        func copy(_ resource: String, ext: String, to name: String) throws -> URL {
            let src = try XCTUnwrap(
                Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures"),
                "falta el fixture \(resource).\(ext)")
            let dst = tempDir.appendingPathComponent(name)
            try Data(contentsOf: src).write(to: dst)
            return dst
        }
        let v1 = try copy("volumes.part1", ext: "rar", to: vol1Name)
        _ = try copy("volumes.part2", ext: "rar", to: vol2Name)
        return v1
    }

    private func firstFile(in nodes: [FileNode], where pred: (FileNode) -> Bool = { _ in true }) -> FileNode? {
        for n in nodes {
            if n.isDirectory { if let f = firstFile(in: n.children, where: pred) { return f } }
            else if pred(n) { return n }
        }
        return nil
    }

    func testOpensModernNamedVolumeSet() async throws {
        let url = try copyVolumes(vol1Name: "pelicula.part1.rar", vol2Name: "pelicula.part2.rar")
        let doc = ArchiveDocument()
        try await doc.openArchive(url)

        XCTAssertEqual(doc.format, .rar)
        XCTAssertEqual(Set(doc.roots.map(\.name)), ["partido.txt", "entero.txt"])
        // El documento toma el nombre de la PRIMERA parte, como con el esquema propio.
        XCTAssertEqual(doc.documentName, "pelicula.part1.rar")
    }

    func testOpensLegacyNamedVolumeSet() async throws {
        let url = try copyVolumes(vol1Name: "informe.rar", vol2Name: "informe.r00")
        let doc = ArchiveDocument()
        try await doc.openArchive(url)

        XCTAssertEqual(doc.format, .rar)
        XCTAssertEqual(Set(doc.roots.map(\.name)), ["partido.txt", "entero.txt"])
    }

    /// El camino real de "Extraer"/"Extraer todo"/arrastrar al Finder (`ExportPlan.writeContents`
    /// → `LibArchiveCodec.extractAll`) también debe funcionar, incluida la entrada que cruza el
    /// límite de volumen — es el que fallaba en el bug original (no solo listar).
    func testExtractsAcrossVolumeBoundary() async throws {
        let url = try copyVolumes(vol1Name: "x.part1.rar", vol2Name: "x.part2.rar")
        let doc = ArchiveDocument()
        try await doc.openArchive(url)

        let partido = try XCTUnwrap(firstFile(in: doc.roots) { $0.name == "partido.txt" })
        let plan = doc.exportPlan(for: partido)
        let dest = tempDir.appendingPathComponent("salida.txt")
        try await doc.performExtraction(of: plan, to: dest, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: dest),
                       Data("Contenido partido entre dos volumenes RAR nativos, de verdad.".utf8))
    }
}
