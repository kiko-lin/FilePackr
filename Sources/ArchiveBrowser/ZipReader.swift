import Foundation

/// Una entrada dentro de un archivo comprimido, leída SIN descomprimir su contenido.
public struct ArchiveEntry: Equatable, Identifiable, Sendable {
    public var id: String { path }
    /// Ruta completa dentro del archivo, p.ej. "docs/anidado.txt".
    public let path: String
    /// Tamaño que ocupa comprimida dentro del archivo.
    public let compressedSize: UInt64
    /// Tamaño real una vez descomprimida.
    public let uncompressedSize: UInt64
    /// `true` si es una carpeta (la ruta acaba en "/").
    public let isDirectory: Bool
    /// Método de compresión ZIP (0 = almacenado, 8 = deflate).
    public let compressionMethod: UInt16
    /// CRC-32 del contenido sin comprimir (lo exige el formato ZIP).
    public let crc32: UInt32
    /// Offset del *local file header* de esta entrada dentro del ZIP.
    /// Necesario para extraer o copiar los bytes comprimidos sin releer el índice.
    public let localHeaderOffset: UInt64
    /// Fecha de modificación (campo MS-DOS del ZIP), si es válida.
    public let modificationDate: Date?
}

public enum ArchiveError: Error, Equatable {
    case notZipArchive
    case corruptCentralDirectory
}

/// Lee el *central directory* de un fichero ZIP para listar su contenido
/// sin descomprimir ni un solo byte de datos de fichero.
///
/// Esta es la pieza que permite "navegar como un explorador" un archivo:
/// el índice (nombres, tamaños, offsets) se obtiene leyendo unos pocos cientos
/// de bytes al final del ZIP, independientemente de su tamaño total.
///
/// Limitaciones conscientes del armazón: sólo ZIP, sin ZIP64 (>4 GB) y sin
/// cifrado de entradas. En producción se sustituye por libarchive para soportar
/// 7z/tar/rar y streaming de entradas individuales con la misma interfaz pública.
public struct ZipReader: Sendable {

    public init() {}

    /// Lista las entradas del ZIP en `url`. Usa mapeo en memoria para no copiar
    /// el fichero entero cuando es grande.
    public func listEntries(at url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try listEntries(in: data)
    }

    /// Lista las entradas a partir del contenido en memoria de un ZIP.
    public func listEntries(in data: Data, progress: ((Double) -> Void)? = nil) throws -> [ArchiveEntry] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { throw ArchiveError.notZipArchive }

        let (entryCount, cdOffset) = centralDirectoryInfo(bytes, eocd: eocd)

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(entryCount)

        var p = cdOffset
        for index in 0..<entryCount {
            guard p + 46 <= bytes.count, readU32(bytes, p) == 0x0201_4b50 else {
                throw ArchiveError.corruptCentralDirectory
            }
            let method = readU16(bytes, p + 10)
            let modTime = readU16(bytes, p + 12)
            let modDate = readU16(bytes, p + 14)
            let crc = readU32(bytes, p + 16)
            let raw32Comp = readU32(bytes, p + 20)
            let raw32Uncomp = readU32(bytes, p + 24)
            let nameLen = Int(readU16(bytes, p + 28))
            let extraLen = Int(readU16(bytes, p + 30))
            let commentLen = Int(readU16(bytes, p + 32))
            let raw32Offset = readU32(bytes, p + 42)

            let nameStart = p + 46
            guard nameStart + nameLen + extraLen <= bytes.count else {
                throw ArchiveError.corruptCentralDirectory
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            // ZIP64: si algún campo de 32 bits está saturado (0xFFFFFFFF), el valor
            // real de 64 bits está en el campo extra (header id 0x0001).
            var compSize = UInt64(raw32Comp)
            var uncompSize = UInt64(raw32Uncomp)
            var localOffset = UInt64(raw32Offset)
            if raw32Comp == 0xFFFF_FFFF || raw32Uncomp == 0xFFFF_FFFF || raw32Offset == 0xFFFF_FFFF {
                let z = zip64Extra(bytes, start: nameStart + nameLen, length: extraLen,
                                   needUncomp: raw32Uncomp == 0xFFFF_FFFF,
                                   needComp: raw32Comp == 0xFFFF_FFFF,
                                   needOffset: raw32Offset == 0xFFFF_FFFF)
                if let v = z.uncomp { uncompSize = v }
                if let v = z.comp { compSize = v }
                if let v = z.offset { localOffset = v }
            }

            entries.append(ArchiveEntry(
                path: name,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                isDirectory: name.hasSuffix("/"),
                compressionMethod: method,
                crc32: crc,
                localHeaderOffset: localOffset,
                modificationDate: Self.dosDate(time: modTime, date: modDate)
            ))
            p = nameStart + nameLen + extraLen + commentLen
            if let progress, entryCount > 0 { progress(Double(index + 1) / Double(entryCount)) }
        }
        return entries
    }

