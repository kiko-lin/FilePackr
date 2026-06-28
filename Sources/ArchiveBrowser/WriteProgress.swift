import Foundation

/// Reporta el progreso de la **escritura/compresión** por bytes de **entrada** procesados. Lo
/// llaman los escritores a medida que leen el contenido original (por trozos), indicando el
/// fichero en curso y cuántos bytes acaba de procesar; el consumidor (la app) acumula contra el
/// total conocido y deriva la fracción + el nombre para la barra de progreso.
///
/// Es un **struct** (no un alias de cierre) para poder pasarlo como valor a través de los cierres
/// de `SavePayload.stream` y almacenarlo en generadores (`Tar.reader`) sin fricción de `@escaping`.
/// El valor por defecto `.none` no reporta nada.
public struct WriteProgress {
    private let _report: (_ file: String, _ inputBytes: Int) -> Void

    public init(_ report: @escaping (_ file: String, _ inputBytes: Int) -> Void) { _report = report }

    /// No reporta (para call sites que no lo necesitan: tests, rutas en memoria). Computado para
    /// no ser un global con estado mutable (las instancias reales capturan acumuladores y se usan
    /// dentro de la tarea de fondo de escritura, no cruzan dominios de concurrencia).
    public static var none: WriteProgress { WriteProgress { _, _ in } }

    /// Reporta `inputBytes` de entrada procesados del fichero `file`.
    public func callAsFunction(_ file: String, _ inputBytes: Int) { _report(file, inputBytes) }
}
