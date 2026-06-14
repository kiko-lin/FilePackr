import Foundation

/// Origen del contenido de una entrada a escribir.
public enum ZipEntrySource: Sendable {
    case directory
    /// Datos en memoria (se comprimen con DEFLATE).
    case data(Data)
    /// Fichero en disco: se lee y comprime al vuelo (streaming, sin cargar todo).
    case file(URL)
    /// Entrada que viene de otro ZIP: se copia tal cual, sin recomprimir.
    case rawEntry(method: UInt16, crc32: UInt32, compressed: Data, uncompressedSize: UInt64)
}

/// Una entrada a escribir dentro del ZIP.
public struct ZipEntryInput: Sendable {
    public let path: String
    public let modifiedAt: Date?
    public let source: ZipEntrySource

    public init(path: String, modifiedAt: Date?, source: ZipEntrySource) {
        self.path = path
        self.modifiedAt = modifiedAt
        self.source = source
    }
}

/// Cifrado a aplicar al escribir el ZIP.
public enum ZipEncryption: Sendable, Equatable {
    case none
    /// ZipCrypto / PKWARE clásico ("Débil"). Interoperable pero inseguro.
    case zipCrypto
    /// AES de WinZip ("Fuerte"). Interoperable y seguro.
    case aes256
}

/// Escribe ficheros ZIP. Soporta dos modos sobre el mismo núcleo:
/// - `build`: en memoria (para el guardado cifrado, que necesita los bytes).
/// - `write`: en streaming a un `FileHandle` (no carga el zip entero en memoria).
/// Emite estructuras ZIP64 automáticamente cuando una entrada o el archivo
/// superan los límites de 32 bits (4 GB de tamaño/offset o 65.535 entradas).
public struct ZipWriter: Sendable {

    public init() {}

    /// Construye el ZIP en memoria y lo devuelve.
    public func build(_ inputs: [ZipEntryInput], encryption: ZipEncryption = .none,
                      password: String? = nil, progress: ((Double) -> Void)? = nil) throws -> Data {
        var out = Data()
        try writeStream(inputs, encryption: encryption, password: password, progress: progress) { out.append($0) }
        return out
    }

    /// Escribe el ZIP directamente a `handle` (streaming a disco).
    public func write(_ inputs: [ZipEntryInput], to handle: FileHandle, encryption: ZipEncryption = .none,
                      password: String? = nil, progress: ((Double) -> Void)? = nil) throws {
        try writeStream(inputs, encryption: encryption, password: password, progress: progress) {
            try handle.write(contentsOf: $0)
        }
    }

    // MARK: - Núcleo

    private func writeStream(_ inputs: [ZipEntryInput], encryption: ZipEncryption, password: String?,
                             progress: ((Double) -> Void)?, sink: (Data) throws -> Void) throws {
        var offset: UInt64 = 0
        var central = Data()
        var count = 0
        func emit(_ data: Data) throws { try sink(data); offset += UInt64(data.count) }

        for (index, input) in inputs.enumerated() {
            var record = try makeRecord(input)
            if let password, !record.isDirectory {
                switch encryption {
                case .none: break
                case .zipCrypto: record = encryptZipCrypto(record, password: password)
                case .aes256: record = encryptAES(record, password: password)
                }
            }
            let localOffset = offset
            try emit(localHeader(record))
            try emit(record.compressed)
            central.append(centralHeader(record, localOffset: localOffset))
            count += 1
            if !inputs.isEmpty { progress?(Double(index + 1) / Double(inputs.count)) }
        }

        let cdOffset = offset
        try emit(central)
        try emit(endRecords(count: count, cdSize: UInt64(central.count), cdOffset: cdOffset))
    }

    // MARK: - Registro por entrada

    private struct Record {
        let nameBytes: Data
        let method: UInt16
        let crc32: UInt32
        let compressed: Data
        let uncompressedSize: UInt64
        let isDirectory: Bool
        let dosTime: UInt16
        let dosDate: UInt16
        var flags: UInt16 = 0
        /// Si está cifrada con AES, fuerza (1/2/3) y método de compresión real.
        var aes: (strength: UInt8, realMethod: UInt16)?
        var compressedSize: UInt64 { UInt64(compressed.count) }
        var needsZip64Sizes: Bool { uncompressedSize >= 0xFFFF_FFFF || compressedSize >= 0xFFFF_FFFF }
        /// Método que va en la cabecera (99 si AES) y CRC (0 en AE-2).
        var headerMethod: UInt16 { aes != nil ? 99 : method }
        var headerCRC: UInt32 { aes != nil ? 0 : crc32 }
    }

