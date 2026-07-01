import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser
import FilePackrModel

/// Registro de FilePackr como aplicación por defecto en el Finder para los formatos que el
/// usuario marca en la pestaña Archivos de Ajustes (y en el aviso de primer arranque).
///
/// A diferencia de la versión anterior, aquí el estado es la **realidad del sistema** (quién
/// abre cada tipo según Launch Services), no una preferencia interna que pudiera divergir:
/// - `isDefault` consulta a macOS.
/// - `setAsDefault` reclama el tipo para FilePackr (macOS 26 pide confirmación al usuario).
/// - `clearDefault` **quita** la asignación devolviéndosela a otra app instalada que pueda
///   abrir el tipo (Utilidad de Archivo para los comunes). No hay API para "revertir" a un
///   estado anterior genérico; si ninguna otra app abre el tipo (7z/rar/…), no se puede quitar.
@MainActor
enum DefaultHandler {
    /// Reclama FilePackr como app por defecto para cada formato del conjunto.
    static func apply(_ formats: Set<ArchiveFormat>) {
        for format in formats { setAsDefault(format) }
    }

    /// ¿Es FilePackr, ahora mismo, la app por defecto del tipo en Launch Services?
    static func isDefault(_ format: ArchiveFormat) -> Bool {
        guard let type = utType(for: format),
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return current.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    /// Pone FilePackr como app por defecto del tipo. En macOS 26 esto dispara un aviso del
    /// sistema pidiendo confirmación; `completion` corre al terminar (aceptado o no) para que
    /// la vista relea el estado real.
    static func setAsDefault(_ format: ArchiveFormat, completion: (@MainActor () -> Void)? = nil) {
        guard let type = utType(for: format) else { completion?(); return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { error in
            if let error {
                NSLog("FilePackr: no se pudo asociar el formato \(format.rawValue): \(error.localizedDescription)")
            }
            if let completion { Task { @MainActor in completion() } }
        }
    }

    /// Quita FilePackr como predeterminado del tipo reasignándolo a la primera **otra** app
    /// instalada que sepa abrirlo. Si no hay ninguna (macOS no trae handler para 7z/rar/…),
    /// no hace nada: el tipo no se puede "dessignar". `completion` corre al terminar.
    static func clearDefault(_ format: ArchiveFormat, completion: (@MainActor () -> Void)? = nil) {
        guard let type = utType(for: format), let target = fallbackHandler(for: type) else {
            completion?()
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: target, toOpen: type) { error in
            if let error {
                NSLog("FilePackr: no se pudo reasignar el formato \(format.rawValue): \(error.localizedDescription)")
            }
            if let completion { Task { @MainActor in completion() } }
        }
    }

    /// ¿Se puede quitar la asignación de este formato? (existe otra app que lo abra).
    static func canClearDefault(_ format: ArchiveFormat) -> Bool {
        guard let type = utType(for: format) else { return false }
        return fallbackHandler(for: type) != nil
    }

    /// La primera app instalada **distinta de FilePackr** que puede abrir el tipo (Utilidad de
    /// Archivo para zip/tar/gz/…). `nil` si FilePackr es la única que lo abre.
    private static func fallbackHandler(for type: UTType) -> URL? {
        let mine = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
            .first { $0.resolvingSymlinksInPath() != mine }
    }

    /// `UTType` del formato: primero por el identificador declarado, con la extensión
    /// principal como último recurso.
    private static func utType(for format: ArchiveFormat) -> UTType? {
        UTType(format.contentTypeIdentifier) ?? UTType(filenameExtension: format.fileExtension)
    }
}
