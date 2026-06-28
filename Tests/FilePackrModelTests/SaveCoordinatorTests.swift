import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Tests de `SaveCoordinator`: el estado y la lógica del diálogo propio de Guardar/Exportar
/// (URL resuelta, validación del botón confirmar, prerrelleno según ajustes/documento) y el
/// encadenado de la acción pendiente tras un guardado con éxito. La escritura real (async) la
/// inyecta la vista con la closure `perform`, aquí sustituida por una falsa.
@MainActor
final class SaveCoordinatorTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3,
                           _ message: String = "condición no cumplida en el tiempo previsto",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - URL resuelta

    func testResolvedURLAddsExtension() {
        let coord = SaveCoordinator()
        coord.destination = URL(fileURLWithPath: "/tmp")
        coord.name = "out"
        coord.format = .zip
        XCTAssertEqual(coord.resolvedURL.lastPathComponent, "out.zip")
    }

    func testResolvedURLDoesNotDuplicateExtension() {
        let coord = SaveCoordinator()
        coord.destination = URL(fileURLWithPath: "/tmp")
        coord.name = "out.zip"
        coord.format = .zip
        XCTAssertEqual(coord.resolvedURL.lastPathComponent, "out.zip")
    }

    func testResolvedURLUsesCompoundExtension() {
        let coord = SaveCoordinator()
        coord.destination = URL(fileURLWithPath: "/tmp")
        coord.name = "out"
        coord.format = .tarGzip
        XCTAssertEqual(coord.resolvedURL.lastPathComponent, "out.tar.gz")
    }

    // MARK: - Validación

    func testNeedsPasswordWhenEncryptedAndEmpty() {
        let coord = SaveCoordinator()
        coord.format = .zip
        coord.encryption = .aes256
        coord.password = ""
        XCTAssertTrue(coord.needsPassword)
        coord.password = "secreto"
        XCTAssertFalse(coord.needsPassword)
    }

    func testNeedsPasswordFalseWithoutEncryption() {
        let coord = SaveCoordinator()
        coord.format = .zip
        coord.encryption = .none
        coord.password = ""
        XCTAssertFalse(coord.needsPassword)
    }

    func testCanConfirmRequiresNameAndPassword() {
        let coord = SaveCoordinator()
        coord.format = .zip
        coord.name = ""
        XCTAssertFalse(coord.canConfirm, "sin nombre no se puede confirmar")
        coord.name = "out"
        XCTAssertTrue(coord.canConfirm)
        coord.encryption = .aes256
        coord.password = ""
        XCTAssertFalse(coord.canConfirm, "cifrado sin contraseña no se puede confirmar")
    }

    // MARK: - Prerrelleno

    func testPrefillNewDocumentUsesSettingsDefault() {
        let settings = AppSettings.shared
        let saved = settings.defaultFormat
        defer { settings.defaultFormat = saved }
        settings.defaultFormat = .tar

        let coord = SaveCoordinator()
        coord.prefill(doc: ArchiveDocument(), settings: settings, baseName: "doc")
        XCTAssertEqual(coord.format, .tar)
        XCTAssertEqual(coord.name, "doc")
    }

    func testPrefillForcesZipForNonWritableFormat() {
        let settings = AppSettings.shared
        let saved = settings.defaultFormat
        defer { settings.defaultFormat = saved }
        settings.defaultFormat = .rar   // solo lectura → debe caer a zip

        let coord = SaveCoordinator()
        coord.prefill(doc: ArchiveDocument(), settings: settings, baseName: "doc")
        XCTAssertEqual(coord.format, .zip)
    }

    func testPrefillForcesZipForSingleFileFormatWhenNotSingleFile() {
        let settings = AppSettings.shared
        let saved = settings.defaultFormat
        defer { settings.defaultFormat = saved }
        settings.defaultFormat = .gzip   // solo-un-fichero, pero el doc no lo es → zip

        let coord = SaveCoordinator()
        coord.prefill(doc: ArchiveDocument(), settings: settings, baseName: "doc")
        XCTAssertEqual(coord.format, .zip)
    }

    // MARK: - Encadenado tras guardar

    func testConfirmSaveRunsPendingActionOnSuccess() async {
        let settings = AppSettings.shared
        let savedFmt = settings.lastUsedFormat, savedEnc = settings.lastUsedEncryption, savedLvl = settings.lastUsedLevel
        defer { settings.lastUsedFormat = savedFmt; settings.lastUsedEncryption = savedEnc; settings.lastUsedLevel = savedLvl }

        let coord = SaveCoordinator()
        coord.destination = URL(fileURLWithPath: "/tmp")
        coord.name = "out"
        coord.format = .zip
        coord.encryption = .none

        var performedExport: Bool?
        var afterCalled = false
        let perform: SaveCoordinator.Perform = { isExport, _, _, _, _, _, _ in
            performedExport = isExport; return true
        }
        coord.beginSave(then: { afterCalled = true })
        coord.confirm(settings: settings, perform: perform)

        await waitUntil { afterCalled }
        XCTAssertEqual(performedExport, false, "beginSave → no es exportación")
        XCTAssertTrue(afterCalled, "la acción pendiente se ejecuta tras guardar con éxito")
    }

    func testConfirmExportDoesNotRunPendingAction() async {
        let settings = AppSettings.shared
        let savedFmt = settings.lastUsedFormat, savedEnc = settings.lastUsedEncryption, savedLvl = settings.lastUsedLevel
        defer { settings.lastUsedFormat = savedFmt; settings.lastUsedEncryption = savedEnc; settings.lastUsedLevel = savedLvl }

        let coord = SaveCoordinator()
        coord.destination = URL(fileURLWithPath: "/tmp")
        coord.name = "out"
        coord.format = .zip

        var performedExport: Bool?
        let perform: SaveCoordinator.Perform = { isExport, _, _, _, _, _, _ in
            performedExport = isExport; return true
        }
        coord.beginExport()
        coord.confirm(settings: settings, perform: perform)

        await waitUntil { performedExport != nil }
        XCTAssertEqual(performedExport, true, "beginExport → es exportación")
    }

    func testConfirmDoesNotRunPendingActionOnFailure() async {
        let settings = AppSettings.shared
        let savedFmt = settings.lastUsedFormat, savedEnc = settings.lastUsedEncryption, savedLvl = settings.lastUsedLevel
        defer { settings.lastUsedFormat = savedFmt; settings.lastUsedEncryption = savedEnc; settings.lastUsedLevel = savedLvl }

        let coord = SaveCoordinator()
        coord.destination = URL(fileURLWithPath: "/tmp")
        coord.name = "out"
        coord.format = .zip

        var performCalled = false
        var afterCalled = false
        let perform: SaveCoordinator.Perform = { _, _, _, _, _, _, _ in
            performCalled = true; return false   // el guardado falla
        }
        coord.beginSave(then: { afterCalled = true })
        coord.confirm(settings: settings, perform: perform)

        await waitUntil { performCalled }
        // Da un margen para asegurar que la acción pendiente NO se dispara tras el fallo.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(afterCalled, "si el guardado falla, la acción pendiente no se ejecuta")
    }
}
