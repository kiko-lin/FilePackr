import Foundation

/// Reparte los números de los documentos sin guardar para el título de ventana
/// («Sin título 1», «Sin título 2»…). Como cada ventana (`WindowGroup`) tiene su propio
/// `ArchiveDocument`, la numeración necesita coordinación entre todas: cada ventana **pide** el
/// menor número libre cuando es un documento nuevo sin guardar y lo **devuelve** al cerrarse o al
/// pasar a tener un nombre de archivo real, de modo que el número se reutilice (como TextEdit).
@MainActor
public enum UntitledNumbering {
    private static var inUse: Set<Int> = []

    /// Reserva y devuelve el menor número libre (≥ 1).
    public static func claim() -> Int {
        var n = 1
        while inUse.contains(n) { n += 1 }
        inUse.insert(n)
        return n
    }

    /// Libera un número para que vuelva a estar disponible.
    public static func release(_ n: Int) {
        inUse.remove(n)
    }
}
