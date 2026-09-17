import Foundation
import CUnrar

public enum UnrarError: Error, Equatable {
    case openFailed, passphraseRequired, wrongPassword, readFailed, truncated
    /// La entrada pedida (`path`) no apareció al recorrer el archivo.
    case entryNotFound(path: String)
}

/// Puente al **unrar de RARLAB** (vendorizado en `CUnrar`) para leer RAR. Sustituye a libarchive
/// en este formato porque libarchive **no descifra RAR** (ni RAR4 ni RAR5). Mismo modelo de
/// iterador secuencial que `LibArchive`: para extraer se re-abre y se recorre hasta las entradas.
///
/// La API de unrar solo abre **ficheros** (no memoria): se trabaja siempre sobre la URL del `.rar`
/// en disco (el primer volumen, si es multivolumen: unrar encuentra solo los siguientes). Los datos
/// se piden en modo *test* y salen por callback: unrar **nunca escribe a disco**, así que las
/// defensas de ZIP-Slip del modelo siguen siendo las que deciden dónde se escribe.
public enum Unrar {

    /// unrar guarda estado de error en un global (`ErrHandler`): serializar todo acceso.
    private static let lock = NSLock()

    /// Lista las entradas (sin extraer datos). `encrypted` = alguna entrada o las cabeceras van
    /// cifradas; `truncated` = el recorrido se cortó (p. ej. falta un volumen) y `entries` es
    /// solo lo que se pudo leer. Lanza `.passphraseRequired`/`.wrongPassword` si las cabeceras
    /// están cifradas y no hay clave o no es la buena.
    public static func listEntries(at url: URL, passphrase: String? = nil) throws -> (entries: [ArchiveEntry], encrypted: Bool, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        var headersEncrypted = false
        let h = try open(url, forExtract: false, passphrase: passphrase, headersEncrypted: &headersEncrypted)
        defer { fp_unrar_close(h) }

        var entries: [ArchiveEntry] = []
        var encrypted = headersEncrypted
        var truncated = false
        var raw = fp_unrar_entry()
        while true {
            var r = fp_unrar_next(h, &raw)
            if r == Int32(FP_UNRAR_END_ARCHIVE) { break }
            if r == Int32(FP_UNRAR_SUCCESS) {
                let entry = makeEntry(raw)
                if entry.isEncrypted { encrypted = true }
                entries.append(entry)
                r = fp_unrar_skip(h)
                if r == Int32(FP_UNRAR_SUCCESS) { continue }
            }
            // Fallo a mitad: lo ya leído es legítimo (p. ej. falta el último volumen) → se devuelve
            // marcado `truncated`; solo se lanza si no hay nada rescatable.
            guard entries.isEmpty else { truncated = true; break }
            throw classify(r, handle: h, passphrase: passphrase, entryEncrypted: headersEncrypted)
        }
        return (entries, encrypted, truncated)
    }

    /// Extrae la entrada `path` emitiendo su contenido por trozos (`sink`).
    public static func extractEntry(path: String, at url: URL, passphrase: String? = nil,
                                    sink: (Data) throws -> Void) throws {
        try withoutActuallyEscaping(sink) { sink in
            try extractEntries([path], at: url, passphrase: passphrase) { _ in sink }
        }
    }

    /// Extrae **varias** entradas en un **único recorrido** (RAR sólido: re-abrir por entrada
    /// re-descomprimiría todo lo anterior). `place(path)` da el sink de cada ruta pedida o `nil`
    /// para saltarla; `onSkip` recibe el tamaño de cada entrada atravesada sin extraer.
    public static func extractEntries(_ paths: [String], at url: URL, passphrase: String? = nil,
                                      onSkip: ((Int64) -> Void)? = nil,
                                      place: (String) throws -> ((Data) throws -> Void)?) throws {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var remaining = Set(paths)
        var headersEncrypted = false
        let h = try open(url, forExtract: true, passphrase: passphrase, headersEncrypted: &headersEncrypted)
        defer { fp_unrar_close(h) }

        var raw = fp_unrar_entry()
        while !remaining.isEmpty {
            let r = fp_unrar_next(h, &raw)
            if r == Int32(FP_UNRAR_END_ARCHIVE) { break }
            guard r == Int32(FP_UNRAR_SUCCESS) else {
                throw classify(r, handle: h, passphrase: passphrase, entryEncrypted: headersEncrypted)
            }
            let entry = makeEntry(raw)
            guard remaining.remove(entry.path) != nil, let sink = try place(entry.path) else {
                onSkip?(Int64(entry.uncompressedSize))
                let s = fp_unrar_skip(h)
                guard s == Int32(FP_UNRAR_SUCCESS) else {
                    throw classify(s, handle: h, passphrase: passphrase, entryEncrypted: entry.isEncrypted)
                }
                continue
            }
            try read(h, entry: entry, passphrase: passphrase, sink: sink)
        }
        if let missing = remaining.sorted().first { throw UnrarError.entryNotFound(path: missing) }
    }

