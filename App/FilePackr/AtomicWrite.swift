import Foundation

/// Escribe en `url` a través de un fichero temporal en la misma carpeta y lo reemplaza al
/// final, de modo que el destino nunca queda a medias: si `body` lanza, el temporal se borra
/// y `url` se deja intacto. Síncrono — el llamador decide el hilo (el guardado lo envuelve en
/// `Task.detached`; la extracción a Finder ya corre en segundo plano).
///
/// `body` recibe el `FileHandle` del temporal abierto para escritura y escribe el contenido
/// (el ZIP en streaming, la compresión gz/xz/bz2, o la extracción de una entrada a disco).
func writeFileAtomically(to url: URL, _ body: (FileHandle) throws -> Void) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(UUID().uuidString).filepackr.tmp")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    let handle = try FileHandle(forWritingTo: tmp)
    do {
        try body(handle)
        try handle.close()
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.moveItem(at: tmp, to: url)
}
