import Foundation

public enum GzipError: Error, Equatable {
    case notGzip
    case corrupt
}

/// gzip (RFC 1952): comprime/descomprime **un** fichero (cabecera + DEFLATE +
/// CRC-32 + tamaño). Interoperable con `gzip`/`gunzip`, Finder, Keka…
public enum Gzip {

    /// Comprime `data` a un flujo gzip. `filename` opcional se guarda en la cabecera.
    public static func compress(_ data: Data, filename: String? = nil, mtime: Date? = nil) -> Data {
        var out = Data()
        out.append(contentsOf: [0x1F, 0x8B, 0x08])          // magic + CM=deflate
        let hasName = filename != nil
        out.append(hasName ? 0x08 : 0x00)                   // FLG (FNAME)
        let time = UInt32(truncatingIfNeeded: Int(mtime?.timeIntervalSince1970 ?? 0))
        out.append(contentsOf: le32(time))                  // MTIME
        out.append(0x00)                                    // XFL
        out.append(0xFF)                                    // OS = desconocido
        if let filename {
            out.append(contentsOf: Array(filename.utf8))
            out.append(0x00)                                // nombre terminado en NUL
        }
        out.append(Deflate.deflate(data))
        out.append(contentsOf: le32(CRC32.checksum(data)))
        out.append(contentsOf: le32(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    /// Descomprime un flujo gzip. Verifica CRC-32 y tamaño.
    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else {
            throw GzipError.notGzip
        }
        let flags = bytes[3]
        var p = 10
        if flags & 0x04 != 0 {                              // FEXTRA
            guard p + 2 <= bytes.count else { throw GzipError.corrupt }
            let xlen = Int(bytes[p]) | (Int(bytes[p + 1]) << 8)
            p += 2 + xlen
        }
        if flags & 0x08 != 0 { p = skipCString(bytes, from: p) }   // FNAME
        if flags & 0x10 != 0 { p = skipCString(bytes, from: p) }   // FCOMMENT
        if flags & 0x02 != 0 { p += 2 }                            // FHCRC
        guard p <= bytes.count - 8 else { throw GzipError.corrupt }

        // Footer: CRC-32(4) + ISIZE(4) al final.
        let isize = Int(read32(bytes, bytes.count - 4))
        let crc = read32(bytes, bytes.count - 8)
        let deflated = data.subdata(in: p..<(bytes.count - 8))

        guard let result = Deflate.decompress(deflated, uncompressedSize: isize) else {
            throw GzipError.corrupt
        }
        guard CRC32.checksum(result) == crc else { throw GzipError.corrupt }
        return result
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
            p += 2 + Int(bytes[p]) | (Int(bytes[p + 1]) << 8)
        }
        var name = [UInt8]()
        while p < bytes.count, bytes[p] != 0 { name.append(bytes[p]); p += 1 }
        return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
    }

    // MARK: - Helpers

    private static func skipCString(_ b: [UInt8], from: Int) -> Int {
        var p = from
        while p < b.count, b[p] != 0 { p += 1 }
        return p + 1   // saltar el NUL
    }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func read32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
