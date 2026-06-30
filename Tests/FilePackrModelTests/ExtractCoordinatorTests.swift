import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Tests de `ExtractCoordinator`: la cola de extracción en lote y, sobre todo, la
/// resolución de conflictos de nombre (donde apareció un bug real detectado en GUI:
/// "conservar ambos" robaba el nombre literal de otro elemento aún pendiente del lote).
///
/// La extracción real (async, toca disco) la inyecta la vista con la closure `perform`;
/// aquí se sustituye por una falsa que registra `(nombre, destino, sobrescribir)` y
/// devuelve éxito/fallo. Así se ejercita la lógica de cola/conflicto sin descomprimir
/// nada. La cola avanza en `Task`s del `@MainActor`, por eso se espera con `waitUntil`.
@MainActor
final class ExtractCoordinatorTests: XCTestCase {

    private var tempDir: URL!
    /// Ajustes aislados (UserDefaults propio): los tests no tocan el estado global de la app.
    private var settings: AppSettings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "test.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults().removePersistentDomain(forName: suiteName)
        tempDir = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Un plan de fichero (el origen no importa: el `perform` de los tests es falso y no lo lee).
    private func plan(_ name: String) -> ExportPlan {
        ExportPlan(name: name, payload: .diskFile(URL(fileURLWithPath: "/dev/null")))
    }

