import Foundation
import Compression

public enum GzipError: Error, Equatable {
    case notGzip
    case corrupt
}

/// gzip (RFC 1952): comprime/descomprime **un** fichero (cabecera + DEFLATE +
/// CRC-32 + tamaño). Interoperable con `gzip`/`gunzip`, Finder, Keka…
public enum Gzip {

    /// Núcleo único: comprime a gzip leyendo la entrada por trozos (`next`) y emitiendo la
    /// salida por trozos (`sink`). Calcula CRC-32 y tamaño al vuelo para el footer. Los
    /// adaptadores en memoria / fichero / pipe (tar.gz) cuelgan de aquí.
    public static func compress(next: () throws -> Data?, sink: (Data) throws -> Void,
                                filename: String? = nil, mtime: Date? = nil) throws {
        try sink(header(filename: filename, mtime: mtime))
        var crc = CRC32.Accumulator()
        var size: UInt64 = 0
        try CompressionStream.run(operation: COMPRESSION_STREAM_ENCODE, algorithm: COMPRESSION_ZLIB,
            next: {
                guard let chunk = try next() else { return nil }
                crc.update(chunk)
                size += UInt64(chunk.count)
                return chunk
            },
            sink: sink)
        var footer = Data()
        footer.append(contentsOf: le32(crc.final))
        footer.append(contentsOf: le32(UInt32(truncatingIfNeeded: size)))
        try sink(footer)
    }

    /// Comprime `data` a un flujo gzip (en memoria). `filename` opcional va en la cabecera.
    public static func compress(_ data: Data, filename: String? = nil, mtime: Date? = nil) -> Data {
        var out = Data()
        do { try compress(next: CompressionStream.once(data), sink: { out.append($0) },
                          filename: filename, mtime: mtime) } catch { return Data() }
        return out
    }

    /// Comprime de `input` a `output` en **streaming** (memoria constante): produce el
    /// mismo flujo gzip que `compress(_:)` pero sin cargar el fichero entero en RAM.
    public static func compress(from input: FileHandle, to output: FileHandle,
                                filename: String? = nil, mtime: Date? = nil) throws {
        try compress(next: CompressionStream.reader(input), sink: { try output.write(contentsOf: $0) },
                     filename: filename, mtime: mtime)
    }

    /// Cabecera gzip (RFC 1952): magic + método + flags + MTIME + nombre opcional.
    private static func header(filename: String?, mtime: Date?) -> Data {
        var out = Data()
        out.append(contentsOf: [0x1F, 0x8B, 0x08])          // magic + CM=deflate
        out.append(filename != nil ? 0x08 : 0x00)           // FLG (FNAME)
        let time = UInt32(truncatingIfNeeded: Int(mtime?.timeIntervalSince1970 ?? 0))
        out.append(contentsOf: le32(time))                  // MTIME
        out.append(0x00)                                    // XFL
        out.append(0xFF)                                    // OS = desconocido
        if let filename {
            out.append(contentsOf: Array(filename.utf8))
            out.append(0x00)                                // nombre terminado en NUL
        }
        return out
    }

    /// Descomprime un flujo gzip a memoria. Verifica CRC-32 y tamaño.
    public static func decompress(_ data: Data) throws -> Data {
        var out = Data()
        try decompress(data, sink: { out.append($0) })
        return out
    }

    /// Descomprime un flujo gzip emitiendo la salida por trozos (`sink`), sin materializar
    /// el resultado en RAM. Verifica CRC-32 y tamaño del footer al vuelo. La entrada (ya en
    /// memoria/mapeada) se recorre en trozos; lo grande es la salida, que va al `sink`.
    public static func decompress(_ data: Data, sink: (Data) throws -> Void) throws {
        let count = data.count
        let base = data.startIndex
        func u8(_ i: Int) -> UInt8 { data[base + i] }
        func read32(_ i: Int) -> UInt32 {
            UInt32(u8(i)) | (UInt32(u8(i + 1)) << 8) | (UInt32(u8(i + 2)) << 16) | (UInt32(u8(i + 3)) << 24)
        }
        guard count >= 18, u8(0) == 0x1F, u8(1) == 0x8B, u8(2) == 0x08 else { throw GzipError.notGzip }
        let flags = u8(3)
        var p = 10
        if flags & 0x04 != 0 {                                     // FEXTRA
            guard p + 2 <= count else { throw GzipError.corrupt }
            p += 2 + (Int(u8(p)) | (Int(u8(p + 1)) << 8))
        }
        if flags & 0x08 != 0 { while p < count, u8(p) != 0 { p += 1 }; p += 1 }   // FNAME
        if flags & 0x10 != 0 { while p < count, u8(p) != 0 { p += 1 }; p += 1 }   // FCOMMENT
        if flags & 0x02 != 0 { p += 2 }                                           // FHCRC
        guard p <= count - 8 else { throw GzipError.corrupt }

        let crc = read32(count - 8)
        let isize = read32(count - 4)
        let body = data[(base + p)..<(base + count - 8)]           // slice sin copia
        var acc = CRC32.Accumulator()
        var total: UInt64 = 0
        do {
            try CompressionStream.run(operation: COMPRESSION_STREAM_DECODE, algorithm: COMPRESSION_ZLIB,
                next: CompressionStream.once(body),
                sink: { chunk in acc.update(chunk); total += UInt64(chunk.count); try sink(chunk) })
        } catch is CompressionStreamError { throw GzipError.corrupt }
        guard acc.final == crc, UInt32(truncatingIfNeeded: total) == isize else { throw GzipError.corrupt }
    }

    /// Una entrada `ArchiveEntry` que representa el único fichero de un `.gz`
    /// (para navegarlo). La extracción se hace con `decompress`.
    public static func entries(in data: Data, fallbackName: String) -> [ArchiveEntry] {
        let bytes = [UInt8](data)
        let size = bytes.count >= 4 ? UInt64(read32(bytes, bytes.count - 4)) : 0
        return [ArchiveEntry(
            path: storedFilename(data) ?? fallbackName,
            compressedSize: UInt64(data.count), uncompressedSize: size,
            isDirectory: false, modificationDate: nil, isEncrypted: false)]
    }

    /// Nombre del fichero contenido (de la cabecera FNAME), si lo hay.
    public static func storedFilename(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, (bytes[3] & 0x08) != 0 else { return nil }
        var p = 10
        if bytes[3] & 0x04 != 0, p + 2 <= bytes.count {
            p += 2 + (Int(bytes[p]) | (Int(bytes[p + 1]) << 8))
        }
        var name = [UInt8]()
        while p < bytes.count, bytes[p] != 0 { name.append(bytes[p]); p += 1 }
        return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
    }

    // MARK: - Helpers

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func read32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
