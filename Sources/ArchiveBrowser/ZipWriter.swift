import Foundation

/// Una unidad a escribir dentro del ZIP.
public enum ZipWriteItem {
    /// Carpeta (la ruta debe acabar en "/").
    case directory(path: String)
    /// Fichero nuevo: se comprimirá con DEFLATE (o se almacenará si no compensa).
    case file(path: String, data: Data)
    /// Entrada que viene de otro ZIP: se copia tal cual, sin recomprimir.
    case rawEntry(path: String, method: UInt16, crc32: UInt32, compressed: Data, uncompressedSize: UInt64)
}

/// Construye un fichero ZIP en memoria a partir de una lista de elementos.
/// Genera local headers, central directory y EOCD. Sin ZIP64 (suficiente para
/// el caso de uso; el formato lo soporta hasta 4 GB por entrada).
public struct ZipWriter: Sendable {

    public init() {}

    public func build(_ items: [ZipWriteItem]) -> Data {
        var out = Data()
        var central = Data()
        var entryCount: UInt16 = 0

        for item in items {
            let record = normalize(item)
            let localOffset = UInt32(out.count)

            // --- Local file header ---
            out.appendU32(0x0403_4b50)
            out.appendU16(20)                    // versión necesaria
            out.appendU16(0)                     // flags
            out.appendU16(record.method)
            out.appendU16(0)                     // hora
            out.appendU16(0)                     // fecha
            out.appendU32(record.crc32)
            out.appendU32(UInt32(record.compressed.count))
            out.appendU32(UInt32(record.uncompressedSize))
            out.appendU16(UInt16(record.nameBytes.count))
            out.appendU16(0)                     // extra
            out.append(record.nameBytes)
            out.append(record.compressed)

            // --- Central directory header ---
            central.appendU32(0x0201_4b50)
            central.appendU16(20)                // versión creada por
            central.appendU16(20)                // versión necesaria
            central.appendU16(0)                 // flags
            central.appendU16(record.method)
            central.appendU16(0)                 // hora
            central.appendU16(0)                 // fecha
            central.appendU32(record.crc32)
            central.appendU32(UInt32(record.compressed.count))
            central.appendU32(UInt32(record.uncompressedSize))
            central.appendU16(UInt16(record.nameBytes.count))
            central.appendU16(0)                 // extra
            central.appendU16(0)                 // comentario
            central.appendU16(0)                 // disco
            central.appendU16(0)                 // attrs internos
            central.appendU32(record.isDirectory ? 0x10 : 0) // attrs externos (bit de directorio)
            central.appendU32(localOffset)
            central.append(record.nameBytes)

            entryCount += 1
        }

        let centralOffset = UInt32(out.count)
        out.append(central)

        // --- End Of Central Directory ---
        out.appendU32(0x0605_4b50)
        out.appendU16(0)                         // disco
        out.appendU16(0)                         // disco con central dir
        out.appendU16(entryCount)
        out.appendU16(entryCount)
        out.appendU32(UInt32(central.count))
        out.appendU32(centralOffset)
        out.appendU16(0)                         // comentario
        return out
    }

    // MARK: - Normalización de cada elemento a campos del header

    private struct Record {
        let nameBytes: Data
        let method: UInt16
        let crc32: UInt32
        let compressed: Data
        let uncompressedSize: UInt64
        let isDirectory: Bool
    }

    private func normalize(_ item: ZipWriteItem) -> Record {
        switch item {
        case .directory(let path):
            let name = path.hasSuffix("/") ? path : path + "/"
            return Record(nameBytes: Data(name.utf8), method: 0, crc32: 0,
                          compressed: Data(), uncompressedSize: 0, isDirectory: true)

        case .file(let path, let data):
            let crc = CRC32.checksum(data)
            if let deflated = Deflate.compress(data) {
                return Record(nameBytes: Data(path.utf8), method: 8, crc32: crc,
                              compressed: deflated, uncompressedSize: UInt64(data.count), isDirectory: false)
            }
            // No compensó comprimir: almacenar sin comprimir.
            return Record(nameBytes: Data(path.utf8), method: 0, crc32: crc,
                          compressed: data, uncompressedSize: UInt64(data.count), isDirectory: false)

        case .rawEntry(let path, let method, let crc, let compressed, let uncompressedSize):
            return Record(nameBytes: Data(path.utf8), method: method, crc32: crc,
                          compressed: compressed, uncompressedSize: uncompressedSize,
                          isDirectory: path.hasSuffix("/"))
        }
    }
}

// MARK: - Escritura little-endian

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
