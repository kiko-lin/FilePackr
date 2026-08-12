import Foundation
import Carchive

public enum LibArchiveError: Error, Equatable {
    case openFailed, passphraseRequired, wrongPassword, writeFailed, readFailed, truncated
    /// La entrada pedida (`path`) no apareció al recorrer el archivo.
    case entryNotFound(path: String)
}

/// Puente a la **libarchive del sistema** para formatos que no implementamos en Swift
/// puro: lee 7z/rar/iso/cpio/xar… y escribe 7z (con cifrado AES si hay contraseña en
/// lectura). API de iterador en streaming: para extraer una entrada se vuelve a abrir
/// y se itera hasta su ruta.
public enum LibArchive {

    private static let OK: Int32 = 0       // ARCHIVE_OK
    private static let EOFCODE: Int32 = 1  // ARCHIVE_EOF
    private static let AE_IFREG: UInt32 = 0o100000
    private static let AE_IFDIR: UInt32 = 0o040000

    // MARK: - Lectura

    /// Origen de los bytes a abrir: en memoria (el caso normal, `container` ya mapeado/cargado)
    /// o una lista ordenada de ficheros de volúmenes RAR nativos (`archive_read_open_filenames`,
    /// la única forma correcta de leerlos: cada volumen lleva su propia cabecera intercalada, así
    /// que no se pueden concatenar a pelo como el esquema propio de volúmenes de FilePackr).
    private enum Source { case memory(UnsafeRawBufferPointer); case files([String]) }

    /// Lista las entradas (sin extraer datos). Devuelve también si hay cifrado y si la lectura
    /// se cortó antes de tiempo (`truncated`: p. ej. un RAR multivolumen al que le faltan partes).
    /// Lanza `.passphraseRequired` si ni siquiera se pueden leer las cabeceras sin clave.
    public static func listEntries(in data: Data, passphrase: String? = nil) throws -> (entries: [ArchiveEntry], encrypted: Bool, truncated: Bool) {
        try data.withUnsafeBytes { try listEntries(source: .memory($0), passphrase: passphrase) }
    }

    /// Como `listEntries(in:)`, pero sobre un conjunto de volúmenes RAR nativos en disco.
    public static func listEntries(volumes: [URL], passphrase: String? = nil) throws -> (entries: [ArchiveEntry], encrypted: Bool, truncated: Bool) {
        try listEntries(source: .files(volumes.map(\.path)), passphrase: passphrase)
    }

