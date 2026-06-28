import Foundation

/// Texto localizado contra el **String Catalog** (`Localizable.xcstrings`).
///
/// La app sigue el idioma del **sistema** (lo idiomático en macOS): no hay selector de idioma
/// interno. Una vez la app declara `es` como localización (ver `knownRegions` del proyecto),
/// macOS elige el idioma según *Ajustes → Idioma y región* y **AppKit localiza por su cuenta**
/// la barra de menús, los paneles del sistema y la columna «Clase» (`UTType`), sin código.
///
/// Las vistas siguen llamando `loc("clave")`; ahora resuelve por `NSLocalizedString` contra la
/// tabla `Localizable` (a la que compila el catálogo). Como el idioma no cambia en caliente, es
/// una función pura —no hace falta `ObservableObject`/`@EnvironmentObject`—.
func loc(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Variante con formato (`%@`, `%d`…).
func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
