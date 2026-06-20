import ArchiveBrowser

extension ArchiveFormat {
    /// Clave de localización del nombre mostrado en el selector de formato. Vive en la
    /// app (no en el motor) porque es una preocupación de interfaz/idioma.
    var nameKey: String {
        switch self {
        case .zip: return "format.zip"
        case .tar: return "format.tar"
        case .tarGzip: return "format.tarGzip"
        case .tarXz: return "format.tarXz"
        case .tarBzip2: return "format.tarBzip2"
        case .gzip: return "format.gzip"
        case .xz: return "format.xz"
        case .bzip2: return "format.bzip2"
        case .sevenZip: return "format.sevenZip"
        case .rar: return "format.rar"
        case .iso: return "format.iso"
        case .cpio: return "format.cpio"
        case .xar: return "format.xar"
        case .lha: return "format.lha"
        case .cab: return "format.cab"
        }
    }
}
