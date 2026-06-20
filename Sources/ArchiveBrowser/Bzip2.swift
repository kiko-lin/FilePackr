import Foundation
import Cbz2

public enum Bzip2Error: Error, Equatable { case notBzip2, corrupt }

/// bzip2 (`.bz2`): comprime/descomprime **un** flujo usando la `libbz2` del sistema
/// (firma `BZh`). Interoperable con `bzip2`/`bunzip2`, liblzma/bsdtar, Keka…
public enum Bzip2 {

    private static let BZ_OK: Int32 = 0
    private static let BZ_OUTBUFF_FULL: Int32 = -8

    /// Comprime `data` a un flujo `.bz2` (`blockSize` 1–9, por defecto el máximo).
    public static func compress(_ data: Data, blockSize: Int32 = 9) -> Data {
        var dstLen = UInt32(data.count + data.count / 100 + 600)   // cota segura documentada
        let dst = UnsafeMutablePointer<CChar>.allocate(capacity: Int(dstLen))
        defer { dst.deallocate() }
        let src = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, data.count))
        defer { src.deallocate() }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: src, count: data.count))

        let rc = BZ2_bzBuffToBuffCompress(dst, &dstLen, src, UInt32(data.count), blockSize, 0, 0)
        guard rc == BZ_OK else { return Data() }
        return Data(bytes: dst, count: Int(dstLen))
    }

    /// Descomprime un flujo `.bz2`. Como bzip2 no guarda el tamaño original, se
    /// reintenta con un búfer cada vez mayor si se queda corto.
    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x42, bytes[1] == 0x5A, bytes[2] == 0x68 else {   // "BZh"
            throw Bzip2Error.notBzip2
        }
        let src = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, data.count))
        defer { src.deallocate() }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: src, count: data.count))

        var capacity = max(data.count * 4, 1024)
        while true {
            var dstLen = UInt32(capacity)
            let dst = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
            let rc = BZ2_bzBuffToBuffDecompress(dst, &dstLen, src, UInt32(data.count), 0, 0)
            if rc == BZ_OK {
                let out = Data(bytes: dst, count: Int(dstLen))
                dst.deallocate()
                return out
            }
            dst.deallocate()
            guard rc == BZ_OUTBUFF_FULL, capacity < (1 << 34) else { throw Bzip2Error.corrupt }
            capacity *= 2
        }
    }

    /// Una entrada `ArchiveEntry` para el único fichero de un `.bz2` (para navegarlo).
    /// bzip2 no almacena el tamaño original; lo sacamos descomprimiendo solo si el
    /// fichero es pequeño (para no ralentizar la apertura de uno enorme).
    public static func entries(in data: Data, fallbackName: String) -> [ArchiveEntry] {
        let size: UInt64 = data.count < 25_000_000
            ? UInt64((try? decompress(data))?.count ?? 0) : 0
        return [ArchiveEntry(
            path: fallbackName,
            compressedSize: UInt64(data.count), uncompressedSize: size,
            isDirectory: false, modificationDate: nil, isEncrypted: false)]
    }
}
