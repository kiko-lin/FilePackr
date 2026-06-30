import ArchiveBrowser

extension ArchiveFormat {
    /// Clave de localización del nombre mostrado en el selector de formato. Vive en la
    /// app (no en el motor) porque es una preocupación de interfaz/idioma.
    public var nameKey: String {
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

    /// Nombre del `.icns` del bundle (en Resources, no en el asset catalog: los campos
    /// `CFBundleTypeIconFile`/`UTTypeIconFile` del Info.plist exigen un fichero por nombre).
    /// El mismo fichero sirve al Finder (vía Info.plist) y a la UI (vía `NSImage(named:)`, que
    /// también busca en Resources). Las tres variantes de tar comprimido reutilizan el de TAR.
    public var iconAssetName: String {
        switch self {
        case .zip: return "FormatIcon-ZIP"
        case .tar, .tarGzip, .tarXz, .tarBzip2: return "FormatIcon-TAR"
        case .gzip: return "FormatIcon-GZIP"
        case .xz: return "FormatIcon-XZ"
        case .bzip2: return "FormatIcon-BZ2"
        case .sevenZip: return "FormatIcon-7Z"
        case .rar: return "FormatIcon-RAR"
        case .iso: return "FormatIcon-ISO"
        case .cpio: return "FormatIcon-CPIO"
        case .xar: return "FormatIcon-XAR"
        case .lha: return "FormatIcon-LHA"
        case .cab: return "FormatIcon-CAB"
        }
    }

    /// Identificador de tipo (UTI) usado para registrarse como handler por defecto y
    /// declarar el `CFBundleDocumentTypes`. Se reutilizan las UTI del sistema cuando
    /// existen; el resto se declaran como tipos importados con prefijo `com.filepackr.`.
    public var contentTypeIdentifier: String {
        switch self {
        case .zip: return "public.zip-archive"
        case .tar: return "public.tar-archive"
        case .tarGzip: return "org.gnu.gnu-zip-tar-archive"
        case .tarXz: return "com.filepackr.tar-xz"
        case .tarBzip2: return "com.filepackr.tar-bzip2"
        case .gzip: return "org.gnu.gnu-zip-archive"
        case .xz: return "org.tukaani.xz-archive"
        case .bzip2: return "public.bzip2-archive"
        case .sevenZip: return "org.7-zip.7-zip-archive"
        case .rar: return "com.rarlab.rar-archive"
        case .iso: return "public.iso-image"
        case .cpio: return "public.cpio-archive"
        case .xar: return "com.filepackr.xar-archive"
        case .lha: return "com.filepackr.lha-archive"
        case .cab: return "com.microsoft.cab-archive"
        }
    }

    /// Todas las extensiones que abre el formato (la principal y sus alias), sin punto.
    public var fileExtensions: [String] {
        switch self {
        case .zip: return ["zip"]
        case .tar: return ["tar"]
        case .tarGzip: return ["tar.gz", "tgz"]
        case .tarXz: return ["tar.xz", "txz"]
        case .tarBzip2: return ["tar.bz2", "tbz", "tbz2"]
        case .gzip: return ["gz"]
        case .xz: return ["xz"]
        case .bzip2: return ["bz2"]
        case .sevenZip: return ["7z"]
        case .rar: return ["rar"]
        case .iso: return ["iso"]
        case .cpio: return ["cpio"]
        case .xar: return ["xar", "pkg"]
        case .lha: return ["lha", "lzh"]
        case .cab: return ["cab"]
        }
    }

    /// Extensiones formateadas para mostrar en la lista («.zip», «.tar.gz, .tgz»…).
    public var displayExtensions: String {
        fileExtensions.map { ".\($0)" }.joined(separator: ", ")
    }
}