    private static func listEntries(source: Source, passphrase: String?) throws -> (entries: [ArchiveEntry], encrypted: Bool, truncated: Bool) {
        let a = try open(source, passphrase: passphrase)
        defer { archive_read_free(a) }

        var entries: [ArchiveEntry] = []
        var encrypted = false
        var truncated = false
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFCODE { break }
            guard r == OK, let entry else {
                // A un volumen le faltan partes: `next_header` no siempre da un EOF limpio al
                // llegar al final de los datos disponibles (solo lo da si el corte cae justo en
                // un borde de bloque) — lo normal en un RAR real es un error de lectura a mitad
                // de bloque. Si ya habíamos leído alguna entrada, esa parte es legítima y se
                // devuelve tal cual (marcada `truncated`) en vez de descartarla; solo se lanza si
                // no hay nada rescatable.
                guard !entries.isEmpty else { throw classifyFailure(a, passphrase: passphrase) }
                truncated = true
                break
            }
            let path = String(cString: archive_entry_pathname(entry))
            let isDir = archive_entry_filetype(entry) == AE_IFDIR || path.hasSuffix("/")
            let size = UInt64(max(0, archive_entry_size(entry)))
            let isEnc = archive_entry_is_encrypted(entry) != 0
            if isEnc { encrypted = true }
            let mtime = archive_entry_mtime(entry)
            entries.append(ArchiveEntry(
                path: path, compressedSize: size, uncompressedSize: size,
                isDirectory: isDir,
                modificationDate: mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime)),
                isEncrypted: isEnc))
            archive_read_data_skip(a)
        }
        if archive_read_has_encrypted_entries(a) > 0 { encrypted = true }
        return (entries, encrypted, truncated)
    }

    /// Datos de la entrada cuyo `path` coincide (re-abre e itera hasta ella).
    public static func extractEntry(path: String, in data: Data, passphrase: String? = nil) throws -> Data {
        var out = Data()
        try extractEntry(path: path, in: data, passphrase: passphrase, sink: { out.append($0) })
        return out
    }

    /// Extrae la entrada `path` emitiendo el contenido por trozos (`sink`), **sin
    /// materializar la salida en RAM**. Re-abre el archivo e itera hasta ella.
    public static func extractEntry(path: String, in data: Data, passphrase: String? = nil,
                                    sink: (Data) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            try extractEntry(path: path, source: .memory(raw), passphrase: passphrase, sink: sink)
        }
    }

    /// Como `extractEntry(path:in:sink:)`, pero sobre un conjunto de volúmenes RAR nativos.
    public static func extractEntry(path: String, volumes: [URL], passphrase: String? = nil,
                                    sink: (Data) throws -> Void) throws {
        try extractEntry(path: path, source: .files(volumes.map(\.path)), passphrase: passphrase, sink: sink)
    }

    private static func extractEntry(path: String, source: Source, passphrase: String?,
                                     sink: (Data) throws -> Void) throws {
        let a = try open(source, passphrase: passphrase)
        defer { archive_read_free(a) }

        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == EOFCODE { throw LibArchiveError.entryNotFound(path: path) }
            guard r == OK, let entry else { throw classifyFailure(a, passphrase: passphrase) }
            if String(cString: archive_entry_pathname(entry)) == path {
                try streamData(a, sink: sink)
                return
            }
            archive_read_data_skip(a)
        }
    }

    /// Extrae **varias** entradas en un **único recorrido** del archivo. Por cada ruta pedida que
    /// aparece, `place(path)` devuelve el sink donde volcar su contenido (en streaming) o `nil`
    /// para saltarla; las demás entradas se saltan. Corta en cuanto no queda ninguna pendiente.
    ///
    /// El recorrido único no es una optimización menor: la API de libarchive es un **iterador
    /// secuencial**, no acceso aleatorio, y 7z comprime en **bloques sólidos**. Re-abrir por
    /// entrada obliga a re-descomprimir todo lo anterior cada vez (coste cuadrático: un 7z de
    /// unos cientos de ficheros tarda minutos y aparenta estar colgado).
    public static func extractEntries(_ paths: [String], in data: Data, passphrase: String? = nil,
                                      onSkip: ((Int64) -> Void)? = nil,
                                      place: (String) throws -> ((Data) throws -> Void)?) throws {
        try data.withUnsafeBytes { raw in
            try extractEntries(paths, source: .memory(raw), passphrase: passphrase, onSkip: onSkip, place: place)
        }
    }

    /// Como `extractEntries(_:in:place:)`, pero sobre un conjunto de volúmenes RAR nativos.
    public static func extractEntries(_ paths: [String], volumes: [URL], passphrase: String? = nil,
                                      onSkip: ((Int64) -> Void)? = nil,
                                      place: (String) throws -> ((Data) throws -> Void)?) throws {
        try extractEntries(paths, source: .files(volumes.map(\.path)), passphrase: passphrase, onSkip: onSkip, place: place)
    }

    /// `onSkip`, si se da, recibe el tamaño (sin descomprimir) de cada entrada **no pedida** que
    /// hay que recorrer para llegar a las que sí lo son: como el iterador es secuencial, ese
    /// recorrido tiene coste real (más aún si el archivo es sólido) aunque no produzca bytes de
    /// salida — sin esta señal, quien mida el progreso por bytes escritos ve la barra congelada
    /// mientras se salta un RAR grande para extraer solo un par de ficheros de él.
    private static func extractEntries(_ paths: [String], source: Source, passphrase: String?,
                                       onSkip: ((Int64) -> Void)? = nil,
                                       place: (String) throws -> ((Data) throws -> Void)?) throws {
        guard !paths.isEmpty else { return }
        var remaining = Set(paths)
        let a = try open(source, passphrase: passphrase)
        defer { archive_read_free(a) }

        var entry: OpaquePointer?
        while !remaining.isEmpty {
            let r = archive_read_next_header(a, &entry)
            if r == EOFCODE { break }
            guard r == OK, let entry else { throw classifyFailure(a, passphrase: passphrase) }
            let path = String(cString: archive_entry_pathname(entry))
            // No pedida, o pedida pero el llamador la descarta → saltar sus datos y seguir.
            guard remaining.remove(path) != nil, let sink = try place(path) else {
                onSkip?(Int64(max(0, archive_entry_size(entry))))
                archive_read_data_skip(a)
                continue
            }
            try streamData(a, sink: sink)
        }
        // Alguna ruta pedida no estaba en el archivo: mismo error que la vía de una entrada
        // (la primera en orden alfabético, para un mensaje determinista con varias ausentes).
        if let missing = remaining.sorted().first { throw LibArchiveError.entryNotFound(path: missing) }
    }

    // MARK: - Escritura (7z)

    public struct WriteItem: Sendable {
        /// Origen del contenido: bytes ya en memoria, o un fichero de disco (streaming).
        public enum Source: Sendable { case data(Data); case file(URL) }
        public let path: String
        public let source: Source
        public let modifiedAt: Date?
        public let isDirectory: Bool

        public init(path: String, data: Data, modifiedAt: Date?, isDirectory: Bool) {
            self.path = path; self.source = .data(data); self.modifiedAt = modifiedAt; self.isDirectory = isDirectory
        }
        /// Entrada cuyo contenido se leerá del fichero al vuelo (sin cargarlo en RAM).
        public init(path: String, fileURL: URL, modifiedAt: Date?) {
            self.path = path; self.source = .file(fileURL); self.modifiedAt = modifiedAt; self.isDirectory = false
        }

        /// Tamaño del contenido (para la cabecera): bytes en memoria o tamaño en disco.
        var size: Int64 {
            if isDirectory { return 0 }
            switch source {
            case .data(let d): return Int64(d.count)
            case .file(let url): return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int).map(Int64.init) ?? 0
            }
        }
    }

    /// Formatos de escritura que soporta la libarchive de Apple.
    public enum WriteFormat: Sendable {
        case sevenZip, iso, xar
        func apply(_ a: OpaquePointer, level: CompressionLevel) {
            switch self {
            case .sevenZip:
                archive_write_set_format_7zip(a)
                // lzma2 + nivel 0–9: el único formato de libarchive con compresión regulable aquí.
                _ = "7zip:compression=lzma2,compression-level=\(level.libArchiveLevel)"
                    .withCString { archive_write_set_options(a, $0) }
            case .iso: archive_write_set_format_iso9660(a)
            case .xar: archive_write_set_format_xar(a)
            }
        }
    }

    /// Escribe un archivo (7z/iso/xar) en `url`. **En claro**: el escritor de 7z de
    /// libarchive no cifra (el cifrado de 7z solo está disponible en lectura).
    public static func write(_ items: [WriteItem], to url: URL, format: WriteFormat = .sevenZip,
                             level: CompressionLevel = .default,
                             cancellation: CancellationCheck = .none,
                             progress: WriteProgress = .none) throws {
        guard let a = archive_write_new() else { throw LibArchiveError.writeFailed }
        defer { archive_write_free(a) }
        format.apply(a, level: level)
        guard url.path.withCString({ archive_write_open_filename(a, $0) }) == OK else {
            throw LibArchiveError.writeFailed
        }

        for item in items {
            try cancellation.check()   // por entrada
            guard let entry = archive_entry_new() else { throw LibArchiveError.writeFailed }
            defer { archive_entry_free(entry) }
            let path = item.isDirectory && !item.path.hasSuffix("/") ? item.path + "/" : item.path
            path.withCString { archive_entry_set_pathname(entry, $0) }
            archive_entry_set_filetype(entry, item.isDirectory ? AE_IFDIR : AE_IFREG)
            archive_entry_set_perm(entry, item.isDirectory ? 0o755 : 0o644)
            archive_entry_set_size(entry, item.size)
            archive_entry_set_mtime(entry, Int64(item.modifiedAt?.timeIntervalSince1970 ?? 0), 0)
            guard archive_write_header(a, entry) == OK else { throw LibArchiveError.writeFailed }
            if !item.isDirectory {
                try writeBody(item.source, to: a, cancellation: cancellation,
                              progress: { progress(item.path, $0) })
            }
        }
        guard archive_write_close(a) == OK else { throw LibArchiveError.writeFailed }
    }

    // MARK: - Helpers

    private static func open(_ source: Source, passphrase: String?) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw LibArchiveError.openFailed }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        if let passphrase { _ = passphrase.withCString { archive_read_add_passphrase(a, $0) } }
        let opened: Int32
        switch source {
        case .memory(let raw):
            // Recorta el bloque SERVICE/QuickOpen sobrante de RAR5 si lo hay (ver
            // RAR5TrailingServiceBlock) — evita el bug de libarchive que lo desincroniza.
            let length = RAR5TrailingServiceBlock.offset(length: Int64(raw.count), read: { off, len in
                guard let base = raw.baseAddress, off >= 0, off + Int64(len) <= Int64(raw.count) else { return nil }
                return Data(bytes: base.advanced(by: Int(off)), count: len)
            }).map(Int.init) ?? raw.count
            opened = archive_read_open_memory(a, raw.baseAddress, length)
        case .files(let paths):
            if let stream = RARVolumeStream.makeIfTruncationNeeded(paths: paths) {
                let clientData = Unmanaged.passRetained(stream).toOpaque()
                opened = archive_read_open2(a, clientData, rarVolumeOpenCallback,
                    rarVolumeReadCallback, nil, rarVolumeCloseCallback)
            } else {
                let cStrings = paths.map { strdup($0) }
                defer { cStrings.forEach { free($0) } }
                var pointers = cStrings.map { UnsafePointer($0) } + [nil]
                opened = archive_read_open_filenames(a, &pointers, 10240)
            }
        }
        guard opened == OK else {
            // Clasificar ANTES de liberar `a`: archive_error_string necesita el archive vivo.
            let failure = classifyFailure(a, passphrase: passphrase)
            archive_read_free(a)
            // .readFailed es el resultado por defecto de classifyFailure para "no sé qué pasó";
            // aquí el fallo es al ABRIR, no a mitad de cabecera, así que ese caso por defecto
            // pasa a ser .openFailed (mismo mensaje para el usuario, más preciso internamente).
            if case .readFailed = failure { throw LibArchiveError.openFailed }
            throw failure
        }
        return a
    }

    /// Lee los datos de la entrada actual y los emite por trozos (`sink`), sin acumularlos.
    private static func streamData(_ a: OpaquePointer, sink: (Data) throws -> Void) throws {
        let bufSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, bufSize) }
            if n == 0 { break }
            guard n > 0 else { throw LibArchiveError.wrongPassword }   // dato cifrado sin clave correcta
            try sink(Data(buf.prefix(Int(n))))
        }
    }

    /// Escribe el cuerpo de una entrada: bytes en memoria o leídos del fichero por trozos.
    /// `progress` recibe los bytes de entrada procesados (sin el nombre, que lo pone el llamador).
    private static func writeBody(_ source: WriteItem.Source, to a: OpaquePointer,
                                  cancellation: CancellationCheck, progress: (Int) -> Void) throws {
        switch source {
        case .data(let d):
            guard !d.isEmpty else { return }
            let n = d.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
            guard n >= 0 else { throw LibArchiveError.writeFailed }
            progress(d.count)
        case .file(let url):
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try cancellation.check()   // por trozo (corta a mitad de un fichero grande)
                let n = chunk.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
                guard n >= 0 else { throw LibArchiveError.writeFailed }
                progress(chunk.count)
            }
        }
    }

    /// Clasifica un fallo (al abrir o a mitad de cabecera) usando la señal **estructurada**
    /// primero (`archive_read_has_encrypted_entries` > 0, robusta ante versión/idioma de
    /// libarchive) y, como complemento para el caso de **cabeceras** cifradas —donde el conteo es
    /// desconocido hasta tener la clave— o para truncamiento, el texto libre de
    /// `archive_error_string`. Este texto es en inglés y no está garantizado entre versiones de
    /// libarchive: es un mejor esfuerzo, con `.readFailed` como respaldo si no reconoce nada.
    private static func classifyFailure(_ a: OpaquePointer, passphrase: String?) -> LibArchiveError {
        let hasEncrypted = archive_read_has_encrypted_entries(a) > 0
        let message = archive_error_string(a).map { String(cString: $0).lowercased() } ?? ""
        let mentionsCrypto = message.contains("passphrase") || message.contains("password") || message.contains("encrypt")
        if hasEncrypted || mentionsCrypto {
            return passphrase == nil ? .passphraseRequired : .wrongPassword
        }
        if message.contains("trunc") { return .truncated }
        return .readFailed
    }
}

