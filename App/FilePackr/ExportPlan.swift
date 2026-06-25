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

    /// Tamaño total **descomprimido** en bytes, para una barra de progreso fina (incluido el
    /// caso de un único fichero enorme). `0` si no se conoce (entradas sin tamaño declarado):
    /// el consumidor cae entonces a un indicador indeterminado.
    nonisolated func byteCount() -> Int64 {
        switch payload {
        case .folder(let children): return children.reduce(0) { $0 + $1.byteCount() }
        case .diskFile(let url): return Self.fileSize(url)
        case .archiveEntry(let entry, _, _, _): return Int64(entry.uncompressedSize)
        }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Escribe el contenido en la ruta `destination` (nombre final incluido). `onProgress`
    /// recibe, a medida que se escribe (por trozos, en streaming), el **nombre del fichero en
    /// curso** y los **bytes** de ese trozo, para una barra fina con etiqueta. Quien lo consuma
    /// debe **acumular y coalescer** (p. ej. a saltos del 1 %): aquí se llama por cada trozo,
    /// que con ficheros grandes son muchos.
    nonisolated func writeContents(to destination: URL,
                                   onProgress: (_ name: String, _ bytes: Int64) -> Void = { _, _ in },
                                   isCancelled: () -> Bool = { false }) throws {
        if isCancelled() { throw CancellationError() }
        switch payload {
        case .folder(let children):
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in children {
                try child.writeContents(to: destination.appendingPathComponent(child.name),
                                        onProgress: onProgress, isCancelled: isCancelled)
            }
        case .diskFile(let url):
            try FileManager.default.copyItem(at: url, to: destination)
            onProgress(name, Self.fileSize(url))   // copyItem no es por trozos: un salto al acabar
        case .archiveEntry(let entry, let archive, let password, let format):
            // Extracción en **streaming**: la salida descomprimida no se materializa en RAM.
            // Se escribe a un temporal y se mueve al final (atomicidad + limpieza si falla, p. ej.
            // si el MAC de AES no cuadra a mitad, o si se **cancela**: el temporal se descarta).
            try writeFileAtomically(to: destination) { handle in
                try format.codec.extract(entry, in: archive, password: password,
                                         sink: { chunk in
                                             if isCancelled() { throw CancellationError() }
                                             try handle.write(contentsOf: chunk)
                                             onProgress(name, Int64(chunk.count))
                                         })
            }
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
    var detail: String?     // nombre del fichero en curso (p. ej. al extraer), opcional
}

/// Señal de cancelación **hilo-segura**, compartida por las dos rutas de extracción (botón
/// Extraer y arrastre al Finder): se marca desde el hilo principal (al pulsar la X o cerrar la
/// ventana) y se consulta desde el hilo de fondo que descomprime, en cada trozo.
nonisolated final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
