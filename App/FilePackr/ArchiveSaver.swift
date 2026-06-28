import Foundation
import ArchiveBrowser

/// Descripción **`Sendable`** de qué escribir, ensamblada por el documento en el hilo
/// principal (lee el árbol) y entregada al `ArchiveSaver`, que la codifica a disco en
/// segundo plano. Así el documento no conoce la mecánica de ficheros temporales ni el
/// streaming de ZIP, y el saver no toca el árbol (que es `@MainActor`).
enum SavePayload: Sendable {
    /// ZIP: entradas ya resueltas (ficheros al vuelo o bytes en crudo) + cifrado + nivel.
    case zip(inputs: [ZipEntryInput], encryption: ZipEncryption, password: String?, level: CompressionLevel)
    /// Formatos que se producen como un único `Data` (tar/tar.gz/tar.xz/tar.bz2/gz/xz/bz2).
    /// El cómputo va diferido en un cierre `@Sendable` para ejecutarse en segundo plano.
    case data(@Sendable () throws -> Data)
    /// Compresión en **streaming** a disco: el cierre escribe el resultado en el
    /// `FileHandle` por trozos, sin cargar el fichero entero en memoria (gz/xz/bz2 de
    /// un fichero de disco). Recibe la `CancellationCheck` para consultarla en su bucle
    /// (la inyecta en el `next` de los compresores).
    case stream(write: @Sendable (FileHandle, CancellationCheck) throws -> Void)
    /// Formatos de libarchive (7z/iso/xar): se escriben directamente a un fichero.
    case libArchive(items: [LibArchive.WriteItem], format: LibArchive.WriteFormat, level: CompressionLevel)
}

/// Codifica un `SavePayload` en el fichero de trabajo, en segundo plano. `work` es un
/// temporal privado del documento, que es quien lo **coloca de forma atómica** después
/// (mueve o trocea `work`→destino) y controla progreso y estado. Por eso aquí se escribe
/// directo, sin un segundo temporal: si algo falla, el documento borra `work`.
enum ArchiveSaver {

    /// Escribe `payload` en `work`. `progress` (fracción 0…1) solo lo emite ZIP. `cancellation`
    /// se consulta en los bucles de escritura (por entrada y por trozo): al cancelar, el escritor
    /// lanza `CancellationError` y el documento descarta el temporal `work`.
    static func encode(_ payload: SavePayload, to work: URL,
                       cancellation: CancellationCheck = .none,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            switch payload {
            case .zip(let inputs, let encryption, let password, let level):
                try writeToFile(work) { handle in
                    try ZipWriter().write(inputs, to: handle, encryption: encryption,
                                          password: password, level: level,
                                          cancellation: cancellation, progress: progress)
                }
            case .data(let make):
                try make().write(to: work)
            case .stream(let write):
                try writeToFile(work) { try write($0, cancellation) }
            case .libArchive(let items, let format, let level):
                try LibArchive.write(items, to: work, format: format, level: level, cancellation: cancellation)
            }
        }.value
    }

    /// Crea `url`, lo abre para escritura, ejecuta `body` y cierra. **No** es atómico (el
    /// documento coloca el temporal resultante de forma atómica). `body` escribe el
    /// contenido en el `FileHandle`: el ZIP en streaming o la compresión gz/xz/bz2.
    nonisolated private static func writeToFile(_ url: URL, _ body: (FileHandle) throws -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try body(handle)
    }
}
