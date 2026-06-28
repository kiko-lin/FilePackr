import Foundation

/// Genera un nombre libre tipo «base 2.ext», «base 3.ext»… (separador de espacio, como el
/// Finder), conservando la extensión. Centraliza la lógica que antes estaba duplicada al añadir
/// (conflicto de nombre en el árbol), crear carpetas y extraer (conflicto en disco/lote).
enum UniqueName {
    /// Primer nombre disponible para `name` según el predicado `isTaken`. Si `name` ya está
    /// libre lo devuelve tal cual; si no, prueba «base N(.ext)» empezando en 2. La extensión se
    /// conserva (un `name` sin punto se trata como base sin extensión).
    static func next(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }
}
