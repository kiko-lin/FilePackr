import AppKit
import FilePackrModel

/// Proveedor de los **Servicios de macOS** (visibles en el menú contextual del Finder y en el
/// menú «Servicios»): «Abrir en FilePackr» y «Descomprimir aquí». Se usan NSServices —no una
/// Finder Sync Extension— porque la app **no** tiene App Sandbox, así que no hace falta target
/// aparte ni entitlements. Lo declara `Info.plist` (clave `NSServices`) y lo registra
/// `AppDelegate` (`NSApp.servicesProvider`). Los nombres de método casan con `NSMessage`.
@MainActor
final class FinderServicesProvider: NSObject {
    /// «Abrir en FilePackr»: entrega las rutas a la propia app por la vía normal de apertura
    /// (la misma que el doble clic en el Finder), abriendo cada archivo en su ventana.
    @objc func openInFilePackr(_ pboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        open(urls(from: pboard))
    }

    /// «Descomprimir aquí»: extrae cada archivo a una carpeta hermana con su nombre, sin abrir
    /// ventana. Si un archivo está protegido con contraseña, cae a abrirlo en la app (que tiene
    /// la UI para pedirla). Al terminar, revela lo extraído en el Finder.
    @objc func extractHereWithFilePackr(_ pboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let archives = urls(from: pboard)
        Task { await extractHere(archives) }
    }

    // MARK: - Apertura

    private func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: Bundle.main.bundleURL, configuration: config)
    }

    // MARK: - Descompresión directa

    private func extractHere(_ archives: [URL]) async {
        var revealed: [URL] = []
        for url in archives {
            do {
                if let dest = try await extractOne(url) { revealed.append(dest) }
            } catch {
                presentError(error, for: url)
            }
        }
        if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
    }

    /// Extrae un archivo a una carpeta hermana libre. Devuelve la carpeta creada, o `nil` si el
    /// archivo necesita contraseña (en cuyo caso se delega en abrirlo en la app).
    private func extractOne(_ url: URL) async throws -> URL? {
        let doc = ArchiveDocument()
        try await doc.openArchive(url)
        // Protegido/cifrado: necesita la UI de contraseña → abrir en la app en vez de fallar.
        if doc.isLocked || doc.requiresOpenPassword {
            open([url])
            return nil
        }
        let dest = freeFolder(in: url.deletingLastPathComponent(),
                              named: archiveBaseName(url.lastPathComponent))
        let plan = doc.exportPlanForAll(named: dest.lastPathComponent)
        try await Task.detached(priority: .userInitiated) {
            try plan.writeContents(to: dest)
        }.value
        return dest
    }

    /// Primera carpeta «<base>», «<base> 2»… que no exista todavía en `dir`.
    private func freeFolder(in dir: URL, named base: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    // MARK: - Utilidades

    private func urls(from pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    }

    private func presentError(_ error: Error, for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("error.title")
        alert.informativeText = "\(url.lastPathComponent): \(localizedErrorMessage(error))"
        alert.addButton(withTitle: loc("button.ok"))
        alert.runModal()
    }
}
