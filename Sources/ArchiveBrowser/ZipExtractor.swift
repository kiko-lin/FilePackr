import Foundation
import Compression

public enum ExtractError: Error, Equatable {
    case corruptLocalHeader
    case unsupportedMethod(UInt16)
    case decompressionFailed
    case needsPassword
    case wrongPassword
    case unsupportedEncryption   // AES u otro cifrado aún no soportado
}

/// Extrae el contenido de una entrada concreta de un ZIP, descomprimiéndola
/// sólo cuando se pide (extracción perezosa). El resto del archivo no se toca.
public struct ZipExtractor: Sendable {

    public init() {}

    /// Devuelve los bytes comprimidos en crudo de una entrada, sin descomprimir.
    /// Útil para copiar la entrada a otro ZIP sin recomprimirla.
    public func rawCompressedData(for entry: ArchiveEntry, in archive: Data) throws -> Data {
        let dataStart = try compressedDataStart(for: entry, in: archive)
        let end = dataStart + Int(entry.compressedSize)
        guard end <= archive.count else { throw ExtractError.corruptLocalHeader }
        return archive.subdata(in: dataStart..<end)
    }

    /// Devuelve el contenido descomprimido de una entrada. Si está cifrada con
    /// ZipCrypto, hay que pasar `password`.
    public func extractedData(for entry: ArchiveEntry, in archive: Data, password: String? = nil) throws -> Data {
        guard let zip = entry.zip else { throw ExtractError.corruptLocalHeader }
        var compressed = try rawCompressedData(for: entry, in: archive)
        var method = zip.compressionMethod

        if entry.isEncrypted {
            guard let password else { throw ExtractError.needsPassword }
            if entry.isAESEncrypted {
                guard let strength = zip.aesStrength else { throw ExtractError.unsupportedEncryption }
                do {
                    compressed = Data(try ZipAES.decrypt([UInt8](compressed), password: password, strength: strength))
                } catch ZipAESError.wrongPassword {
                    throw ExtractError.wrongPassword
                } catch {
                    throw ExtractError.decompressionFailed
                }
                method = zip.aesRealMethod ?? 8
            } else {
                compressed = try decryptZipCrypto(compressed, entry: entry, password: password)
            }
        }

        switch method {
        case 0: // almacenado sin comprimir
            return compressed
        case 8: // deflate
            guard let out = Deflate.decompress(compressed, uncompressedSize: Int(entry.uncompressedSize)) else {
                throw ExtractError.decompressionFailed
            }
            return out
        default:
            throw ExtractError.unsupportedMethod(method)
        }
    }

