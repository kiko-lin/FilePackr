import Foundation

/// Limita la frecuencia de los avisos de progreso: reporta solo cada ~1% (o al llegar al final),
/// para no inundar el hilo principal cuando una operación con ficheros grandes emite progreso por
/// cada trozo (muchísimos). Centraliza el umbral que antes estaba repetido en cada operación larga.
public struct ProgressThrottle {
    private var lastReported = 0.0

    public init() {}

    /// `true` si toca reportar esta `fraction` (0...1): cuando ha avanzado ≥1% desde el último
    /// reporte o ya ha llegado a 1. Actualiza el umbral interno cuando devuelve `true`.
    public mutating func shouldReport(_ fraction: Double) -> Bool {
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return false }
        lastReported = fraction
        return true
    }
}
