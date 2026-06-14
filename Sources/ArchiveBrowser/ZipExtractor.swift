import Foundation

public enum ExtractError: Error, Equatable {
    case corruptLocalHeader
    case unsupportedMethod(UInt16)
    case decompressionFailed
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

    /// Devuelve el contenido descomprimido de una entrada.
    public func extractedData(for entry: ArchiveEntry, in archive: Data) throws -> Data {
        let compressed = try rawCompressedData(for: entry, in: archive)
        switch entry.compressionMethod {
        case 0: // almacenado sin comprimir
            return compressed
        case 8: // deflate
            guard let out = Deflate.decompress(compressed, uncompressedSize: Int(entry.uncompressedSize)) else {
                throw ExtractError.decompressionFailed
            }
            return out
        default:
            throw ExtractError.unsupportedMethod(entry.compressionMethod)
        }
    }

    /// Localiza el inicio de los datos saltando el *local file header* variable.
    private func compressedDataStart(for entry: ArchiveEntry, in archive: Data) throws -> Int {
        let base = Int(entry.localHeaderOffset)
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