// MARK: - Lector de volúmenes RAR con cola recortada

/// Presenta una lista de volúmenes RAR como un único flujo secuencial a libarchive (vía
/// `archive_read_open2`), igual que haría `archive_read_open_filenames` — con la diferencia de
/// que el ÚLTIMO volumen se corta en `lastVolumeCap` bytes en vez de leerse entero. Solo se usa
/// cuando `RAR5TrailingServiceBlock` ha encontrado un bloque SERVICE/QuickOpen sobrante que hay
/// que esquivar; en cualquier otro caso se sigue usando `archive_read_open_filenames` sin coste
/// añadido.
private final class RARVolumeStream {
    private let paths: [String]
    private let lastVolumeCap: Int64
    private var index = 0
    private var handle: FileHandle?
    private var remainingInCurrent: Int64 = 0
    private let chunkSize = 256 * 1024

    /// Retenido por el puntero que se pasa a libarchive como `client_data` mientras dure la
    /// apertura (ver `rarVolumeReadCallback`): el contrato de `archive_read_open2` exige que el
    /// buffer devuelto siga vivo hasta la siguiente llamada.
    var currentChunk = Data()

    private init(paths: [String], lastVolumeCap: Int64) {
        self.paths = paths
        self.lastVolumeCap = lastVolumeCap
    }

