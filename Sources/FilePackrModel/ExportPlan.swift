import Foundation
import ArchiveBrowser

/// Errores de la extracción de un `ExportPlan`.
public enum ExportError: Error, Equatable {
    /// Una entrada intentaba escribir fuera de la carpeta destino (ZIP-Slip / path traversal).
    /// El argumento es el nombre del componente que provocó el escape.
    case pathEscapesDestination(String)
}

/// Instantánea inmutable y `Sendable` de un nodo para poder extraerlo en segundo
/// plano (al soltar en el Finder) sin acceder al documento, que es `@MainActor`.
public struct ExportPlan: Sendable {
    public let name: String
    public let payload: Payload

    public enum Payload: Sendable {
        case folder([ExportPlan])
        case diskFile(URL)
        case archiveEntry(entry: ArchiveEntry, archive: ArchiveContainer, password: String?, format: ArchiveFormat)
    }

    nonisolated public var isDirectory: Bool {
        if case .folder = payload { return true }
        return false
    }

    /// Extrae el contenido a una carpeta temporal y devuelve la URL resultante.
    nonisolated public func materialize(isCancelled: @escaping () -> Bool = { false }) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePackrExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(name)
        do {
            try writeContents(to: destination, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        return destination
    }

    /// Tamaño total **descomprimido** en bytes, para una barra de progreso fina (incluido el
    /// caso de un único fichero enorme). `0` si no se conoce (entradas sin tamaño declarado):
    /// el consumidor cae entonces a un indicador indeterminado.
    nonisolated public func byteCount() -> Int64 {
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
    ///
    /// `onSkip` recibe los bytes (sin nombre: no hay un fichero de destino al que asociarlos) de
    /// cada entrada que el codec tiene que atravesar sin extraerla — solo relevante en formatos
    /// de recorrido secuencial (RAR/7z…) al extraer un subconjunto: ese recorrido tiene coste
    /// real aunque no escriba nada, y sin esta señal la barra parece congelada mientras dura.
    nonisolated public func writeContents(to destination: URL,
                                   onProgress: @escaping (_ name: String, _ bytes: Int64) -> Void = { _, _ in },
                                   onSkip: @escaping (_ bytes: Int64) -> Void = { _ in },
                                   isCancelled: @escaping () -> Bool = { false }) throws {
        // Fase 1: crear la estructura (carpetas), copiar los ficheros de disco y **recolectar** las
        // entradas de archivo con su destino. Todas las entradas de un plan comparten archivo y
        // formato por construcción (`exportPlan(for:)` usa el único documento abierto).
        var jobs: [(entry: ArchiveEntry, url: URL)] = []
        var archive: ArchiveContainer?, format: ArchiveFormat?, password: String?
        // Seguridad (ZIP-Slip, 2ª defensa): nada puede escribirse fuera del árbol de `destination`,
        // aunque un nombre con ".." se colara hasta aquí (la 1ª defensa los filtra en el árbol).
        // Comparamos rutas estandarizadas: el destino debe ser la raíz o un descendiente suyo.
        let root = destination.standardizedFileURL
        func isContained(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return path == root.path || path.hasPrefix(root.path + "/")
        }
        func buildStructure(_ plan: ExportPlan, to dest: URL) throws {
            if isCancelled() { throw CancellationError() }
            switch plan.payload {
            case .folder(let children):
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                for child in children {
                    let childDest = dest.appendingPathComponent(child.name)
                    guard isContained(childDest) else { throw ExportError.pathEscapesDestination(child.name) }
                    try buildStructure(child, to: childDest)
                }
            case .diskFile(let url):
                try FileManager.default.copyItem(at: url, to: dest)
                onProgress(plan.name, Self.fileSize(url))   // copyItem no es por trozos: un salto al acabar
            case .archiveEntry(let entry, let arch, let pwd, let fmt):
                jobs.append((entry, dest)); archive = arch; format = fmt; password = pwd
            }
        }
        try buildStructure(self, to: destination)
        guard let format, let archive, !jobs.isEmpty else { return }

        // Fase 2: un **solo recorrido** del archivo colocando cada entrada en su destino. Para tar
        // comprimido con varias entradas = una sola descompresión (§10 #1); el resto va por entrada.
        // Cada fichero se escribe atómicamente (temp + move) y se cierra al empezar el siguiente.
        let destinations = Dictionary(jobs.map { ($0.entry.path, $0.url) }, uniquingKeysWith: { first, _ in first })
        var writer: AtomicEntryWriter?
        func commitCurrent() throws { try writer?.commit(); writer = nil }
        do {
            try format.codec.extractAll(jobs.map(\.entry), in: archive, password: password, onSkip: onSkip) { entry in
                try commitCurrent()                                  // la entrada anterior queda completa
                guard let url = destinations[entry.path] else { return nil }   // no seleccionada → saltar
                let active = try AtomicEntryWriter(destination: url)
                writer = active
                let name = url.lastPathComponent   // nombre del fichero para la etiqueta de progreso
                return { chunk in
                    if isCancelled() { throw CancellationError() }
                    try active.write(chunk)
                    onProgress(name, Int64(chunk.count))
                }
            }
            try commitCurrent()                                      // última entrada
        } catch {
            writer?.discard()                                        // temporal a medias: descartar
            throw error
        }
    }
}

/// Qué operación larga está en curso. El modelo emite el **token** (dato), no el texto;
/// la vista lo traduce. Así la i18n no vive en el modelo y la etiqueta se re-localiza si
/// se cambia de idioma a mitad de la operación.
public enum ProgressActivity: Equatable {
    case opening(String)       // nombre del fichero que se abre
    case extracting
    case compressing(String)   // nombre del documento ("" si aún sin guardar)
    case encrypting(String)    // nombre del documento ("" si aún sin guardar)
    case splitting
    case cleaningUp            // borrando extracciones parciales tras cancelar un lote
}

/// Estado de una operación larga (comprimir/extraer) para la barra de progreso.
public struct ProgressState {
    public var kind: ProgressActivity
    public var fraction: Double? // nil = indeterminado
    public var detail: String? // nombre del fichero en curso (p. ej. al extraer), opcional
}

/// Señal de cancelación **hilo-segura**, compartida por las dos rutas de extracción (botón
/// Extraer y arrastre al Finder): se marca desde el hilo principal (al pulsar la X o cerrar la
/// ventana) y se consulta desde el hilo de fondo que descomprime, en cada trozo.
public nonisolated final class CancelToken: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var cancelled = false
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
