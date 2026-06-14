import Foundation

/// Una unidad a escribir dentro del ZIP.
public enum ZipWriteItem {
    /// Carpeta (la ruta debe acabar en "/").
    case directory(path: String, modifiedAt: Date?)
    /// Fichero nuevo: se comprimirá con DEFLATE (o se almacenará si no compensa).
    case file(path: String, data: Data, modifiedAt: Date?)
    /// Entrada que viene de otro ZIP: se copia tal cual, sin recomprimir.
    case rawEntry(path: String, method: UInt16, crc32: UInt32, compressed: Data, uncompressedSize: UInt64, modifiedAt: Date?)
}

/// Construye un fichero ZIP en memoria a partir de una lista de elementos.
/// Genera local headers, central directory y EOCD. Sin ZIP64 (suficiente para
/// el caso de uso; el formato lo soporta hasta 4 GB por entrada).
public struct ZipWriter: Sendable {

    public init() {}

    /// Construye el ZIP. `progress` se llama tras cada elemento con la fracción
    /// completada (0…1), útil para una barra de progreso en segundo plano.
    public func build(_ items: [ZipWriteItem], progress: ((Double) -> Void)? = nil) -> Data {
        var out = Data()
        var central = Data()
        var entryCount: UInt16 = 0

        for (index, item) in items.enumerated() {
            let record = normalize(item)
            let localOffset = UInt32(out.count)

            // --- Local file header ---
            out.appendU32(0x0403_4b50)
            out.appendU16(20)                    // versión necesaria
            out.appendU16(0)                     // flags
            out.appendU16(record.method)
            out.appendU16(record.dosTime)        // hora
            out.appendU16(record.dosDate)        // fecha
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
            central.appendU16(record.dosTime)    // hora
            central.appendU16(record.dosDate)    // fecha
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
            if !items.isEmpty { progress?(Double(index + 1) / Double(items.count)) }
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
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private func normalize(_ item: ZipWriteItem) -> Record {
        switch item {
        case .directory(let path, let modifiedAt):
            let name = path.hasSuffix("/") ? path : path + "/"
            let (time, date) = Self.dosDateTime(modifiedAt)
            return Record(nameBytes: Data(name.utf8), method: 0, crc32: 0,
                          compressed: Data(), uncompressedSize: 0, isDirectory: true,
                          dosTime: time, dosDate: date)

        case .file(let path, let data, let modifiedAt):
            let crc = CRC32.checksum(data)
            let (time, date) = Self.dosDateTime(modifiedAt)
            if let deflated = Deflate.compress(data) {
                return Record(nameBytes: Data(path.utf8), method: 8, crc32: crc,
                              compressed: deflated, uncompressedSize: UInt64(data.count), isDirectory: false,
                              dosTime: time, dosDate: date)
            }
            // No compensó comprimir: almacenar sin comprimir.
            return Record(nameBytes: Data(path.utf8), method: 0, crc32: crc,
                          compressed: data, uncompressedSize: UInt64(data.count), isDirectory: false,
                          dosTime: time, dosDate: date)

        case .rawEntry(let path, let method, let crc, let compressed, let uncompressedSize, let modifiedAt):
            let (time, date) = Self.dosDateTime(modifiedAt)
            return Record(nameBytes: Data(path.utf8), method: method, crc32: crc,
                          compressed: compressed, uncompressedSize: uncompressedSize,
                          isDirectory: path.hasSuffix("/"), dosTime: time, dosDate: date)
        }
    }

    /// Codifica una fecha en el formato MS-DOS del ZIP (hora, fecha). Si es `nil`,
    /// devuelve ceros (sin fecha).
    private static func dosDateTime(_ date: Date?) -> (UInt16, UInt16) {
        guard let date else { return (0, 0) }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(127, max(0, (c.year ?? 1980) - 1980))
        let dosDate = UInt16((year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        return (dosTime, dosDate)
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
