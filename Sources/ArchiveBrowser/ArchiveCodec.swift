import Foundation

/// Origen de los bytes de un contenedor ya abierto, a conservar para extraer entradas después.
/// Casi siempre son bytes en memoria (`.data`, mapeados o cargados). RAR es la excepción
/// (`.rarFile`): unrar solo abre ficheros, así que se conserva la URL del `.rar` en disco (el
/// primer volumen si es multivolumen; unrar encuentra solo los siguientes) y se reabre cada vez.
public enum ArchiveContainer: Sendable {
    case data(Data)
    case rarFile(URL)
}

/// Un codec recibió un `ArchiveContainer` que no sabe interpretar. Solo `RarCodec` consume
/// `.rarFile`; el resto de codecs solo ven `.data` en la práctica.
struct UnsupportedContainerError: Error {}

/// Resultado de abrir un contenedor: el formato (posiblemente **refinado** —p. ej. un
/// `.gz` que en realidad es un `.tar.gz`—), los bytes que hay que conservar para
/// extraer entradas después (`container`) y la lista de entradas.
public struct ArchiveReadResult: Sendable {
    public let format: ArchiveFormat
    public let container: ArchiveContainer
    public let entries: [ArchiveEntry]
    /// La lectura se cortó antes de llegar al final real del archivo (p. ej. un RAR
    /// multivolumen al que le faltan partes): `entries` es lo que se pudo leer, no todo.
    public let truncated: Bool

    public init(format: ArchiveFormat, container: ArchiveContainer, entries: [ArchiveEntry], truncated: Bool = false) {
        self.format = format
        self.container = container
        self.entries = entries
        self.truncated = truncated
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
    func entryData(for entry: ArchiveEntry, in container: ArchiveContainer, password: String?) throws -> Data

    /// Extrae una entrada emitiendo el contenido en claro por trozos (`sink`), **sin
    /// materializar la salida en RAM** cuando el formato lo permite (ZIP, gz/xz/bz2).
    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws

    /// Extrae varias entradas en el **mínimo número de pases**. Por cada entrada que el codec
    /// recorre, `place(entry)` devuelve un sink donde volcar su contenido (en streaming) o `nil`
    /// para saltarla. Las llamadas a `place` van en el orden de recorrido del codec; una entrada
    /// se considera **terminada** cuando empieza la siguiente (o al volver de este método), para
    /// que el llamador pueda cerrar/colocar cada fichero secuencialmente.
    ///
    /// Por defecto: una llamada a `extract` por entrada (óptimo en formatos de **acceso aleatorio**
    /// —ZIP, `.tar` puro—). Lo sobreescriben los formatos **secuenciales**, donde ir entrada a
    /// entrada re-descomprime lo anterior cada vez: `TarCodec` comprimido (un pase con
    /// `streamEntries`) y `LibArchiveCodec` (7z sólido y compañía, un pase con `extractEntries`).
    ///
    /// `onSkip`, si se da, recibe el tamaño sin comprimir de cada entrada que el recorrido tiene
    /// que atravesar sin extraerla (no pedida): solo lo usan `LibArchiveCodec` y `RarCodec`, cuyo iterador es
    /// secuencial y sin acceso aleatorio, así que ese recorrido tiene coste real aunque no emita
    /// bytes de salida — sin la señal, extraer solo un par de ficheros de un RAR grande deja la
    /// barra de progreso congelada mientras se salta el resto.
    func extractAll(_ entries: [ArchiveEntry], in container: ArchiveContainer, password: String?,
                    onSkip: ((Int64) -> Void)?,
                    place: (ArchiveEntry) throws -> ((Data) throws -> Void)?) throws
}

public extension ArchiveCodec {
    /// Sobrecarga cómoda para abrir sin progreso.
    func open(_ data: Data, fallbackName: String, passphrase: String? = nil) throws -> ArchiveReadResult {
        try open(data, fallbackName: fallbackName, passphrase: passphrase, progress: nil)
    }

    /// Por defecto cae a `entryData` + una sola escritura (formatos donde aún no hay
    /// streaming de extracción, p. ej. tar ya descomprimido en RAM y libarchive).
    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws {
        try sink(entryData(for: entry, in: container, password: password))
    }

