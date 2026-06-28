import Foundation
import ArchiveBrowser

/// Nombre base de un archivo sin su extensión conocida (zip/tar/tar.gz/tgz/gz). Para el resto
/// cae a `deletingPathExtension`. Compartido por la vista y los Servicios del Finder.
func archiveBaseName(_ name: String) -> String {
    let lower = name.lowercased()
    for ext in [".tar.gz", ".tgz", ".tar", ".zip", ".gz"] where lower.hasSuffix(ext) {
        return String(name.dropLast(ext.count))
    }
    return (name as NSString).deletingPathExtension
}

/// Traduce los errores conocidos del motor a un mensaje en el idioma de la app. Para los no
/// contemplados (p. ej. errores de fichero del sistema) cae a su `localizedDescription`.
/// Compartido por la vista y los Servicios del Finder.
func localizedErrorMessage(_ error: Error) -> String {
    switch error {
    case let e as ExtractError:
        switch e {
        case .needsPassword: return loc("error.needsPassword")
        case .wrongPassword: return loc("error.wrongPassword")
        case .unsupportedEncryption: return loc("error.unsupportedEncryption")
        case .unsupportedMethod: return loc("error.unsupportedMethod")
        case .corruptLocalHeader, .decompressionFailed: return loc("error.corrupt")
        }
    case let e as LibArchiveError:
        switch e {
        case .passphraseRequired: return loc("error.needsPassword")
        case .wrongPassword: return loc("error.wrongPassword")
        case .writeFailed: return loc("error.writeFailed")
        case .openFailed, .readFailed, .entryNotFound: return loc("error.readFailed")
        }
    case let e as ZipAESError:
        switch e {
        case .wrongPassword: return loc("error.wrongPassword")
        case .unsupportedStrength: return loc("error.unsupportedEncryption")
        case .corrupt: return loc("error.corrupt")
        }
    case is ZipWriteError:
        return loc("error.writeFailed")
    case is ArchiveError, is TarError, is GzipError, is XzError, is Bzip2Error:
        return loc("error.corrupt")
    default:
        return error.localizedDescription
    }
}
