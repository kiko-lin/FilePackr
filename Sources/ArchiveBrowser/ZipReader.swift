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
    public func listEntries(in data: Data) throws -> [ArchiveEntry] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { throw ArchiveError.notZipArchive }

        let entryCount = readU16(bytes, eocd + 10)
        let cdOffset = Int(readU32(bytes, eocd + 16))

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(entryCount))

        var p = cdOffset
        for _ in 0..<entryCount {
            guard p + 46 <= bytes.count, readU32(bytes, p) == 0x0201_4b50 else {
                throw ArchiveError.corruptCentralDirectory
            }
            let method = readU16(bytes, p + 10)
            let crc = readU32(bytes, p + 16)
            let compSize = UInt64(readU32(bytes, p + 20))
            let uncompSize = UInt64(readU32(bytes, p + 24))
            let nameLen = Int(readU16(bytes, p + 28))
            let extraLen = Int(readU16(bytes, p + 30))
            let commentLen = Int(readU16(bytes, p + 32))
            let localOffset = UInt64(readU32(bytes, p + 42))

            let nameStart = p + 46
            guard nameStart + nameLen <= bytes.count else {
                throw ArchiveError.corruptCentralDirectory
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            entries.append(ArchiveEntry(
                path: name,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                isDirectory: name.hasSuffix("/"),
                compressionMethod: method,
                crc32: crc,
                localHeaderOffset: localOffset
            ))
            p = nameStart + nameLen + extraLen + commentLen
        }
        return entries
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

    private func readU16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