    /// Sobrecarga sin `onSkip`, para los llamadores (y tests) a los que no les hace falta.
    func extractAll(_ entries: [ArchiveEntry], in container: ArchiveContainer, password: String?,
                    place: (ArchiveEntry) throws -> ((Data) throws -> Void)?) throws {
        try extractAll(entries, in: container, password: password, onSkip: nil, place: place)
    }

    /// Por defecto: extrae cada entrada por separado (acceso aleatorio), sin recorrido de por
    /// medio que saltar → `onSkip` no aplica aquí. `TarCodec` comprimido lo sobreescribe para
    /// hacer un único pase cuando hay varias entradas.
    func extractAll(_ entries: [ArchiveEntry], in container: ArchiveContainer, password: String?,
                    onSkip: ((Int64) -> Void)?,
                    place: (ArchiveEntry) throws -> ((Data) throws -> Void)?) throws {
        for entry in entries {
            if let sink = try place(entry) {
                try extract(entry, in: container, password: password, sink: sink)
            }
        }
    }
}

public extension ArchiveFormat {
    /// Codec que sabe leer/extraer este formato (registro formato → codec).
    var codec: any ArchiveCodec {
        switch self {
        case .zip:
            return ZipCodec()
        case .tar:
            return TarCodec(format: .tar, streamDecompress: nil)
        case .tarGzip:
            return TarCodec(format: .tarGzip, streamDecompress: { try Gzip.decompress($0, sink: $1) })
        case .tarXz:
            return TarCodec(format: .tarXz, streamDecompress: { try Xz.decompress($0, sink: $1) })
        case .tarBzip2:
            return TarCodec(format: .tarBzip2, streamDecompress: { try Bzip2.decompress($0, sink: $1) })
        case .gzip:
            return SingleFileCodec(format: .gzip, tarFormat: .tarGzip,
                                   decompress: { try Gzip.decompress($0) },
                                   streamDecompress: { try Gzip.decompress($0, sink: $1) },
                                   entries: { Gzip.entries(in: $0, fallbackName: $1) })
        case .xz:
            return SingleFileCodec(format: .xz, tarFormat: .tarXz,
                                   decompress: { try Xz.decompress($0) },
                                   streamDecompress: { try Xz.decompress($0, sink: $1) },
                                   entries: { Xz.entries(in: $0, fallbackName: $1) })
        case .bzip2:
            return SingleFileCodec(format: .bzip2, tarFormat: .tarBzip2,
                                   decompress: { try Bzip2.decompress($0) },
                                   streamDecompress: { try Bzip2.decompress($0, sink: $1) },
                                   entries: { Bzip2.entries(in: $0, fallbackName: $1) })
        case .rar:
            return RarCodec()
        case .sevenZip, .iso, .cpio, .xar, .lha, .cab:
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
        return ArchiveReadResult(format: .zip, container: .data(data), entries: entries)
    }

    func entryData(for entry: ArchiveEntry, in container: ArchiveContainer, password: String?) throws -> Data {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        return try ZipExtractor().extractedData(for: entry, in: container, password: password)
    }

    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        try ZipExtractor().extract(entry, in: container, password: password, sink: sink)
    }
}

/// TAR, opcionalmente envuelto en un compresor (gzip/xz/bzip2).
///
/// - **`.tar` puro** (`streamDecompress == nil`): el `container` es el propio TAR (mapeado);
///   acceso aleatorio directo por offset, sin descomprimir nada — no tiene el problema de RAM.
/// - **`.tar.<x>` comprimido**: el `container` son los bytes **comprimidos** (mapeados). Al abrir
///   se indexa al vuelo con `StreamIndexer` (sin materializar el TAR inflado) y cada entrada se
///   extrae re-descomprimiendo hasta su offset con `streamExtract`. Acceso por entrada = re-stream
///   (patrón canónico de tar; sin caché — §10 #2), memoria acotada.
struct TarCodec: ArchiveCodec {
    let format: ArchiveFormat
    /// Descompresión en streaming del envoltorio; `nil` para `.tar` puro (sin compresión).
    let streamDecompress: (@Sendable (Data, (Data) throws -> Void) throws -> Void)?

    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        guard let streamDecompress else {   // .tar puro: acceso aleatorio directo sobre el container
            return ArchiveReadResult(format: format, container: .data(data), entries: try Tar.listEntries(in: data))
        }
        let indexer = Tar.StreamIndexer()
        try streamDecompress(data) { try indexer.consume($0) }
        // El container se conserva COMPRIMIDO (mapeado); las entradas se re-descomprimen por offset.
        return ArchiveReadResult(format: format, container: .data(data), entries: try indexer.finish())
    }

