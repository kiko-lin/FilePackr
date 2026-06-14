import Foundation

public enum TarError: Error, Equatable { case corrupt }

/// Lectura/escritura de archivos **TAR** (ustar), el contenedor Unix. Sin compresión
/// (se combina con gzip para `.tar.gz`). Lee ustar, cabeceras extendidas PAX (`x`) y
/// nombres largos GNU (`L`); escribe ustar y emite PAX para rutas que no caben.
public enum Tar {

    private static let blockSize = 512

    // MARK: - Lectura

    /// Lista las entradas del TAR. `localHeaderOffset` apunta a los datos (para extraer).
    public static func listEntries(in data: Data) throws -> [ArchiveEntry] {
        let bytes = [UInt8](data)
        var entries: [ArchiveEntry] = []
        var p = 0
        var pendingPath: String?
        var pendingSize: UInt64?
        var pendingDate: Date?

        while p + blockSize <= bytes.count {
            if isZeroBlock(bytes, at: p) { break }   // dos bloques cero = fin

            let rawName = string(bytes, p, 100)
            let prefix = string(bytes, p + 345, 155)
            let size = pendingSize ?? octal(bytes, p + 124, 12)
            let mtime = pendingDate ?? dateFrom(octal(bytes, p + 136, 12))
            let type = bytes[p + 156]
            let dataStart = p + blockSize
            let dataBlocks = (Int(size) + blockSize - 1) / blockSize

            switch type {
            case 0x78, 0x67:   // 'x' / 'g' — cabecera extendida PAX
                let header = parsePax(bytes, start: dataStart, size: Int(size))
                pendingPath = header.path
                pendingSize = header.size
                pendingDate = header.mtime
                p = dataStart + dataBlocks * blockSize
                continue
            case 0x4C:         // 'L' — nombre largo GNU
                pendingPath = string(bytes, dataStart, Int(size)).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                p = dataStart + dataBlocks * blockSize
                continue
            default:
                break
            }

            let name = pendingPath ?? (prefix.isEmpty ? rawName : prefix + "/" + rawName)
            pendingPath = nil; pendingSize = nil; pendingDate = nil

            let isDir = type == 0x35 || name.hasSuffix("/")   // '5'
            if type == 0x30 || type == 0x00 || type == 0x35 || isDir {   // ficheros y carpetas
                guard dataStart + Int(size) <= bytes.count else { throw TarError.corrupt }
                entries.append(ArchiveEntry(
                    path: name, compressedSize: size, uncompressedSize: size,
                    isDirectory: isDir, compressionMethod: 0, crc32: 0,
                    localHeaderOffset: UInt64(dataStart), modificationDate: mtime,
                    dosTime: 0, flags: 0, aesStrength: nil, aesRealMethod: nil))
            }
            p = dataStart + dataBlocks * blockSize
        }
        return entries
    }

    /// Datos (sin comprimir) de una entrada del TAR.
    public static func entryData(for entry: ArchiveEntry, in data: Data) throws -> Data {
        let start = Int(entry.localHeaderOffset)
        let end = start + Int(entry.uncompressedSize)
        guard end <= data.count else { throw TarError.corrupt }
        return data.subdata(in: start..<end)
    }

    // MARK: - Escritura

    public struct WriteItem: Sendable {
        public let path: String
        public let data: Data
        public let modifiedAt: Date?
        public let isDirectory: Bool
        public init(path: String, data: Data, modifiedAt: Date?, isDirectory: Bool) {
            self.path = path; self.data = data; self.modifiedAt = modifiedAt; self.isDirectory = isDirectory
        }
    }

    public static func write(_ items: [WriteItem]) -> Data {
        var out = Data()
        for item in items {
            let path = item.isDirectory && !item.path.hasSuffix("/") ? item.path + "/" : item.path
            // Nombre que no cabe en ustar (100 + 155 con split) → cabecera PAX previa.
            if Array(path.utf8).count > 100 {
                out.append(paxHeader(path: path))
            }
            out.append(header(path: path, size: item.isDirectory ? 0 : item.data.count,
                              mtime: item.modifiedAt, isDirectory: item.isDirectory))
            if !item.isDirectory {
                out.append(item.data)
                out.append(padding(item.data.count))
            }
        }
        out.append(Data(count: blockSize * 2))   // dos bloques cero
        return out
    }

