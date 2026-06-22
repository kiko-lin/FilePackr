import AppKit

/// Abre un `NSOpenPanel` configurado para **elegir una carpeta** (permite crear carpetas) y
/// devuelve la URL elegida, o `nil` si se cancela. Centraliza la configuración repetida del
/// selector de carpeta de destino (extracción) y del de la carpeta fija (Ajustes).
@MainActor
func chooseFolderPanel(prompt: String, startingAt: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = prompt
    if let startingAt { panel.directoryURL = startingAt }
    return panel.runModal() == .OK ? panel.url : nil
}
