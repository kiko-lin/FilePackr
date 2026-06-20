import Foundation

/// Resultado de abrir un contenedor: el formato (posiblemente **refinado** —p. ej. un
/// `.gz` que en realidad es un `.tar.gz`—), los bytes que hay que conservar para
/// extraer entradas después (`container`) y la lista de entradas.
public struct ArchiveReadResult: Sendable {
    public let format: ArchiveFormat
    public let container: Data
    public let entries: [ArchiveEntry]

    public init(format: ArchiveFormat, container: Data, entries: [ArchiveEntry]) {
        self.format = format
        self.container = container
        self.entries = entries
    }
}

/// Abstracción de **lectura/extracción** por formato. Centraliza en un único sitio el
/// `switch` que antes estaba repartido por el documento (abrir un archivo y extraer
/// una entrada suelta). Añadir un formato = un nuevo codec + su `case` en el registro.
///
/// La escritura tiene rutas demasiado dispares (streaming ZIP con copia en crudo,
/// libarchive a fichero, formatos de un solo fichero) y se gestiona aparte.
public protocol ArchiveCodec: Sendable {
    /// Abre `data` y devuelve sus entradas. `fallbackName` nombra la entrada sintética
    /// de los formatos de un solo fichero (gz/xz/bz2). `progress` solo lo usa ZIP.
    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult

    /// Datos en claro de una entrada, leídos del `container` que devolvió `open`.
    func entryData(for entry: ArchiveEntry, in container: Data, password: String?) throws -> Data
}

public extension ArchiveCodec {
    /// Sobrecarga cómoda para abrir sin progreso.
    func open(_ data: Data, fallbackName: String, passphrase: String? = nil) throws -> ArchiveReadResult {
        try open(data, fallbackName: fallbackName, passphrase: passphrase, progress: nil)
    }
}

public extension ArchiveFormat {
    /// Codec que sabe leer/extraer este formato (registro formato → codec).
    var codec: any ArchiveCodec {
        switch self {
        case .zip:
            return ZipCodec()
        case .tar:
            return TarCodec(format: .tar, decompress: { $0 })
        case .tarGzip:
            return TarCodec(format: .tarGzip, decompress: { try Gzip.decompress($0) })
        case .tarXz:
            return TarCodec(format: .tarXz, decompress: { try Xz.decompress($0) })
        case .tarBzip2:
            return TarCodec(format: .tarBzip2, decompress: { try Bzip2.decompress($0) })
        case .gzip:
            return SingleFileCodec(format: .gzip, tarFormat: .tarGzip,
                                   decompress: { try Gzip.decompress($0) },
                                   entries: { Gzip.entries(in: $0, fallbackName: $1) })
        case .xz:
            return SingleFileCodec(format: .xz, tarFormat: .tarXz,
                                   decompress: { try Xz.decompress($0) },
                                   entries: { Xz.entries(in: $0, fallbackName: $1) })
        case .bzip2:
            return SingleFileCodec(format: .bzip2, tarFormat: .tarBzip2,
                                   decompress: { try Bzip2.decompress($0) },
                                   entries: { Bzip2.entries(in: $0, fallbackName: $1) })
        case .sevenZip, .rar, .iso, .cpio, .xar, .lha, .cab:
            return LibArchiveCodec(format: self)
        }
    }
}

// MARK: - Codecs concretos

/// ZIP en Swift puro (índice por central directory + extracción/descifrado perezosos).
struct ZipCodec: ArchiveCodec {
    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        let entries = try ZipReader().listEntries(in: data, progress: progress)
        return ArchiveReadResult(format: .zip, container: data, entries: entries)
    }

    func entryData(for entry: ArchiveEntry, in container: Data, password: String?) throws -> Data {
        try ZipExtractor().extractedData(for: entry, in: container, password: password)
    }
}

/// TAR, opcionalmente envuelto en un compresor (gzip/xz/bzip2). El `container` que se
/// conserva es el TAR ya descomprimido, así que extraer es leer una porción.
struct TarCodec: ArchiveCodec {
    let format: ArchiveFormat
    let decompress: @Sendable (Data) throws -> Data

    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        let tar = try decompress(data)
        return ArchiveReadResult(format: format, container: tar, entries: try Tar.listEntries(in: tar))
    }

    func entryData(for entry: ArchiveEntry, in container: Data, password: String?) throws -> Data {
        try Tar.entryData(for: entry, in: container)
    }
}

/// Formatos de un solo fichero (gzip/xz/bzip2). Al abrir distingue un fichero suelto de
/// un `.tar.<x>` mirando la firma ustar tras descomprimir; si es un TAR, refina el
/// formato a su variante y delega en TAR. El `container` conserva los bytes originales.
struct SingleFileCodec: ArchiveCodec {
    let format: ArchiveFormat
    let tarFormat: ArchiveFormat
    let decompress: @Sendable (Data) throws -> Data
    let entries: @Sendable (Data, String) -> [ArchiveEntry]

    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        let inner = try decompress(data)
        if Tar.hasUstarMagic(inner) {
            return ArchiveReadResult(format: tarFormat, container: inner, entries: try Tar.listEntries(in: inner))
        }
        return ArchiveReadResult(format: format, container: data, entries: entries(data, fallbackName))
    }

    func entryData(for entry: ArchiveEntry, in container: Data, password: String?) throws -> Data {
        try decompress(container)
    }
}

/// Formatos que pasan por la libarchive del sistema (7z/rar/iso/cpio/xar/lha/cab).
struct LibArchiveCodec: ArchiveCodec {
    let format: ArchiveFormat

    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        let (entries, _) = try LibArchive.listEntries(in: data, passphrase: passphrase)
        return ArchiveReadResult(format: format, container: data, entries: entries)
    }

    func entryData(for entry: ArchiveEntry, in container: Data, password: String?) throws -> Data {
        try LibArchive.extractEntry(path: entry.path, in: container, passphrase: password)
    }
}
