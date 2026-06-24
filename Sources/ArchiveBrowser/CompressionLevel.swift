import Foundation

/// Nivel de compresión elegido al guardar/exportar: el compromiso clásico velocidad ⇄ tamaño.
/// Es una sola fuente de verdad para todo el motor; cada formato lo traduce a su escala interna
/// (`bzip2BlockSize`, `libArchiveLevel`, y en el futuro el nivel de zlib/liblzma para ZIP/gz/xz).
public enum CompressionLevel: String, Sendable, CaseIterable, Hashable {
    case fast, normal, maximum

    /// Valor por defecto (equilibrio). Coincide con el comportamiento histórico del motor.
    public static let `default`: CompressionLevel = .normal

    /// bzip2: tamaño de bloque 1–9 (mayor = más compresión y memoria). `normal`/`maximum`
    /// usan 9 —el máximo de bzip2— para no cambiar la salida por defecto de siempre.
    public var bzip2BlockSize: Int32 {
        switch self {
        case .fast: return 1
        case .normal, .maximum: return 9
        }
    }

    /// libarchive: nivel 0–9 de la opción `compression-level` (7z/lzma2). `normal` cae en 6,
    /// el preset por defecto de LZMA.
    public var libArchiveLevel: Int {
        switch self {
        case .fast: return 1
        case .normal: return 6
        case .maximum: return 9
        }
    }
}