    func entryData(for entry: ArchiveEntry, in container: ArchiveContainer, password: String?) throws -> Data {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        guard let streamDecompress else { return try Tar.entryData(for: entry, in: container) }
        var out = Data()
        try streamExtractEntry(entry, in: container, with: streamDecompress) { out.append($0) }
        return out
    }

    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        guard let streamDecompress else { try sink(Tar.entryData(for: entry, in: container)); return }
        try withoutActuallyEscaping(sink) { escapingSink in
            try streamExtractEntry(entry, in: container, with: streamDecompress, sink: escapingSink)
        }
    }

    func extractAll(_ entries: [ArchiveEntry], in container: ArchiveContainer, password: String?,
                    onSkip: ((Int64) -> Void)?,
                    place: (ArchiveEntry) throws -> ((Data) throws -> Void)?) throws {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        // Varias entradas de un tar **comprimido**: un solo recorrido (re-descomprime una vez).
        // Con una sola entrada (o `.tar` puro) sale más a cuenta ir por entrada: `extract` usa
        // `streamExtract`, que **corta** al terminarla sin inflar el resto del flujo (§10 #1).
        if let streamDecompress, entries.count > 1 {
            try withoutActuallyEscaping(place) { escapingPlace in
                try Tar.streamEntries(decompressing: container, with: streamDecompress, selecting: escapingPlace)
            }
            return
        }
        for entry in entries {
            if let sink = try place(entry) {
                try extract(entry, in: .data(container), password: password, sink: sink)
            }
        }
    }

    /// Re-descomprime `container` hasta el offset de `entry` y emite sus bytes por `sink`,
    /// cortando al terminar la entrada (no infla el resto del flujo).
    private func streamExtractEntry(_ entry: ArchiveEntry, in container: Data,
                                    with streamDecompress: @Sendable (Data, (Data) throws -> Void) throws -> Void,
                                    sink: @escaping (Data) throws -> Void) throws {
        guard let offset = entry.dataOffset.map(Int.init) else { throw TarError.corrupt }
        try Tar.streamExtract(offset: offset, length: Int(entry.uncompressedSize),
                              decompressing: container, with: streamDecompress, sink: sink)
    }
}

/// Formatos de un solo fichero (gzip/xz/bzip2). Al abrir distingue un fichero suelto de
/// un `.tar.<x>` mirando la firma ustar tras descomprimir; si es un TAR, refina el
/// formato a su variante y delega en TAR. El `container` conserva los bytes originales.
struct SingleFileCodec: ArchiveCodec {
    let format: ArchiveFormat
    let tarFormat: ArchiveFormat
    let decompress: @Sendable (Data) throws -> Data
    let streamDecompress: @Sendable (Data, (Data) throws -> Void) throws -> Void
    let entries: @Sendable (Data, String) -> [ArchiveEntry]

    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        // Distinguir un fichero suelto de un `.tar.<x>` solo necesita los primeros 263 bytes
        // descomprimidos (la firma ustar está en el offset 257). Inflamos solo esa cabecera en
        // streaming: si es un suelto, no materializamos todo el contenido (que se descartaría).
        if Tar.hasUstarMagic(try peekDecompressed(data, count: 263)) {
            // Es un TAR comprimido: indexar al vuelo (sin inflar el TAR entero) y conservar los
            // bytes COMPRIMIDOS (mapeados) como container. La extracción usará el TarCodec de
            // tarFormat, que re-descomprime por offset (§10 #2, mismo container comprimido).
            let indexer = Tar.StreamIndexer()
            try streamDecompress(data) { try indexer.consume($0) }
            return ArchiveReadResult(format: tarFormat, container: .data(data), entries: try indexer.finish())
        }
        return ArchiveReadResult(format: format, container: .data(data), entries: entries(data, fallbackName))
    }

    /// Descomprime en streaming solo hasta acumular `count` bytes (o EOF), para inspeccionar
    /// la cabecera sin inflar todo el flujo. La verificación íntegra (CRC/tamaño) la hace la
    /// extracción real más tarde; aquí solo se necesita la firma.
    private func peekDecompressed(_ data: Data, count: Int) throws -> Data {
        struct EnoughRead: Error {}
        var head = Data()
        do {
            try streamDecompress(data) { chunk in
                head.append(chunk)
                if head.count >= count { throw EnoughRead() }
            }
        } catch is EnoughRead {}
        return head
    }

    func entryData(for entry: ArchiveEntry, in container: ArchiveContainer, password: String?) throws -> Data {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        return try decompress(container)
    }

    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws {
        guard case .data(let container) = container else { throw UnsupportedContainerError() }
        try streamDecompress(container, sink)   // descomprime al vuelo, sin materializar la salida
    }
}

