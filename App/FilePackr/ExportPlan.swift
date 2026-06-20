import Foundation
import ArchiveBrowser

/// Instantánea inmutable y `Sendable` de un nodo para poder extraerlo en segundo
/// plano (al soltar en el Finder) sin acceder al documento, que es `@MainActor`.
struct ExportPlan: Sendable {
    let name: String
    let payload: Payload

    enum Payload: Sendable {
        case folder([ExportPlan])
        case diskFile(URL)
        case archiveEntry(entry: ArchiveEntry, archive: Data, password: String?, format: ArchiveFormat)
    }

    nonisolated var isDirectory: Bool {
        if case .folder = payload { return true }
        return false
    }

    /// Extrae el contenido a una carpeta temporal y devuelve la URL resultante.
    nonisolated func materialize() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePackrExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(name)
        try writeContents(to: destination)
        return destination
    }

    /// Número de ficheros (hojas) que contiene, para calcular el progreso.
    nonisolated func fileCount() -> Int {
        switch payload {
        case .folder(let children): return children.reduce(0) { $0 + $1.fileCount() }
        case .diskFile, .archiveEntry: return 1
        }
    }

    /// Escribe el contenido en la ruta `destination` (nombre final incluido).
    /// Llama a `onFile` tras escribir cada fichero (para reportar progreso).
    nonisolated func writeContents(to destination: URL, onFile: () -> Void = {}) throws {
        switch payload {
        case .folder(let children):
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in children {
                try child.writeContents(to: destination.appendingPathComponent(child.name), onFile: onFile)
            }
        case .diskFile(let url):
            try FileManager.default.copyItem(at: url, to: destination)
            onFile()
        case .archiveEntry(let entry, let archive, let password, let format):
            let data = try format.codec.entryData(for: entry, in: archive, password: password)
            try data.write(to: destination, options: .atomic)
            onFile()
        }
    }
}

/// Qué operación larga está en curso. El modelo emite el **token** (dato), no el texto;
/// la vista lo traduce. Así la i18n no vive en el modelo y la etiqueta se re-localiza si
/// se cambia de idioma a mitad de la operación.
enum ProgressKind: Equatable {
    case opening(String)       // nombre del fichero que se abre
    case extracting
    case compressing(String)   // nombre del documento ("" si aún sin guardar)
    case encrypting(String)    // nombre del documento ("" si aún sin guardar)
    case splitting
}

/// Estado de una operación larga (comprimir/extraer) para la barra de progreso.
struct ProgressState {
    var kind: ProgressKind
    var fraction: Double?   // nil = indeterminado
}
