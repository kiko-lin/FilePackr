import Foundation

/// CRC-32 (polinomio IEEE 0xEDB88320), tal como lo exige el formato ZIP para
/// validar la integridad de cada entrada. Implementación por tabla.
public enum CRC32 {

    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// Calcula el CRC-32 de `data` de una sola pasada.
    public static func checksum(_ data: Data) -> UInt32 {
        var acc = Accumulator()
        acc.update(data)
        return acc.final
    }

    /// Acumulador incremental: permite calcular el CRC-32 por trozos (streaming)
    /// sin tener todos los bytes a la vez. Usado por gzip y ZIP al comprimir al vuelo.
    public struct Accumulator {
        private var crc: UInt32 = 0xFFFF_FFFF

        public init() {}

        /// Incorpora un trozo más al cálculo.
        public mutating func update(_ data: Data) {
            for byte in data {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }

        /// CRC-32 acumulado hasta ahora.
        public var final: UInt32 { crc ^ 0xFFFF_FFFF }
    }
}