    /// Crea un fichero real en el destino para simular una colisión "ya existe en disco".
    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent(name).path, contents: Data())
    }

    /// Espera (cediendo el hilo) a que se cumpla una condición; falla por timeout.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3,
                           _ message: String = "condición no cumplida en el tiempo previsto",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 2_000_000)   // 2 ms
        }
    }

    /// Un coordinador con destino fijado a `tempDir` (sin pasar por `prepareDestination`).
    private func makeCoordinator() -> ExtractCoordinator {
        let coord = ExtractCoordinator()
        coord.destination = tempDir
        return coord
    }

    // MARK: - Cola sin conflictos

    func testDistinctNamesExtractToTheirOwnDestinations() async {
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var calls: [(name: String, dest: URL, overwrite: Bool)] = []
        let perform: ExtractCoordinator.Perform = { plan, dest, overwrite in
            calls.append((plan.name, dest, overwrite)); return true
        }

        coord.begin(title: "t") { [self.plan("a.txt"), self.plan("b.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)

        await waitUntil { calls.count == 2 }
        XCTAssertEqual(Set(calls.map { $0.dest.lastPathComponent }), ["a.txt", "b.txt"])
        XCTAssertTrue(calls.allSatisfy { !$0.overwrite })
        XCTAssertNil(coord.conflict)
    }

    // MARK: - Conflicto por duplicado dentro del propio lote (sin tocar disco)

    /// Dos elementos con el mismo nombre: el segundo choca con el primero **ya reservado**
    /// en el lote, aunque su nombre aún no esté en disco (set `claimed`).
    func testDuplicateNameInBatchTriggersConflict() async {
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var calls: [(name: String, dest: URL, overwrite: Bool)] = []
        let perform: ExtractCoordinator.Perform = { plan, dest, overwrite in
            calls.append((plan.name, dest, overwrite)); return true
        }

        coord.begin(title: "t") { [self.plan("dup.txt"), self.plan("dup.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)

        await waitUntil { coord.conflict != nil }
        XCTAssertEqual(coord.conflict?.destination.lastPathComponent, "dup.txt")
        XCTAssertEqual(calls.count, 1, "solo el primero se extrajo antes del conflicto")
    }

    // MARK: - Resolución de conflictos

    func testKeepBothOnDiskCollisionPicksFreeName() async {
        touch("file.txt")   // ya existe en disco
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var calls: [(name: String, dest: URL, overwrite: Bool)] = []
        let perform: ExtractCoordinator.Perform = { plan, dest, overwrite in
            calls.append((plan.name, dest, overwrite)); return true
        }

        coord.begin(title: "t") { [self.plan("file.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)

        await waitUntil { coord.conflict != nil }
        coord.resolveConflict(coord.conflict!, overwrite: false, doc: doc, perform: perform)

        await waitUntil { calls.count == 1 }
        XCTAssertEqual(calls[0].dest.lastPathComponent, "file 2.txt")
        XCTAssertFalse(calls[0].overwrite)
    }

    func testOverwriteKeepsSameDestination() async {
        touch("file.txt")
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var calls: [(name: String, dest: URL, overwrite: Bool)] = []
        let perform: ExtractCoordinator.Perform = { plan, dest, overwrite in
            calls.append((plan.name, dest, overwrite)); return true
        }

        coord.begin(title: "t") { [self.plan("file.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)

        await waitUntil { coord.conflict != nil }
        coord.resolveConflict(coord.conflict!, overwrite: true, doc: doc, perform: perform)

        await waitUntil { calls.count == 1 }
        XCTAssertEqual(calls[0].dest.lastPathComponent, "file.txt")
        XCTAssertTrue(calls[0].overwrite)
    }

    /// Regresión del bug detectado en GUI: al "conservar ambos" para un duplicado, el nombre
    /// libre alternativo no debe robar el nombre **literal** de otro elemento aún pendiente
    /// del lote. Con ["foto.jpg", "foto.jpg", "foto 2.jpg"]: el 2.º conserva-ambos debe ir a
    /// "foto 3.jpg" (no a "foto 2.jpg", que le pertenece al 3.º), y el 3.º conserva "foto 2.jpg".
    func testKeepBothDoesNotStealPendingLiteralName() async {
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var calls: [(name: String, dest: URL, overwrite: Bool)] = []
        let perform: ExtractCoordinator.Perform = { plan, dest, overwrite in
            calls.append((plan.name, dest, overwrite)); return true
        }

        coord.begin(title: "t") {
            [self.plan("foto.jpg"), self.plan("foto.jpg"), self.plan("foto 2.jpg")]
        }
        coord.confirm(doc: doc, settings: settings, perform: perform)

        // El 1.º se extrae sin conflicto; el 2.º (mismo nombre) abre conflicto.
        await waitUntil { coord.conflict != nil }
        coord.resolveConflict(coord.conflict!, overwrite: false, doc: doc, perform: perform)

        await waitUntil { calls.count == 3 }
        let dests = calls.map { $0.dest.lastPathComponent }
        XCTAssertEqual(Set(dests), ["foto.jpg", "foto 2.jpg", "foto 3.jpg"],
                       "cada elemento debe acabar en un destino único")
        XCTAssertEqual(Set(dests).count, 3, "ningún elemento comparte destino")
        XCTAssertTrue(dests.contains("foto 2.jpg"),
                      "el elemento que se llama literalmente 'foto 2.jpg' conserva su nombre")
    }

    // MARK: - Cancelación

    /// Cancelar desde el diálogo de conflicto vacía la cola y devuelve las rutas ya extraídas
    /// (para ofrecer conservar/eliminar). El elemento del conflicto no cuenta como extraído.
    func testCancelConflictReturnsAlreadyExtractedURLs() async {
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var calls: [(name: String, dest: URL, overwrite: Bool)] = []
        let perform: ExtractCoordinator.Perform = { plan, dest, overwrite in
            calls.append((plan.name, dest, overwrite)); return true
        }

        coord.begin(title: "t") { [self.plan("done.txt"), self.plan("done.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)

        await waitUntil { coord.conflict != nil }   // 1.º extraído, 2.º en conflicto
        let extracted = coord.cancelConflict()

        XCTAssertEqual(extracted.map { $0.lastPathComponent }, ["done.txt"])
        XCTAssertNil(coord.conflict)
    }

    /// Regresión: tras un lote completado con éxito no debe quedar estado residual. Si no,
    /// cancelar después otra operación (arrastre/guardado) mostraría "Conservar/Eliminar" sobre
    /// ficheros de un lote anterior ya extraído.
    func testNoResidualStateAfterSuccessfulBatch() async {
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        var done = 0
        let perform: ExtractCoordinator.Perform = { _, _, _ in done += 1; return true }

        coord.begin(title: "t") { [self.plan("a.txt"), self.plan("b.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)
        await waitUntil { done == 2 }
        try? await Task.sleep(nanoseconds: 20_000_000)   // margen para el processNext de cierre

        XCTAssertTrue(coord.cancelBatch().isEmpty, "no debe quedar nada que limpiar tras el éxito")
    }

    // MARK: - Destino por defecto según ajustes

    func testPrepareDestinationUsesFixedFolder() {
        settings.extractMode = .fixedFolder
        settings.fixedExtractFolder = tempDir
        let coord = ExtractCoordinator()
        coord.prepareDestination(doc: ArchiveDocument(), settings: settings)
        XCTAssertEqual(coord.destination, tempDir)
    }

    func testConfirmRecordsLastUsedFolder() async {
        let coord = makeCoordinator()
        let doc = ArchiveDocument()
        let perform: ExtractCoordinator.Perform = { _, _, _ in true }
        coord.begin(title: "t") { [self.plan("x.txt")] }
        coord.confirm(doc: doc, settings: settings, perform: perform)
        await waitUntil { self.settings.lastUsedExtractFolder == self.tempDir }
        XCTAssertEqual(settings.lastUsedExtractFolder, tempDir)
    }
}