    private func makeRecord(_ input: ZipEntryInput) throws -> Record {
        let (time, date) = Self.dosDateTime(input.modifiedAt)
        switch input.source {
        case .directory:
            let name = input.path.hasSuffix("/") ? input.path : input.path + "/"
            return Record(nameBytes: Data(name.utf8), method: 0, crc32: 0, compressed: Data(),
                          uncompressedSize: 0, isDirectory: true, dosTime: time, dosDate: date)
        case .data(let data):
            return fileRecord(path: input.path, data: data, time: time, date: date)
        case .file(let url):
            return fileRecord(path: input.path, data: try Data(contentsOf: url), time: time, date: date)
        case .rawEntry(let method, let crc, let compressed, let uncompressedSize):
            return Record(nameBytes: Data(input.path.utf8), method: method, crc32: crc, compressed: compressed,
                          uncompressedSize: uncompressedSize, isDirectory: input.path.hasSuffix("/"),
                          dosTime: time, dosDate: date)
        }
    }

    private func fileRecord(path: String, data: Data, time: UInt16, date: UInt16) -> Record {
        let crc = CRC32.checksum(data)
        if let deflated = Deflate.compress(data) {
            return Record(nameBytes: Data(path.utf8), method: 8, crc32: crc, compressed: deflated,
                          uncompressedSize: UInt64(data.count), isDirectory: false, dosTime: time, dosDate: date)
        }
        return Record(nameBytes: Data(path.utf8), method: 0, crc32: crc, compressed: data,
                      uncompressedSize: UInt64(data.count), isDirectory: false, dosTime: time, dosDate: date)
    }

    /// Cifra una entrada con ZipCrypto: cabecera de 12 bytes + datos, todo con el
    /// mismo flujo de cifrado; activa el bit 0 de las banderas.
    private func encryptZipCrypto(_ record: Record, password: String) -> Record {
        var cipher = ZipCrypto(password: password)
        var header = (0..<12).map { _ in UInt8.random(in: 0...255) }
        header[11] = UInt8((record.crc32 >> 24) & 0xFF)
        var encrypted = cipher.encrypt(header)
        encrypted.append(contentsOf: cipher.encrypt([UInt8](record.compressed)))
        return Record(nameBytes: record.nameBytes, method: record.method, crc32: record.crc32,
                      compressed: Data(encrypted), uncompressedSize: record.uncompressedSize,
                      isDirectory: false, dosTime: record.dosTime, dosDate: record.dosDate, flags: 0x0001)
    }

    /// Cifra una entrada con AES de WinZip (AE-2). La cabecera lleva método 99 y un
    /// campo extra 0x9901 que indica fuerza y método real; el CRC va a 0.
    private func encryptAES(_ record: Record, password: String) -> Record {
        let stored = ZipAES.encrypt([UInt8](record.compressed), password: password, strength: ZipAES.strength256)
        return Record(nameBytes: record.nameBytes, method: record.method, crc32: record.crc32,
                      compressed: Data(stored), uncompressedSize: record.uncompressedSize,
                      isDirectory: false, dosTime: record.dosTime, dosDate: record.dosDate,
                      flags: 0x0001, aes: (ZipAES.strength256, record.method))
    }

    /// Campo extra 0x9901 (AES de WinZip): versión 2, vendor "AE", fuerza, método real.
    private func aesExtra(_ record: Record) -> Data {
        guard let aes = record.aes else { return Data() }
        var e = Data()
        e.appendU16(0x9901)
        e.appendU16(7)
        e.appendU16(2)                       // AE-2
        e.append(contentsOf: [0x41, 0x45])   // "AE"
        e.append(aes.strength)
        e.appendU16(aes.realMethod)
        return e
    }

    // MARK: - Cabeceras

