import Foundation
import Compression

public enum XzError: Error, Equatable { case notXz, corrupt }

/// xz (LZMA2 en contenedor `.xz`): comprime/descomprime **un** flujo. Se apoya en la
/// *Compression framework* de Apple (`COMPRESSION_LZMA`), cuya salida es un `.xz`
/// estándar (firma `FD 37 7A 58 5A 00`), interoperable con `xz`, liblzma, Keka…
public enum Xz {

    /// Comprime `data` a un flujo `.xz`.
    public static func compress(_ data: Data) -> Data {
        run(data, COMPRESSION_STREAM_ENCODE) ?? Data()
    }

    /// Descomprime un flujo `.xz`.
    public static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 6, Array(data.prefix(6)) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] else {
            throw XzError.notXz
        }
        guard let out = run(data, COMPRESSION_STREAM_DECODE) else { throw XzError.corrupt }
        return out
    }

    /// Una entrada `ArchiveEntry` para el único fichero de un `.xz` (para navegarlo).
    /// El tamaño se lee del índice del propio `.xz` (sin descomprimir).
    public static func entries(in data: Data, fallbackName: String) -> [ArchiveEntry] {
        [ArchiveEntry(
            path: fallbackName,
            compressedSize: UInt64(data.count),
            uncompressedSize: uncompressedSize(of: data) ?? 0,
            isDirectory: false, compressionMethod: 0, crc32: 0,
            localHeaderOffset: 0, modificationDate: nil,
            dosTime: 0, flags: 0, aesStrength: nil, aesRealMethod: nil)]
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

    /// Procesa `input` por la *Compression framework* en streaming (maneja tamaño de
    /// salida desconocido), devolviendo el resultado o `nil` si falla.
    private static func run(_ input: Data, _ op: compression_stream_operation) -> Data? {
        let dstCapacity = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        var stream = compression_stream(dst_ptr: dst, dst_size: dstCapacity,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, op, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        let src = [UInt8](input)
        return src.withUnsafeBufferPointer { srcBuf -> Data? in
            stream.src_ptr = srcBuf.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = src.count
            stream.dst_ptr = dst
            stream.dst_size = dstCapacity

            var output = Data()
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            var status = COMPRESSION_STATUS_OK
            repeat {
                status = compression_stream_process(&stream, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(dst, count: dstCapacity - stream.dst_size)
                    stream.dst_ptr = dst
                    stream.dst_size = dstCapacity
                default:
                    return nil
                }
            } while status == COMPRESSION_STATUS_OK
            return output
        }
    }
}