    // MARK: - Helpers de escritura

    private static func header(path: String, size: Int, mtime: Date?, isDirectory: Bool) -> Data {
        var h = [UInt8](repeating: 0, count: blockSize)
        let nameBytes = Array(path.utf8.prefix(100))
        for (i, b) in nameBytes.enumerated() { h[i] = b }
        writeOctal(&h, 100, 8, 0o755)                 // mode
        writeOctal(&h, 108, 8, 0)                     // uid
        writeOctal(&h, 116, 8, 0)                     // gid
        writeOctal(&h, 124, 12, size)                 // size
        writeOctal(&h, 136, 12, Int(mtime?.timeIntervalSince1970 ?? 0))
        h[156] = isDirectory ? 0x35 : 0x30            // typeflag '5'/'0'
        let magic = Array("ustar\0".utf8); for (i, b) in magic.enumerated() { h[257 + i] = b }
        h[263] = 0x30; h[264] = 0x30                  // version "00"
        // checksum: con el campo a espacios
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        writeOctal(&h, 148, 7, sum)                   // 6 dígitos + NUL
        h[154] = 0x00; h[155] = 0x20
        return Data(h)
    }

    private static func paxHeader(path: String) -> Data {
        // Registro PAX: "<len> path=<ruta>\n", donde len es la longitud total del registro.
        let value = "path=" + path + "\n"
        var len = value.utf8.count + 1
        while String(len).utf8.count + 1 + value.utf8.count != len { len = String(len).utf8.count + 1 + value.utf8.count }
        let record = Data("\(len) \(value)".utf8)
        var data = header(path: "PaxHeader", size: record.count, mtime: nil, isDirectory: false)
        data[156] = 0x78   // 'x'
        // recalcular checksum tras cambiar typeflag
        var h = [UInt8](data)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        writeOctal(&h, 148, 7, sum); h[154] = 0; h[155] = 0x20
        var out = Data(h)
        out.append(record)
        out.append(padding(record.count))
        return out
    }

    private static func writeOctal(_ h: inout [UInt8], _ off: Int, _ len: Int, _ value: Int) {
        let digits = String(value, radix: 8)
        let field = String(repeating: "0", count: max(0, len - 1 - digits.count)) + digits
        for (i, c) in field.utf8.prefix(len - 1).enumerated() { h[off + i] = c }
        h[off + len - 1] = 0x00
    }

    private static func padding(_ size: Int) -> Data {
        let rem = size % blockSize
        return rem == 0 ? Data() : Data(count: blockSize - rem)
    }

    // MARK: - Helpers de lectura

    private static func isZeroBlock(_ b: [UInt8], at p: Int) -> Bool {
        for i in p..<min(p + blockSize, b.count) where b[i] != 0 { return false }
        return true
    }
    private static func string(_ b: [UInt8], _ off: Int, _ len: Int) -> String {
        let end = min(off + len, b.count)
        var slice = Array(b[off..<end])
        if let nul = slice.firstIndex(of: 0) { slice = Array(slice[0..<nul]) }
        return String(decoding: slice, as: UTF8.self)
    }
    private static func octal(_ b: [UInt8], _ off: Int, _ len: Int) -> UInt64 {
        let s = string(b, off, len).trimmingCharacters(in: .whitespaces)
        return UInt64(s, radix: 8) ?? 0
    }
    private static func dateFrom(_ epoch: UInt64) -> Date? {
        epoch == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(epoch))
    }
    private static func parsePax(_ b: [UInt8], start: Int, size: Int) -> (path: String?, size: UInt64?, mtime: Date?) {
        let end = min(start + size, b.count)
        let text = String(decoding: b[start..<end], as: UTF8.self)
        var path: String?; var sz: UInt64?; var mtime: Date?
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let kv = line[line.index(after: space)...]
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = String(kv[..<eq]); let value = String(kv[kv.index(after: eq)...])
            switch key {
            case "path": path = value
            case "size": sz = UInt64(value)
            case "mtime": mtime = Double(value).map { Date(timeIntervalSince1970: $0) }
            default: break
            }
        }
        return (path, sz, mtime)
    }
}