    // MARK: - Helpers

    private static func open(_ url: URL, forExtract: Bool, passphrase: String?,
                             headersEncrypted: inout Bool) throws -> OpaquePointer {
        var result: Int32 = 0
        var encrypted: Int32 = 0
        let h = url.path.withCString { path in
            if let passphrase {
                return passphrase.withCString { fp_unrar_open(path, forExtract ? 1 : 0, $0, &result, &encrypted) }
            }
            return fp_unrar_open(path, forExtract ? 1 : 0, nil, &result, &encrypted)
        }
        headersEncrypted = encrypted != 0
        guard let h else {
            switch result {
            case Int32(FP_UNRAR_MISSING_PASSWORD): throw UnrarError.passphraseRequired
            case Int32(FP_UNRAR_BAD_PASSWORD): throw UnrarError.wrongPassword
            // Cabeceras cifradas con clave errónea en RAR4: el descifrado da basura → "datos malos".
            case Int32(FP_UNRAR_BAD_DATA) where headersEncrypted && passphrase != nil: throw UnrarError.wrongPassword
            default: throw UnrarError.openFailed
            }
        }
        return h
    }

    /// Descomprime la entrada actual hacia `sink`. Un error lanzado por `sink` (p. ej.
    /// cancelación) aborta unrar y se relanza tal cual.
    private static func read(_ h: OpaquePointer, entry: ArchiveEntry, passphrase: String?,
                             sink: (Data) throws -> Void) throws {
        try withoutActuallyEscaping(sink) { sink in
            let context = ReadContext(sink: sink)
            let unmanaged = Unmanaged.passRetained(context)
            defer { unmanaged.release() }
            let r = fp_unrar_read(h, { ctx, bytes, length in
                let context = Unmanaged<ReadContext>.fromOpaque(ctx!).takeUnretainedValue()
                guard length > 0, let bytes else { return 0 }
                do {
                    try context.sink(Data(bytes: bytes, count: length))
                    return 0
                } catch {
                    context.error = error
                    return 1
                }
            }, unmanaged.toOpaque())
            if let error = context.error { throw error }
            guard r == Int32(FP_UNRAR_SUCCESS) else {
                throw classify(r, handle: h, passphrase: passphrase, entryEncrypted: entry.isEncrypted)
            }
        }
    }

    private final class ReadContext {
        let sink: (Data) throws -> Void
        var error: Error?
        init(sink: @escaping (Data) throws -> Void) { self.sink = sink }
    }

    private static func classify(_ code: Int32, handle h: OpaquePointer, passphrase: String?,
                                 entryEncrypted: Bool) -> UnrarError {
        switch code {
        case Int32(FP_UNRAR_MISSING_PASSWORD): return .passphraseRequired
        case Int32(FP_UNRAR_BAD_PASSWORD): return .wrongPassword
        default: break
        }
        if fp_unrar_volume_missing(h) != 0 { return .truncated }
        // RAR4 no tiene valor de verificación de clave: una clave errónea sale como CRC malo.
        if code == Int32(FP_UNRAR_BAD_DATA), entryEncrypted || fp_unrar_password_requested(h) != 0 {
            return passphrase == nil ? .passphraseRequired : .wrongPassword
        }
        if code == Int32(FP_UNRAR_EREAD) { return .truncated }
        return .readFailed
    }

    private static func makeEntry(_ raw: fp_unrar_entry) -> ArchiveEntry {
        let path = String(cString: raw.path)
        return ArchiveEntry(
            path: path, compressedSize: raw.packed_size, uncompressedSize: raw.unpacked_size,
            isDirectory: raw.is_directory != 0 || path.hasSuffix("/"),
            modificationDate: raw.mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(raw.mtime)),
            isEncrypted: raw.is_encrypted != 0)
    }
}
