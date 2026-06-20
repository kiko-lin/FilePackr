import Foundation
import ArchiveBrowser

/// Descripción **`Sendable`** de qué escribir, ensamblada por el documento en el hilo
/// principal (lee el árbol) y entregada al `ArchiveSaver`, que la codifica a disco en
/// segundo plano. Así el documento no conoce la mecánica de ficheros temporales ni el
/// streaming de ZIP, y el saver no toca el árbol (que es `@MainActor`).
enum SavePayload: Sendable {
    /// ZIP: entradas ya resueltas (ficheros al vuelo o bytes en crudo) + cifrado.
    case zip(inputs: [ZipEntryInput], encryption: ZipEncryption, password: String?)
    /// Formatos que se producen como un único `Data` (tar/tar.gz/tar.xz/tar.bz2/gz/xz/bz2).
    /// El cómputo va diferido en un cierre `@Sendable` para ejecutarse en segundo plano.
    case data(@Sendable () throws -> Data)
    /// Formatos de libarchive (7z/iso/xar): se escriben directamente a un fichero.
    case libArchive(items: [LibArchive.WriteItem], format: LibArchive.WriteFormat)
}

/// Codifica un `SavePayload` en el fichero de trabajo, en segundo plano. La colocación
/// final (fichero único o troceado en volúmenes) la decide el documento, que controla
/// el progreso y el estado del documento.
enum ArchiveSaver {

    /// Escribe `payload` en `work`. `progress` (fracción 0…1) solo lo emite ZIP.
    static func encode(_ payload: SavePayload, to work: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        switch payload {
        case .zip(let inputs, let encryption, let password):
            try await streamZip(inputs, to: work, encryption: encryption, password: password, progress: progress)
        case .data(let make):
            try await Task.detached(priority: .userInitiated) {
                try make().write(to: work, options: .atomic)
            }.value
        case .libArchive(let items, let format):
            try await Task.detached(priority: .userInitiated) {
                try LibArchive.write(items, to: work, format: format)
            }.value
        }
    }

    /// Escribe el ZIP en `url` haciendo streaming a un temporal y reemplazando al final,
    /// para no dejar el destino a medias si falla.
    private static func streamZip(_ inputs: [ZipEntryInput], to url: URL,
                                  encryption: ZipEncryption, password: String?,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).filepackr.tmp")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try ZipWriter().write(inputs, to: handle, encryption: encryption,
                                      password: password, progress: progress)
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
        }.value
    }
}
