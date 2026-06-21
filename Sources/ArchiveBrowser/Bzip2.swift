import Foundation
import Cbz2

public enum Bzip2Error: Error, Equatable { case notBzip2, corrupt }

/// bzip2 (`.bz2`): comprime/descomprime **un** flujo usando la `libbz2` del sistema
/// (firma `BZh`). Interoperable con `bzip2`/`bunzip2`, liblzma/bsdtar, Keka…
public enum Bzip2 {

    private static let BZ_OK: Int32 = 0
    private static let BZ_RUN: Int32 = 0
    private static let BZ_FINISH: Int32 = 2
    private static let BZ_RUN_OK: Int32 = 1
    private static let BZ_FINISH_OK: Int32 = 3
    private static let BZ_STREAM_END: Int32 = 4

    /// Comprime de `input` a `output` en **streaming** (memoria constante): adaptador del
    /// núcleo incremental que lee por trozos del fichero y escribe por trozos al fichero.
    public static func compress(from input: FileHandle, to output: FileHandle, blockSize: Int32 = 9) throws {
        try compress(blockSize: blockSize, next: CompressionStream.reader(input),
                     sink: { try output.write(contentsOf: $0) })
    }

    /// Comprime `data` a un flujo `.bz2` (`blockSize` 1–9, por defecto el máximo).
    /// Adaptador en memoria del mismo núcleo incremental (los bytes ya están en RAM).
    public static func compress(_ data: Data, blockSize: Int32 = 9) -> Data {
        var out = Data()
        do {
            try compress(blockSize: blockSize, next: CompressionStream.once(data), sink: { out.append($0) })
        } catch { return Data() }
        return out
    }

    /// Núcleo único de compresión bzip2 con la **API incremental** de `libbz2`: lee la
    /// entrada por trozos (`next`) y emite la salida por trozos (`sink`), con memoria
    /// constante. Lo comparten la ruta en memoria, la de fichero→fichero y el pipe tar.bz2.
    public static func compress(blockSize: Int32 = 9, next: () throws -> Data?,
                                sink: (Data) throws -> Void) throws {
        var strm = bz_stream()
        guard BZ2_bzCompressInit(&strm, blockSize, 0, 0) == BZ_OK else { throw Bzip2Error.corrupt }
        defer { BZ2_bzCompressEnd(&strm) }

        let cap = 64 * 1024
        let outBuf = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        let inBuf = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer { outBuf.deallocate(); inBuf.deallocate() }

        // Escribe lo producido en `outBuf` tras una llamada a BZ2_bzCompress.
        func flushOut() throws {
            let produced = cap - Int(strm.avail_out)
            if produced > 0 { try sink(Data(bytes: outBuf, count: produced)) }
        }

        // Fase RUN: alimentar cada trozo de entrada hasta consumirlo. `next` puede dar
        // trozos mayores que el búfer; los partimos en porciones de `cap`.
        while let chunk = try next() {
            var offset = 0
            while offset < chunk.count {
                let n = min(cap, chunk.count - offset)
                chunk.withUnsafeBytes { raw in
                    inBuf.update(from: raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self), count: n)
                }
                offset += n
                strm.next_in = inBuf
                strm.avail_in = UInt32(n)
                repeat {
                    strm.next_out = outBuf
                    strm.avail_out = UInt32(cap)
                    guard BZ2_bzCompress(&strm, BZ_RUN) == BZ_RUN_OK else { throw Bzip2Error.corrupt }
                    try flushOut()
                } while strm.avail_in > 0 || strm.avail_out == 0
            }
        }

        // Fase FINISH: vaciar lo pendiente hasta BZ_STREAM_END.
        strm.next_in = inBuf
        strm.avail_in = 0
        var rc: Int32 = BZ_FINISH_OK
        repeat {
            strm.next_out = outBuf
            strm.avail_out = UInt32(cap)
            rc = BZ2_bzCompress(&strm, BZ_FINISH)
            guard rc == BZ_FINISH_OK || rc == BZ_STREAM_END else { throw Bzip2Error.corrupt }
            try flushOut()
        } while rc != BZ_STREAM_END
    }

    /// Descomprime un flujo `.bz2` a memoria.
    public static func decompress(_ data: Data) throws -> Data {
        var out = Data()
        try decompress(data, sink: { out.append($0) })
        return out
    }

    /// Descomprime un flujo `.bz2` emitiendo la salida por trozos (`sink`), sin materializar
    /// el resultado en RAM, con la **API incremental** de `libbz2`. La entrada (ya en
    /// memoria/mapeada) se alimenta en trozos; lo grande es la salida, que va al `sink`.
    public static func decompress(_ data: Data, sink: (Data) throws -> Void) throws {
        let base = data.startIndex
        guard data.count >= 3, data[base] == 0x42, data[base + 1] == 0x5A, data[base + 2] == 0x68 else {  // "BZh"
            throw Bzip2Error.notBzip2
        }
        var strm = bz_stream()
        guard BZ2_bzDecompressInit(&strm, 0, 0) == BZ_OK else { throw Bzip2Error.corrupt }
        defer { BZ2_bzDecompressEnd(&strm) }

        let cap = 64 * 1024
        let outBuf = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        let inBuf = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer { outBuf.deallocate(); inBuf.deallocate() }

        var offset = base
        let end = data.endIndex
        var moreInput = true
        while true {
            if strm.avail_in == 0 {
                if offset < end {
                    let n = min(cap, end - offset)
                    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: inBuf, count: n), from: offset..<(offset + n))
                    strm.next_in = inBuf
                    strm.avail_in = UInt32(n)
                    offset += n
                } else {
                    moreInput = false
                }
            }
            strm.next_out = outBuf
            strm.avail_out = UInt32(cap)
            let rc = BZ2_bzDecompress(&strm)
            let produced = cap - Int(strm.avail_out)
            if produced > 0 { try sink(Data(bytes: outBuf, count: produced)) }
            if rc == BZ_STREAM_END { break }
            guard rc == BZ_OK else { throw Bzip2Error.corrupt }
            if !moreInput && produced == 0 && strm.avail_in == 0 { throw Bzip2Error.corrupt }   // truncado
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
