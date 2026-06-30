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
nonisolated func writeFileAtomically(to url: URL, _ body: (FileHandle) throws -> Void) throws {
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

/// Versión **incremental** de `writeFileAtomically`: abre un temporal, recibe el contenido por
/// trozos (`write`) y al terminar lo coloca atómicamente en `destination` (`commit`); si algo
/// falla a mitad (p. ej. cancelación), `discard` cierra y borra el temporal sin tocar el destino.
///
/// La usa la extracción en **un solo pase** (`ExportPlan.writeContents`), donde el motor recorre
/// el archivo entregando una entrada tras otra y no hay un cierre `body` por fichero: el llamador
/// abre un writer al empezar la entrada y lo `commit`ea cuando empieza la siguiente.
nonisolated final class AtomicEntryWriter {
    private let url: URL
    private let tmp: URL
    private let handle: FileHandle

    init(destination url: URL) throws {
        self.url = url
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tmp = dir.appendingPathComponent(".\(UUID().uuidString).filepackr.tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: tmp)
    }

    func write(_ chunk: Data) throws { try handle.write(contentsOf: chunk) }

    func commit() throws {
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    func discard() { try? handle.close(); try? FileManager.default.removeItem(at: tmp) }
}