    /// Devuelve (número de entradas, offset del central directory), siguiendo el
    /// registro ZIP64 cuando los campos de 32 bits del EOCD están saturados.
    private func centralDirectoryInfo(_ bytes: [UInt8], eocd: Int) -> (count: Int, offset: Int) {
        let count16 = readU16(bytes, eocd + 10)
        let size32 = readU32(bytes, eocd + 12)
        let offset32 = readU32(bytes, eocd + 16)

        if count16 == 0xFFFF || size32 == 0xFFFF_FFFF || offset32 == 0xFFFF_FFFF,
           eocd >= 20, readU32(bytes, eocd - 20) == 0x0706_4b50 {
            let recordOffset = Int(readU64(bytes, eocd - 20 + 8))
            if recordOffset >= 0, recordOffset + 56 <= bytes.count,
               readU32(bytes, recordOffset) == 0x0606_4b50 {
                let count = Int(readU64(bytes, recordOffset + 32))
                let offset = Int(readU64(bytes, recordOffset + 48))
                return (count, offset)
            }
        }
        return (Int(count16), Int(offset32))
    }

    /// Lee del campo extra ZIP64 (id 0x0001) los valores de 64 bits presentes,
    /// en el orden fijo: descomprimido, comprimido, offset del local header.
    private func zip64Extra(_ bytes: [UInt8], start: Int, length: Int,
                            needUncomp: Bool, needComp: Bool, needOffset: Bool)
        -> (uncomp: UInt64?, comp: UInt64?, offset: UInt64?) {
        var p = start
        let end = min(start + length, bytes.count)
        while p + 4 <= end {
            let id = readU16(bytes, p)
            let size = Int(readU16(bytes, p + 2))
            if id == 0x0001 {
                var q = p + 4
                let fieldEnd = min(p + 4 + size, end)
                var uncomp: UInt64?, comp: UInt64?, offset: UInt64?
                if needUncomp, q + 8 <= fieldEnd { uncomp = readU64(bytes, q); q += 8 }
                if needComp, q + 8 <= fieldEnd { comp = readU64(bytes, q); q += 8 }
                if needOffset, q + 8 <= fieldEnd { offset = readU64(bytes, q); q += 8 }
                return (uncomp, comp, offset)
            }
            p += 4 + size
        }
        return (nil, nil, nil)
    }

    // MARK: - Lectura binaria (little-endian)

    /// Busca la firma End Of Central Directory (0x06054b50) desde el final.
    private func findEOCD(_ bytes: [UInt8]) -> Int? {
        let signature: UInt32 = 0x0605_4b50
        guard bytes.count >= 22 else { return nil }
        let lowerBound = bytes.count - min(bytes.count, 22 + 0xFFFF) // comentario máx 64 KB
        var i = bytes.count - 22
        while i >= lowerBound {
            if readU32(bytes, i) == signature { return i }
            i -= 1
        }
        return nil
    }

    /// Convierte la fecha/hora MS-DOS del ZIP (dos UInt16) en una `Date`.
    static func dosDate(time: UInt16, date: UInt16) -> Date? {
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        guard day > 0, month > 0 else { return nil }
        var components = DateComponents()
        components.year = Int((date >> 9) & 0x7F) + 1980
        components.month = month
        components.day = day
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return Calendar.current.date(from: components)
    }

    private func readU16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(b[o + i]) << (8 * i) }
        return value
    }
}