    /// Extrae una entrada emitiendo el contenido en claro por trozos (`sink`), **sin
    /// materializar la salida descomprimida en RAM**. Descifra (ZipCrypto/AES) e infla al
    /// vuelo; en AES verifica el MAC al terminar (la contraseña ya se valida al empezar).
    /// El archivo origen ya está en memoria/mapeado; lo grande es la salida.
    public func extract(_ entry: ArchiveEntry, in archive: Data, password: String? = nil,
                        sink: (Data) throws -> Void) throws {
        guard let zip = entry.zip else { throw ExtractError.corruptLocalHeader }
        let dataStart = try compressedDataStart(for: entry, in: archive)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= archive.count else { throw ExtractError.corruptLocalHeader }

        var method = zip.compressionMethod
        var next: () throws -> Data?         // trozos ya descifrados (texto comprimido en claro)
        var finalize: () throws -> Void = {} // verificación posterior (MAC de AES)

        if entry.isEncrypted {
            guard let password else { throw ExtractError.needsPassword }
            if entry.isAESEncrypted {
                guard let strength = zip.aesStrength else { throw ExtractError.unsupportedEncryption }
                let saltLen = ZipAES.saltLength(strength)
                guard dataEnd - dataStart >= saltLen + 2 + 10 else { throw ExtractError.wrongPassword }
                let salt = [UInt8](archive.subdata(in: dataStart..<(dataStart + saltLen)))
                let pv = [UInt8](archive.subdata(in: (dataStart + saltLen)..<(dataStart + saltLen + 2)))
                let mac = [UInt8](archive.subdata(in: (dataEnd - 10)..<dataEnd))
                var dec: ZipAES.Decryptor
                do { dec = try ZipAES.Decryptor(password: password, strength: strength, salt: salt, pv: pv) }
                catch { throw ExtractError.wrongPassword }
                let chunks = rangeChunks(archive, (dataStart + saltLen + 2)..<(dataEnd - 10))
                next = { chunks().map { Data(dec.update([UInt8]($0))) } }
                finalize = { do { try dec.verify(mac) } catch { throw ExtractError.wrongPassword } }
                method = zip.aesRealMethod ?? 8
            } else {
                // ZipCrypto: 12 bytes de cabecera de verificación, luego flujo cifrado.
                guard dataEnd - dataStart >= 12 else { throw ExtractError.wrongPassword }
                var cipher = ZipCrypto(password: password)
                let header = cipher.decrypt([UInt8](archive.subdata(in: dataStart..<(dataStart + 12))))
                let expected = zip.flags & 0x0008 != 0
                    ? UInt8((zip.dosTime >> 8) & 0xFF) : UInt8((zip.crc32 >> 24) & 0xFF)
                guard header[11] == expected else { throw ExtractError.wrongPassword }
                let chunks = rangeChunks(archive, (dataStart + 12)..<dataEnd)
                next = { chunks().map { Data(cipher.decrypt([UInt8]($0))) } }
            }
        } else {
            next = rangeChunks(archive, dataStart..<dataEnd)
        }

        switch method {
        case 0:   // almacenado sin comprimir
            while let chunk = try next() { try sink(chunk) }
        case 8:   // deflate
            do {
                try CompressionStream.run(operation: COMPRESSION_STREAM_DECODE, algorithm: COMPRESSION_ZLIB,
                                          next: next, sink: sink)
            } catch is CompressionStreamError { throw ExtractError.decompressionFailed }
        default:
            throw ExtractError.unsupportedMethod(method)
        }
        try finalize()
    }

    /// Iterador de trozos de `size` bytes sobre el rango `range` de `data` (sin cargar todo).
    private func rangeChunks(_ data: Data, _ range: Range<Int>, size: Int = 64 * 1024) -> () -> Data? {
        var offset = range.lowerBound
        return {
            guard offset < range.upperBound else { return nil }
            let end = min(offset + size, range.upperBound)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    /// Descifra ZipCrypto: los primeros 12 bytes son la cabecera de verificación.
    private func decryptZipCrypto(_ data: Data, entry: ArchiveEntry, password: String) throws -> Data {
        guard let zip = entry.zip else { throw ExtractError.wrongPassword }
        guard data.count >= 12 else { throw ExtractError.wrongPassword }
        var cipher = ZipCrypto(password: password)
        let decrypted = cipher.decrypt([UInt8](data))
        // El byte 11 de la cabecera verifica la contraseña: byte alto del CRC, o de
        // la hora MS-DOS si la entrada usa descriptor de datos (bit 3), como hace
        // el `zip` de Info-ZIP.
        let hasDataDescriptor = zip.flags & 0x0008 != 0
        let expected = hasDataDescriptor
            ? UInt8((zip.dosTime >> 8) & 0xFF)
            : UInt8((zip.crc32 >> 24) & 0xFF)
        guard decrypted[11] == expected else { throw ExtractError.wrongPassword }
        return Data(decrypted[12...])
    }

    /// Localiza el inicio de los datos saltando el *local file header* variable.
    private func compressedDataStart(for entry: ArchiveEntry, in archive: Data) throws -> Int {
        guard let base = entry.zip.map({ Int($0.localHeaderOffset) }) else { throw ExtractError.corruptLocalHeader }
        // local header: firma(4) + 26 bytes fijos; longitudes en 26 (nombre) y 28 (extra).
        guard base + 30 <= archive.count else { throw ExtractError.corruptLocalHeader }
        let bytes = [UInt8](archive[base..<min(base + 30, archive.count)])
        let signature = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        guard signature == 0x0403_4b50 else { throw ExtractError.corruptLocalHeader }
        let nameLen = Int(bytes[26]) | (Int(bytes[27]) << 8)
        let extraLen = Int(bytes[28]) | (Int(bytes[29]) << 8)
        return base + 30 + nameLen + extraLen
    }
}
