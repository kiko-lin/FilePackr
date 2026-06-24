import Foundation
import Compression

/// Compresión/descompresión DEFLATE en crudo (RFC 1951), que es la que usa el formato ZIP.
/// Al **escribir** se usa la zlib del sistema (`Zlib`), que admite **nivel** 0–9; al **leer**
/// se sigue usando el framework `Compression` de Apple (`COMPRESSION_ZLIB`, que produce/consume
/// DEFLATE sin la cabecera zlib y no necesita nivel).
enum Deflate {

    /// Comprime `input` con DEFLATE al `level` indicado. Devuelve `nil` si no logra reducir el
    /// tamaño (en ese caso conviene almacenar sin comprimir, método 0).
    static func compress(_ input: Data, level: CompressionLevel = .default) -> Data? {
        guard !input.isEmpty else { return nil }
        var out = Data()
        do {
            try Zlib.encode(level: level.zlibLevel, next: CompressionStream.once(input),
                            sink: { out.append($0) })
        } catch { return nil }
        guard !out.isEmpty, out.count < input.count else { return nil }
        return out
    }

    /// Ratio de compresión máximo de DEFLATE (~1032:1). Un tamaño declarado mayor que
    /// `comprimido × este factor` es físicamente imposible.
    static let maxDeflateRatio = 1032

    /// Descomprime `input` (DEFLATE) sabiendo el tamaño original `uncompressedSize`.
    static func decompress(_ input: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        // Cota anti "zip-bomb por declaración": `uncompressedSize` viene del central
        // directory (controlado por el fichero). Si supera el máximo que DEFLATE puede
        // expandir desde estos bytes comprimidos, es una cifra mentirosa: rechazar antes
        // de asignar (evita reservar gigabytes por un archivo malicioso). Para entradas
        // realmente grandes y no confiables, la ruta de streaming (`extract(...,sink:)`)
        // infla al vuelo sin esta asignación.
        guard uncompressedSize <= input.count * maxDeflateRatio + 64 else { return nil }
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