    static func makeIfTruncationNeeded(paths: [String]) -> RARVolumeStream? {
        guard paths.count > 1, let lastPath = paths.last,
              let size = (try? FileManager.default.attributesOfItem(atPath: lastPath)[.size]) as? Int,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: lastPath)) else { return nil }
        defer { try? handle.close() }
        guard let cap = RAR5TrailingServiceBlock.offset(length: Int64(size), read: { off, len in
            guard off >= 0, off + Int64(len) <= Int64(size) else { return nil }
            do {
                try handle.seek(toOffset: UInt64(off))
                let d = try handle.read(upToCount: len)
                return d?.count == len ? d : nil
            } catch { return nil }
        }) else { return nil }
        return RARVolumeStream(paths: paths, lastVolumeCap: cap)
    }

    private func openNextIfNeeded() -> Bool {
        while handle == nil {
            guard index < paths.count else { return false }
            let path = paths[index]
            guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
                  let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int else {
                index += 1
                continue
            }
            let cap = index == paths.count - 1 ? min(Int64(size), lastVolumeCap) : Int64(size)
            guard cap > 0 else {
                try? h.close()
                index += 1
                continue
            }
            handle = h
            remainingInCurrent = cap
        }
        return true
    }

    func nextChunk() -> Data {
        guard openNextIfNeeded(), let h = handle else { return Data() }
        let want = Int(min(Int64(chunkSize), remainingInCurrent))
        guard want > 0, let chunk = try? h.read(upToCount: want), !chunk.isEmpty else {
            try? h.close(); handle = nil; index += 1
            return nextChunk()
        }
        remainingInCurrent -= Int64(chunk.count)
        if remainingInCurrent <= 0 {
            try? h.close(); handle = nil; index += 1
        }
        return chunk
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

private func rarVolumeOpenCallback(_ archive: OpaquePointer?, _ clientData: UnsafeMutableRawPointer?) -> Int32 {
    0 // ARCHIVE_OK
}

private func rarVolumeReadCallback(_ archive: OpaquePointer?, _ clientData: UnsafeMutableRawPointer?,
                                   _ buffer: UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int {
    guard let clientData else { buffer?.pointee = nil; return 0 }
    let stream = Unmanaged<RARVolumeStream>.fromOpaque(clientData).takeUnretainedValue()
    stream.currentChunk = stream.nextChunk()
    guard !stream.currentChunk.isEmpty else { buffer?.pointee = nil; return 0 }
    return stream.currentChunk.withUnsafeBytes { raw in
        buffer?.pointee = raw.baseAddress
        return raw.count
    }
}

private func rarVolumeCloseCallback(_ archive: OpaquePointer?, _ clientData: UnsafeMutableRawPointer?) -> Int32 {
    guard let clientData else { return 0 }
    let unmanaged = Unmanaged<RARVolumeStream>.fromOpaque(clientData)
    unmanaged.takeUnretainedValue().close()
    unmanaged.release()
    return 0 // ARCHIVE_OK
}
