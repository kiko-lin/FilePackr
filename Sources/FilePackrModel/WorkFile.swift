import Foundation

/// Ciclo de vida de los **temporales de guardado** (`.<uuid>.filepackr.work`): se escriben
/// ocultos y en la carpeta del destino para que el movimiento final sea atómico (mismo volumen).
/// Centraliza el sufijo, el registro de los que están en curso y su limpieza, antes disperso en
/// `ArchiveDocument`.
public enum WorkFile {
    /// Sufijo de los temporales de guardado.
    public static let suffix = ".filepackr.work"

    /// Temporales de guardados **en curso** (todas las ventanas). Si la app termina a mitad, el
    /// `AppDelegate` los borra en `applicationWillTerminate` (la tarea de fondo muere antes de
    /// limpiar su propio `.work`). En cierre/cancelación normales los limpia el `catch` de `writeArchive`.
    @MainActor public static var active: Set<URL> = []

    /// Borra los temporales de guardados que quedaran en curso al terminar la app.
    @MainActor public static func cleanUpActive() {
        for url in active { try? FileManager.default.removeItem(at: url) }
        active.removeAll()
    }

    /// Borra restos de un guardado interrumpido por un cierre forzado anterior en `folder`.
    /// **Conservador**: solo los de más de una hora, para no tocar un guardado concurrente en
    /// curso en la misma carpeta (que tendría segundos de antigüedad).
    public static func cleanStale(in folder: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in items where url.lastPathComponent.hasSuffix(suffix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
