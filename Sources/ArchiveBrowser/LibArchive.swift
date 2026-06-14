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
                    isDirectory: isDir, compressionMethod: 0, crc32: 0,
                    localHeaderOffset: 0,
                    modificationDate: mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime)),
                    dosTime: 0, flags: isEnc ? 1 : 0, aesStrength: nil, aesRealMethod: nil))
                archive_read_data_skip(a)
            }
            if archive_read_has_encrypted_entries(a) > 0 { encrypted = true }
            return (entries, encrypted)
        }
    }

    /// Datos de la entrada cuyo `path` coincide (re-abre e itera hasta ella).
    public static func extractEntry(path: String, in data: Data, passphrase: String? = nil) throws -> Data {
        try data.withUnsafeBytes { raw -> Data in
            let a = try open(raw, passphrase: passphrase)
            defer { archive_read_free(a) }

            var entry: OpaquePointer?
            while true {
                let r = archive_read_next_header(a, &entry)
                if r == EOFCODE { throw LibArchiveError.entryNotFound }
                guard r == OK, let entry else { throw classifyHeaderFailure(a, passphrase: passphrase) }
                if String(cString: archive_entry_pathname(entry)) == path {
                    return try readData(a)
                }
                archive_read_data_skip(a)
            }
        }
    }

    // MARK: - Escritura (7z)

    public struct WriteItem: Sendable {
        public let path: String
        public let data: Data
        public let modifiedAt: Date?
        public let isDirectory: Bool
        public init(path: String, data: Data, modifiedAt: Date?, isDirectory: Bool) {
            self.path = path; self.data = data; self.modifiedAt = modifiedAt; self.isDirectory = isDirectory
        }
    }

    /// Escribe un `.7z` en `url` (en claro: el escritor de 7z de libarchive no cifra;
    /// el cifrado de 7z solo está disponible en **lectura**).
    public static func write7z(_ items: [WriteItem], to url: URL) throws {
        guard let a = archive_write_new() else { throw LibArchiveError.writeFailed }
        defer { archive_write_free(a) }
        archive_write_set_format_7zip(a)
        _ = "7zip:compression=lzma2".withCString { archive_write_set_options(a, $0) }
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
            archive_entry_set_size(entry, item.isDirectory ? 0 : Int64(item.data.count))
            archive_entry_set_mtime(entry, Int64(item.modifiedAt?.timeIntervalSince1970 ?? 0), 0)
            guard archive_write_header(a, entry) == OK else { throw LibArchiveError.writeFailed }
            if !item.isDirectory, !item.data.isEmpty {
                let written = item.data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
                guard written >= 0 else { throw LibArchiveError.writeFailed }
            }
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

    private static func readData(_ a: OpaquePointer) throws -> Data {
        var out = Data()
        let bufSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, bufSize) }
            if n == 0 { break }
            guard n > 0 else { throw LibArchiveError.wrongPassword }   // dato cifrado sin clave correcta
            out.append(contentsOf: buf.prefix(Int(n)))
        }
        return out
    }

    /// Distingue "necesita contraseña" de un fallo genérico, mirando el mensaje de error.
    private static func classifyHeaderFailure(_ a: OpaquePointer, passphrase: String?) -> LibArchiveError {
        let message = archive_error_string(a).map { String(cString: $0).lowercased() } ?? ""
        if message.contains("passphrase") || message.contains("password") || message.contains("encrypt") {
            return passphrase == nil ? .passphraseRequired : .wrongPassword
        }
        return .readFailed
    }
}