/// Formatos que pasan por la libarchive del sistema (7z/iso/cpio/xar/lha/cab).
struct LibArchiveCodec: ArchiveCodec {
    let format: ArchiveFormat

    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        let (entries, _, truncated) = try LibArchive.listEntries(in: data, passphrase: passphrase)
        return ArchiveReadResult(format: format, container: .data(data), entries: entries, truncated: truncated)
    }

    func entryData(for entry: ArchiveEntry, in container: ArchiveContainer, password: String?) throws -> Data {
        guard case .data(let data) = container else { throw UnsupportedContainerError() }
        return try LibArchive.extractEntry(path: entry.path, in: data, passphrase: password)
    }

    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws {
        guard case .data(let data) = container else { throw UnsupportedContainerError() }
        try LibArchive.extractEntry(path: entry.path, in: data, passphrase: password, sink: sink)
    }

    /// Un **solo recorrido** para todo el lote. libarchive es un iterador secuencial (no acceso
    /// aleatorio) y 7z comprime en bloques **sólidos**: extraer entrada a entrada re-abre y
    /// re-descomprime todo lo anterior cada vez → coste cuadrático (§10 #1, igual que tar
    /// comprimido). Con una sola entrada da lo mismo: el recorrido corta al colocarla.
    func extractAll(_ entries: [ArchiveEntry], in container: ArchiveContainer, password: String?,
                    onSkip: ((Int64) -> Void)?,
                    place: (ArchiveEntry) throws -> ((Data) throws -> Void)?) throws {
        guard case .data(let data) = container else { throw UnsupportedContainerError() }
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        try LibArchive.extractEntries(Array(byPath.keys), in: data, passphrase: password, onSkip: onSkip) { path in
            guard let entry = byPath[path] else { return nil }
            return try place(entry)
        }
    }
}

/// RAR vía unrar (vendorizado): a diferencia de libarchive, **descifra**. Trabaja sobre el fichero
/// en disco (`.rarFile`), no sobre bytes: `open(_ data:)` no aplica y el documento abre con
/// `Unrar.listEntries(at:)` directamente.
struct RarCodec: ArchiveCodec {
    func open(_ data: Data, fallbackName: String, passphrase: String?,
              progress: ((Double) -> Void)?) throws -> ArchiveReadResult {
        throw UnsupportedContainerError()
    }

    func entryData(for entry: ArchiveEntry, in container: ArchiveContainer, password: String?) throws -> Data {
        var out = Data()
        try extract(entry, in: container, password: password) { out.append($0) }
        return out
    }

    func extract(_ entry: ArchiveEntry, in container: ArchiveContainer, password: String?,
                 sink: (Data) throws -> Void) throws {
        guard case .rarFile(let url) = container else { throw UnsupportedContainerError() }
        try Unrar.extractEntry(path: entry.path, at: url, passphrase: password, sink: sink)
    }

    /// Un **solo recorrido** (RAR sólido: mismo motivo que `LibArchiveCodec.extractAll`).
    func extractAll(_ entries: [ArchiveEntry], in container: ArchiveContainer, password: String?,
                    onSkip: ((Int64) -> Void)?,
                    place: (ArchiveEntry) throws -> ((Data) throws -> Void)?) throws {
        guard case .rarFile(let url) = container else { throw UnsupportedContainerError() }
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        try Unrar.extractEntries(Array(byPath.keys), at: url, passphrase: password, onSkip: onSkip) { path in
            guard let entry = byPath[path] else { return nil }
            return try place(entry)
        }
    }
}
