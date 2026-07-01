import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Guarda de la decisión de alcance (2026-07-01): FilePackr solo se ofrece como app por
/// defecto de los formatos que puede **crear** (editables), nunca de los de solo lectura.
@MainActor
final class DefaultAssociationTests: XCTestCase {

    func testDefaultAssociatedFormatsAreExactlyTheWritableOnes() {
        XCTAssertEqual(
            AppSettings.defaultAssociatedFormats,
            Set(ArchiveFormat.allCases.filter(\.isWritable))
        )
    }

    func testDefaultAssociatedFormatsExcludeReadOnlyFormats() {
        for readOnly in [ArchiveFormat.rar, .cpio, .lha, .cab] {
            XCTAssertFalse(
                AppSettings.defaultAssociatedFormats.contains(readOnly),
                "\(readOnly) es de solo lectura; no debe reclamarse como app por defecto"
            )
        }
    }

    func testDefaultAssociatedFormatsIncludeRepresentativeEditableFormats() {
        for writable in [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip, .gzip, .xz, .bzip2, .xar] {
            XCTAssertTrue(
                AppSettings.defaultAssociatedFormats.contains(writable),
                "\(writable) es editable; debe estar en el conjunto por defecto"
            )
        }
    }

    /// Instalación nueva (UserDefaults vacío): sin asociaciones hasta que el usuario acepte
    /// el primer arranque o marque formatos. Las casillas de Ajustes reflejan la realidad.
    func testFreshInstallHasNoAssociationsUntilOptIn() {
        let suite = "test.defaultAssociation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.associatedFormats.isEmpty)
    }
}
