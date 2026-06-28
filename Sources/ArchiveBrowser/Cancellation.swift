import Foundation

/// Señal **cooperativa** de cancelación para las operaciones largas del motor (compresión,
/// escritura de volúmenes…). El consumidor —la app— decide cuándo está cancelada; el motor
/// solo la **consulta** en los puntos naturales de sus bucles (por entrada y por trozo) y lanza
/// `CancellationError`. Así el motor queda **desacoplado** del `CancelToken` de la app y la
/// cancelación es real (para en el siguiente trozo, no "a posteriori").
///
/// El valor por defecto `.none` no cancela nunca, de modo que los call sites que no la necesitan
/// (tests, rutas en memoria) no tienen que pasar nada.
public struct CancellationCheck: Sendable {
    private let _isCancelled: @Sendable () -> Bool

    public init(_ isCancelled: @escaping @Sendable () -> Bool) { _isCancelled = isCancelled }

    /// Nunca cancela.
    public static let none = CancellationCheck { false }

    public var isCancelled: Bool { _isCancelled() }

    /// Lanza `CancellationError` si la operación está cancelada. Llamar en los límites de cada
    /// bucle (por entrada y por trozo) para que el corte sea inmediato.
    public func check() throws {
        if _isCancelled() { throw CancellationError() }
    }
}
