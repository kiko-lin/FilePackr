import Cocoa
import FinderSync

/// Extensión **Finder Sync** de FilePackr. Añade dos acciones **directas** al menú contextual del
/// Finder (no bajo el submenú «Servicios») sobre archivos comprimidos:
///
///   • «Abrir en FilePackr»            → abre cada archivo en la app.
///   • «Descomprimir aquí con FilePackr» → extrae cada archivo a una carpeta hermana.
///
/// Los títulos usan `NSLocalizedString`, así que **siguen el idioma del SO** (en/es).
///
/// La extensión va en **App Sandbox** (obligatorio para app extensions) y **no** hace el trabajo
/// pesado: reenvía a la app anfitriona (sin sandbox). «Abrir» = apertura de archivo normal (odoc);
/// «Descomprimir aquí» = esquema propio `filepackr://extract?p=<base64>`, que maneja `AppDelegate`.
class FinderSyncExtension: FIFinderSync {

    /// Extensiones de archivo que sabemos manejar (coinciden con los tipos declarados en el
    /// `Info.plist` de la app). Las dobles (`tar.gz`…) se comprueban aparte.
    private static let singleExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz", "tbz2",
        "7z", "rar", "iso", "cpio", "xar", "lha", "lzh", "cab"
    ]
    private static let doubleSuffixes = [".tar.gz", ".tar.xz", ".tar.bz2"]

    override init() {
        super.init()
        // Finder Sync solo ofrece menús para ítems dentro de las carpetas que vigila. Vigilamos la
        // raíz para cubrir todo el sistema de archivos (Escritorio, Descargas, volúmenes externos…).
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        guard !selectedArchives().isEmpty else { return nil }   // solo si hay comprimidos seleccionados

        let menu = NSMenu(title: "")
        menu.addItem(withTitle: NSLocalizedString("menu.open",
                                                  comment: "Contextual menu: open selected archives in FilePackr"),
                     action: #selector(openInFilePackr(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("menu.extract",
                                                  comment: "Contextual menu: extract selected archives to a sibling folder"),
                     action: #selector(extractHere(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Acciones

    @objc private func openInFilePackr(_ sender: AnyObject?) { forward(action: "open") }
    @objc private func extractHere(_ sender: AnyObject?)     { forward(action: "extract") }

    /// Reenvía por el esquema propio `filepackr://<action>?p=<base64(ruta)>`. Lo maneja la app
    /// anfitriona (sin sandbox), que abre/extrae los archivos ella misma. No usamos
    /// `NSWorkspace.open(withApplicationAt:)` desde aquí porque el traspaso de un fichero desde una
    /// extensión en sandbox a otra app lo bloquea macOS («… no tiene permiso para abrir …»).
    private func forward(action: String) {
        let archives = selectedArchives()
        guard !archives.isEmpty,
              var comps = URLComponents(string: "filepackr://\(action)") else { return }
        comps.queryItems = archives.map {
            URLQueryItem(name: "p", value: Data($0.path.utf8).base64EncodedString())
        }
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Utilidades

    private func selectedArchives() -> [URL] {
        (FIFinderSyncController.default().selectedItemURLs() ?? []).filter(Self.isSupportedArchive)
    }

    private static func isSupportedArchive(_ url: URL) -> Bool {
        // Solo ficheros (no carpetas).
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return false }
        let name = url.lastPathComponent.lowercased()
        if doubleSuffixes.contains(where: name.hasSuffix) { return true }
        return singleExtensions.contains(url.pathExtension.lowercased())
    }
}
