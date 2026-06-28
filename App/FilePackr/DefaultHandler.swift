import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser
import FilePackrModel

/// Registro de FilePackr como aplicación por defecto en el Finder para los formatos
/// que el usuario marca en la pestaña Archivos de Ajustes.
///
/// Limitación de macOS: no existe API para *liberar* un handler por defecto y
/// devolvérselo a la app anterior. Al **desmarcar** un formato solo se actualiza la
/// preferencia interna (`AppSettings.associatedFormats`); el usuario debe cambiar el
/// "Abrir con → Cambiar todos" desde el Finder si quiere otra app por defecto.
@MainActor
enum DefaultHandler {
    /// Registra FilePackr como app por defecto para cada formato del conjunto.
    static func apply(_ formats: Set<ArchiveFormat>) {
        for format in formats { setAsDefault(format) }
    }

    /// Intenta poner FilePackr como app por defecto del formato dado.
    static func setAsDefault(_ format: ArchiveFormat) {
        guard let type = utType(for: format) else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { error in
            if let error {
                NSLog("FilePackr: no se pudo asociar el formato \(format.rawValue): \(error.localizedDescription)")
            }
        }
    }

    /// `UTType` del formato: primero por el identificador declarado, con la extensión
    /// principal como último recurso.
    private static func utType(for format: ArchiveFormat) -> UTType? {
        UTType(format.contentTypeIdentifier) ?? UTType(filenameExtension: format.fileExtension)
    }
}
