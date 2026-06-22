import Foundation

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
/// Soporta **ZIP64** (>4 GB o >65.535 entradas) y lee los metadatos de **cifrado**
/// (ZipCrypto y AES de WinZip) de cada entrada. La extracción/descifrado en sí vive
/// en `ZipExtractor`; aquí solo se indexa el central directory.
public struct ZipReader: Sendable {

    public init() {}

    /// Lista las entradas del ZIP en `url`. Usa mapeo en memoria para no copiar
    /// el fichero entero cuando es grande.
    public func listEntries(at url: URL) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try listEntries(in: data)
    }

    /// Lista las entradas de un ZIP en memoria. Para no copiar el fichero entero
    /// (que puede ser de varios GB), sólo lee la **cola** (EOCD + ZIP64) y la
    /// región del **central directory**; lo demás no se toca.
    public func listEntries(in data: Data, progress: ((Double) -> Void)? = nil) throws -> [ArchiveEntry] {
        let fileSize = data.count
        guard fileSize >= 22 else { throw ArchiveError.notZipArchive }

        // 1. Cola: EOCD + comentario (≤64 KB) + posible EOCD64 record (56) y locator (20).
        let tailLen = min(fileSize, 22 + 0xFFFF + 20 + 56)
        let tail = [UInt8](data.subdata(in: (fileSize - tailLen)..<fileSize))
        let tailBase = fileSize - tailLen
        guard let eocd = findEOCD(tail) else { throw ArchiveError.notZipArchive }

        // 2. Número de entradas, tamaño y offset del central directory (con ZIP64).
        var entryCount = Int(readU16(tail, eocd + 10))
        var cdSize = UInt64(readU32(tail, eocd + 12))
        var cdOffset = UInt64(readU32(tail, eocd + 16))

        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF,
           eocd >= 20, readU32(tail, eocd - 20) == 0x0706_4b50,
           let record = zip64Record(in: data, at: Int(readU64(tail, eocd - 20 + 8)), tail: tail, tailBase: tailBase) {
            entryCount = Int(readU64(record, 24))   // total de entradas
            cdSize = readU64(record, 40)
            cdOffset = readU64(record, 48)
        }

        // 3. Leer SOLO la región del central directory.
        let cdStart = Int(cdOffset)
        let cdEnd = min(cdStart + Int(cdSize), fileSize)
        guard cdStart >= 0, cdStart <= cdEnd else { throw ArchiveError.corruptCentralDirectory }
        let cd = [UInt8](data.subdata(in: cdStart..<cdEnd))

        // 4. Parsear las entradas (offsets relativos a `cd`).
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(entryCount)
        var p = 0
        for index in 0..<entryCount {
            guard p + 46 <= cd.count, readU32(cd, p) == 0x0201_4b50 else {
                throw ArchiveError.corruptCentralDirectory
            }
            let flags = readU16(cd, p + 8)
            let method = readU16(cd, p + 10)
            let modTime = readU16(cd, p + 12)
            let modDate = readU16(cd, p + 14)
            let crc = readU32(cd, p + 16)
            let raw32Comp = readU32(cd, p + 20)
            let raw32Uncomp = readU32(cd, p + 24)
            let nameLen = Int(readU16(cd, p + 28))
            let extraLen = Int(readU16(cd, p + 30))
            let commentLen = Int(readU16(cd, p + 32))
            let raw32Offset = readU32(cd, p + 42)

            let nameStart = p + 46
            guard nameStart + nameLen + extraLen <= cd.count else {
                throw ArchiveError.corruptCentralDirectory
            }
            let name = String(decoding: cd[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            // ZIP64: si algún campo de 32 bits está saturado, el valor real está
            // en el campo extra (id 0x0001).
            var compSize = UInt64(raw32Comp)
            var uncompSize = UInt64(raw32Uncomp)
            var localOffset = UInt64(raw32Offset)
            if raw32Comp == 0xFFFF_FFFF || raw32Uncomp == 0xFFFF_FFFF || raw32Offset == 0xFFFF_FFFF {
                let z = zip64Extra(cd, start: nameStart + nameLen, length: extraLen,
                                   needUncomp: raw32Uncomp == 0xFFFF_FFFF,
                                   needComp: raw32Comp == 0xFFFF_FFFF,
                                   needOffset: raw32Offset == 0xFFFF_FFFF)
                if let v = z.uncomp { uncompSize = v }
                if let v = z.comp { compSize = v }
                if let v = z.offset { localOffset = v }
            }

            // AES de WinZip: el campo extra 0x9901 da la fuerza y el método real.
            var aesStrength: UInt8?
            var aesRealMethod: UInt16?
            if method == 99, let aes = aesExtra(cd, start: nameStart + nameLen, length: extraLen) {
                aesStrength = aes.strength
                aesRealMethod = aes.method
            }

            entries.append(ArchiveEntry(
                path: name,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                isDirectory: name.hasSuffix("/"),
                modificationDate: Self.dosDate(time: modTime, date: modDate),
                isEncrypted: flags & 0x0001 != 0,
                zip: ZipEntryInfo(
                    compressionMethod: method,
                    crc32: crc,
                    localHeaderOffset: localOffset,
                    dosTime: modTime,
                    flags: flags,
                    aesStrength: aesStrength,
                    aesRealMethod: aesRealMethod)
            ))
            p = nameStart + nameLen + extraLen + commentLen
            if let progress, entryCount > 0 { progress(Double(index + 1) / Double(entryCount)) }
        }
        return entries
    }

    /// Lee el campo extra AES de WinZip (id 0x9901): fuerza y método real.
    private func aesExtra(_ b: [UInt8], start: Int, length: Int) -> (strength: UInt8, method: UInt16)? {
        var p = start
        let end = min(start + length, b.count)
        while p + 4 <= end {
            let id = readU16(b, p)
            let size = Int(readU16(b, p + 2))
            if id == 0x9901, p + 4 + 7 <= end {
                // versión(2) + vendor(2) + fuerza(1) + método(2)
                return (b[p + 4 + 4], readU16(b, p + 4 + 5))
            }
            p += 4 + size
        }
        return nil
    }

    /// Lee el registro ZIP64 EOCD (56 bytes) en `offset`, de la cola si está ahí
    /// o del fichero en otro caso. `nil` si la firma no cuadra.
    private func zip64Record(in data: Data, at offset: Int, tail: [UInt8], tailBase: Int) -> [UInt8]? {
        guard offset >= 0 else { return nil }
        let record: [UInt8]
        if offset >= tailBase, offset - tailBase + 56 <= tail.count {
            record = Array(tail[(offset - tailBase)..<(offset - tailBase + 56)])
        } else if offset + 56 <= data.count {
            record = [UInt8](data.subdata(in: offset..<(offset + 56)))
        } else {
            return nil
        }
        return readU32(record, 0) == 0x0606_4b50 ? record : nil
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
