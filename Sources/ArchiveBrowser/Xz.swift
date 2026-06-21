import Foundation
import Compression

public enum XzError: Error, Equatable { case notXz, corrupt }

/// xz (LZMA2 en contenedor `.xz`): comprime/descomprime **un** flujo. Se apoya en la
/// *Compression framework* de Apple (`COMPRESSION_LZMA`), cuya salida es un `.xz`
/// estándar (firma `FD 37 7A 58 5A 00`), interoperable con `xz`, liblzma, Keka…
public enum Xz {

    /// Núcleo único: comprime a `.xz` leyendo la entrada por trozos (`next`) y emitiendo
    /// la salida por trozos (`sink`). Los adaptadores en memoria / fichero cuelgan de aquí.
    public static func compress(next: () throws -> Data?, sink: (Data) throws -> Void) throws {
        try CompressionStream.run(operation: COMPRESSION_STREAM_ENCODE, algorithm: COMPRESSION_LZMA,
                                  next: next, sink: sink)
    }

    /// Comprime `data` a un flujo `.xz` (en memoria).
    public static func compress(_ data: Data) -> Data {
        var out = Data()
        do { try compress(next: CompressionStream.once(data), sink: { out.append($0) }) } catch { return Data() }
        return out
    }

    /// Comprime de `input` a `output` en **streaming** (memoria constante): produce el
    /// mismo flujo `.xz` que `compress(_:)` pero sin cargar el fichero entero en RAM.
    public static func compress(from input: FileHandle, to output: FileHandle) throws {
        try compress(next: CompressionStream.reader(input), sink: { try output.write(contentsOf: $0) })
    }

    /// Descomprime un flujo `.xz` a memoria.
    public static func decompress(_ data: Data) throws -> Data {
        var out = Data()
        try decompress(data, sink: { out.append($0) })
        return out
    }

    /// Descomprime un flujo `.xz` emitiendo la salida por trozos (`sink`), sin materializar
    /// el resultado en RAM. La entrada `.xz` ya está en memoria (mapeada); lo grande es la
    /// salida, que va al `sink` (p. ej. un fichero) trozo a trozo.
    public static func decompress(_ data: Data, sink: (Data) throws -> Void) throws {
        guard data.count >= 6, Array(data.prefix(6)) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] else {
            throw XzError.notXz
        }
        do {
            try CompressionStream.run(operation: COMPRESSION_STREAM_DECODE, algorithm: COMPRESSION_LZMA,
                                      next: CompressionStream.once(data), sink: sink)
        } catch is CompressionStreamError { throw XzError.corrupt }   // error del códec; los del sink se propagan
    }

    /// Una entrada `ArchiveEntry` para el único fichero de un `.xz` (para navegarlo).
    /// El tamaño se lee del índice del propio `.xz` (sin descomprimir).
    public static func entries(in data: Data, fallbackName: String) -> [ArchiveEntry] {
        [ArchiveEntry(
            path: fallbackName,
            compressedSize: UInt64(data.count),
            uncompressedSize: uncompressedSize(of: data) ?? 0,
            isDirectory: false, modificationDate: nil, isEncrypted: false)]
    }

    /// Tamaño descomprimido total leído del **Index** del `.xz` (suma de los registros),
    /// sin descomprimir. `nil` si no se puede parsear.
    public static func uncompressedSize(of data: Data) -> UInt64? {
        let b = [UInt8](data)
        guard b.count >= 12, b[b.count - 2] == 0x59, b[b.count - 1] == 0x5A else { return nil }  // "YZ"
        // Stream Footer: CRC32(4) | Backward Size(4 LE) | Stream Flags(2) | "YZ"(2)
        let backward = UInt32(b[b.count - 8]) | (UInt32(b[b.count - 7]) << 8)
            | (UInt32(b[b.count - 6]) << 16) | (UInt32(b[b.count - 5]) << 24)
        let indexSize = (Int(backward) + 1) * 4
        let indexStart = b.count - 12 - indexSize
        guard indexStart >= 0, b[indexStart] == 0x00 else { return nil }  // Index Indicator
        var p = indexStart + 1
        guard let (count, p1) = readVLI(b, p) else { return nil }
        p = p1
        var total: UInt64 = 0
        for _ in 0..<count {
            guard let (_, p2) = readVLI(b, p) else { return nil }          // Unpadded Size
            guard let (size, p3) = readVLI(b, p2) else { return nil }      // Uncompressed Size
            total += size
            p = p3
        }
        return total
    }

    // MARK: - Helpers

    /// Entero de longitud variable (VLI) del formato xz: 7 bits por byte, MSB = continúa.
    private static func readVLI(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0, shift: UInt64 = 0, p = start
        while p < b.count {
            let byte = b[p]; p += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, p) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
