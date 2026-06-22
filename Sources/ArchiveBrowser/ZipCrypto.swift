import Foundation

/// Cifrado clásico de ZIP ("ZipCrypto" / PKWARE traditional), el de la opción
/// "Débil (PKZip2 compatible)". Es interoperable con `zip`/`unzip`, Finder,
/// Keka, WinZip… pero criptográficamente débil; para datos sensibles usar AES.
///
/// Cifra/descifra un flujo de bytes. Cada entrada cifrada lleva delante una
/// cabecera de cifrado de 12 bytes (también cifrada).
struct ZipCrypto {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    init(password: String) {
        for byte in password.utf8 { updateKeys(byte) }
    }

    private mutating func updateKeys(_ byte: UInt8) {
        key0 = crc(key0, byte)
        key1 = key1 &+ (key0 & 0xFF)
        key1 = key1 &* 134_775_813 &+ 1
        key2 = crc(key2, UInt8((key1 >> 24) & 0xFF))
    }

    private func crc(_ value: UInt32, _ byte: UInt8) -> UInt32 {
        (value >> 8) ^ CRC32.table[Int((value ^ UInt32(byte)) & 0xFF)]
    }

    private func keystreamByte() -> UInt8 {
        let temp = (key2 | 2) & 0xFFFF
        return UInt8(((temp &* (temp ^ 1)) >> 8) & 0xFF)
    }

    // El algoritmo es serial (cada byte actualiza la clave para el siguiente), así que no se
    // puede vectorizar; el único coste evitable es el `append`: se escribe sobre un buffer sin
    // inicializar, cada byte una sola vez.
    mutating func decrypt(_ data: [UInt8]) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: data.count) { out, count in
            for i in 0..<data.count {
                let plain = data[i] ^ keystreamByte()
                updateKeys(plain)
                out[i] = plain
            }
            count = data.count
        }
    }

    mutating func encrypt(_ data: [UInt8]) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: data.count) { out, count in
            for i in 0..<data.count {
                out[i] = data[i] ^ keystreamByte()
                updateKeys(data[i])
            }
            count = data.count
        }
    }
}