    private func localHeader(_ record: Record) -> Data {
        let zip64 = record.needsZip64Sizes
        var extra = Data()
        if zip64 {
            extra.appendU16(0x0001)
            extra.appendU16(16)
            extra.appendU64(record.uncompressedSize)
            extra.appendU64(record.compressedSize)
        }
        extra.append(aesExtra(record))
        var h = Data()
        h.appendU32(0x0403_4b50)
        h.appendU16(zip64 ? 45 : 20)
        h.appendU16(record.flags)
        h.appendU16(record.headerMethod)
        h.appendU16(record.dosTime)
        h.appendU16(record.dosDate)
        h.appendU32(record.headerCRC)
        h.appendU32(zip64 ? 0xFFFF_FFFF : UInt32(record.compressedSize))
        h.appendU32(zip64 ? 0xFFFF_FFFF : UInt32(record.uncompressedSize))
        h.appendU16(UInt16(record.nameBytes.count))
        h.appendU16(UInt16(extra.count))
        h.append(record.nameBytes)
        h.append(extra)
        return h
    }

    private func centralHeader(_ record: Record, localOffset: UInt64) -> Data {
        let needSizes = record.needsZip64Sizes
        let needOffset = localOffset >= 0xFFFF_FFFF
        let zip64 = needSizes || needOffset

        var body = Data()
        if needSizes {
            body.appendU64(record.uncompressedSize)
            body.appendU64(record.compressedSize)
        }
        if needOffset { body.appendU64(localOffset) }
        var extra = Data()
        if zip64 {
            extra.appendU16(0x0001)
            extra.appendU16(UInt16(body.count))
            extra.append(body)
        }
        extra.append(aesExtra(record))

        var h = Data()
        h.appendU32(0x0201_4b50)
        h.appendU16(zip64 ? 45 : 20)
        h.appendU16(zip64 ? 45 : 20)
        h.appendU16(record.flags)
        h.appendU16(record.headerMethod)
        h.appendU16(record.dosTime)
        h.appendU16(record.dosDate)
        h.appendU32(record.headerCRC)
        h.appendU32(needSizes ? 0xFFFF_FFFF : UInt32(record.compressedSize))
        h.appendU32(needSizes ? 0xFFFF_FFFF : UInt32(record.uncompressedSize))
        h.appendU16(UInt16(record.nameBytes.count))
        h.appendU16(UInt16(extra.count))
        h.appendU16(0)                                   // comentario
        h.appendU16(0)                                   // disco
        h.appendU16(0)                                   // attrs internos
        h.appendU32(record.isDirectory ? 0x10 : 0)       // attrs externos
        h.appendU32(needOffset ? 0xFFFF_FFFF : UInt32(localOffset))
        h.append(record.nameBytes)
        h.append(extra)
        return h
    }

    private func endRecords(count: Int, cdSize: UInt64, cdOffset: UInt64) -> Data {
        var d = Data()
        let needZip64 = count > 0xFFFF || cdSize >= 0xFFFF_FFFF || cdOffset >= 0xFFFF_FFFF

        if needZip64 {
            let zip64EocdOffset = cdOffset + cdSize
            // ZIP64 End Of Central Directory record
            d.appendU32(0x0606_4b50)
            d.appendU64(44)                              // tamaño del resto del registro
            d.appendU16(45)
            d.appendU16(45)
            d.appendU32(0)
            d.appendU32(0)
            d.appendU64(UInt64(count))
            d.appendU64(UInt64(count))
            d.appendU64(cdSize)
            d.appendU64(cdOffset)
            // ZIP64 EOCD locator
            d.appendU32(0x0706_4b50)
            d.appendU32(0)
            d.appendU64(zip64EocdOffset)
            d.appendU32(1)
        }

        // End Of Central Directory
        d.appendU32(0x0605_4b50)
        d.appendU16(0)
        d.appendU16(0)
        d.appendU16(UInt16(min(count, 0xFFFF)))
        d.appendU16(UInt16(min(count, 0xFFFF)))
        d.appendU32(cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize))
        d.appendU32(cdOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdOffset))
        d.appendU16(0)
        return d
    }

    /// Codifica una fecha en formato MS-DOS (hora, fecha). `nil` → ceros.
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
    mutating func appendU64(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (8 * i)) & 0xFF)) }
    }
}
