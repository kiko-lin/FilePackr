import Foundation

/// Escribe en `url` a través de un fichero temporal en la misma carpeta y lo reemplaza al
/// final, de modo que el destino nunca queda a medias: si `body` lanza, el temporal se borra
/// y `url` se deja intacto. Síncrono — el llamador decide el hilo.
///
/// Lo usa la **extracción a una ruta real del Finder** (`ExportPlan.writeContents`), donde el
/// destino es visible y debe ser todo-o-nada. El guardado no pasa por aquí: escribe a su
/// propio temporal de trabajo y es el documento quien lo coloca atómicamente.
///
/// `body` recibe el `FileHandle` del temporal abierto para escritura y escribe el contenido.
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
