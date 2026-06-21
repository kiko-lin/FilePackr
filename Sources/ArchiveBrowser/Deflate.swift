import Foundation
import Compression

/// Compresión/descompresión DEFLATE en crudo (RFC 1951), que es la que usa el
/// formato ZIP. Se apoya en el framework `Compression` de Apple: el algoritmo
/// `COMPRESSION_ZLIB` produce/consume DEFLATE sin la cabecera zlib.
enum Deflate {

    /// Comprime `input` con DEFLATE. Devuelve `nil` si no logra reducir el tamaño
    /// (en ese caso conviene almacenar sin comprimir, método 0).
    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let dstCapacity = input.count + 64
        var dst = Data(count: dstCapacity)

        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            input.withUnsafeBytes { srcRaw in
                compression_encode_buffer(
                    dstRaw.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                    srcRaw.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < input.count else { return nil }
        return dst.prefix(written)
    }

    /// Descomprime `input` (DEFLATE) sabiendo el tamaño original `uncompressedSize`.
    static func decompress(_ input: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        var dst = Data(count: uncompressedSize)

        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            input.withUnsafeBytes { srcRaw in
                compression_decode_buffer(
                    dstRaw.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    srcRaw.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { return nil }
        return dst
    }
}
