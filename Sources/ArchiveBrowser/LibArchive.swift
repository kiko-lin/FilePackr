import Foundation
import Carchive

public enum LibArchiveError: Error, Equatable {
    case openFailed, passphraseRequired, wrongPassword, entryNotFound, writeFailed, readFailed
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

    /// Lista las entradas (sin extraer datos). Devuelve también si hay cifrado.
    /// Lanza `.passphraseRequired` si ni siquiera se pueden leer las cabeceras sin clave.
    public static func listEntries(in data: Data, passphrase: String? = nil) throws -> (entries: [ArchiveEntry], encrypted: Bool) {
        try data.withUnsafeBytes { raw -> ([ArchiveEntry], Bool) in
            let a = try open(raw, passphrase: passphrase)
            defer { archive_read_free(a) }

            var entries: [ArchiveEntry] = []
            var encrypted = false
            var entry: OpaquePointer?
            while true {
                let r = archive_read_next_header(a, &entry)
                if r == EOFCODE { break }
                guard r == OK, let entry else {
                    throw classifyHeaderFailure(a, passphrase: passphrase)
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
            return (entries, encrypted)
        }
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
            let a = try open(raw, passphrase: passphrase)
            defer { archive_read_free(a) }

            var entry: OpaquePointer?
            while true {
                let r = archive_read_next_header(a, &entry)
                if r == EOFCODE { throw LibArchiveError.entryNotFound }
                guard r == OK, let entry else { throw classifyHeaderFailure(a, passphrase: passphrase) }
                if String(cString: archive_entry_pathname(entry)) == path {
                    try streamData(a, sink: sink)
                    return
                }
                archive_read_data_skip(a)
            }
        }
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
                             level: CompressionLevel = .default) throws {
        guard let a = archive_write_new() else { throw LibArchiveError.writeFailed }
        defer { archive_write_free(a) }
        format.apply(a, level: level)
        guard url.path.withCString({ archive_write_open_filename(a, $0) }) == OK else {
            throw LibArchiveError.writeFailed
        }

        for item in items {
            guard let entry = archive_entry_new() else { throw LibArchiveError.writeFailed }
            defer { archive_entry_free(entry) }
            let path = item.isDirectory && !item.path.hasSuffix("/") ? item.path + "/" : item.path
            path.withCString { archive_entry_set_pathname(entry, $0) }
            archive_entry_set_filetype(entry, item.isDirectory ? AE_IFDIR : AE_IFREG)
            archive_entry_set_perm(entry, item.isDirectory ? 0o755 : 0o644)
            archive_entry_set_size(entry, item.size)
            archive_entry_set_mtime(entry, Int64(item.modifiedAt?.timeIntervalSince1970 ?? 0), 0)
            guard archive_write_header(a, entry) == OK else { throw LibArchiveError.writeFailed }
            if !item.isDirectory { try writeBody(item.source, to: a) }
        }
        guard archive_write_close(a) == OK else { throw LibArchiveError.writeFailed }
    }

    // MARK: - Helpers

    private static func open(_ raw: UnsafeRawBufferPointer, passphrase: String?) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw LibArchiveError.openFailed }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        if let passphrase { _ = passphrase.withCString { archive_read_add_passphrase(a, $0) } }
        guard archive_read_open_memory(a, raw.baseAddress, raw.count) == OK else {
            archive_read_free(a)
            throw LibArchiveError.openFailed
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
    private static func writeBody(_ source: WriteItem.Source, to a: OpaquePointer) throws {
        switch source {
        case .data(let d):
            guard !d.isEmpty else { return }
            let n = d.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
            guard n >= 0 else { throw LibArchiveError.writeFailed }
        case .file(let url):
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let n = chunk.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
                guard n >= 0 else { throw LibArchiveError.writeFailed }
            }
        }
    }

    /// Distingue "necesita contraseña" de un fallo genérico. Señal **estructurada** primero
    /// (`archive_read_has_encrypted_entries` > 0, robusta ante versión/idioma de libarchive) y,
    /// como complemento para el caso de **cabeceras** cifradas —donde el conteo es desconocido
    /// hasta tener la clave—, el texto del mensaje de error.
    private static func classifyHeaderFailure(_ a: OpaquePointer, passphrase: String?) -> LibArchiveError {
        let hasEncrypted = archive_read_has_encrypted_entries(a) > 0
        let message = archive_error_string(a).map { String(cString: $0).lowercased() } ?? ""
        let mentionsCrypto = message.contains("passphrase") || message.contains("password") || message.contains("encrypt")
        if hasEncrypted || mentionsCrypto {
            return passphrase == nil ? .passphraseRequired : .wrongPassword
        }
        return .readFailed
    }
}
