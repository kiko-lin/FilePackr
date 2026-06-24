import Foundation

/// Formato del contenedor abierto o de salida. Es la pieza que decide capacidades
/// (cifrado, escritura, un solo fichero…) y, vía `codec`, cómo se lee/extrae.
public enum ArchiveFormat: String, Sendable, CaseIterable, Hashable {
    case zip, tar, tarGzip, tarXz, tarBzip2, gzip, xz, bzip2
    case sevenZip, rar, iso, cpio, xar, lha, cab

    /// Extensión de fichero asociada.
    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarXz: return "tar.xz"
        case .tarBzip2: return "tar.bz2"
        case .gzip: return "gz"
        case .xz: return "xz"
        case .bzip2: return "bz2"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .iso: return "iso"
        case .cpio: return "cpio"
        case .xar: return "xar"
        case .lha: return "lha"
        case .cab: return "cab"
        }
    }

    /// Solo ZIP admite cifrado con contraseña al **escribir** (7z se descifra al leer).
    public var supportsEncryption: Bool { self == .zip }

    /// La división en volúmenes (por bytes, sufijo `.001`/`.002`…) es genérica y
    /// vale para todos los formatos de salida que escribimos.
    public var supportsVolumeSplit: Bool { true }

    /// Formatos de un solo fichero (gzip/xz/bzip2): solo si el documento es un fichero.
    public var isSingleFileOnly: Bool { self == .gzip || self == .xz || self == .bzip2 }

    /// Formatos cuyo nivel de compresión es efectivo **hoy**: bzip2 (vía `blockSize`) y 7z
    /// (vía la opción `compression-level` de libarchive). ZIP/gzip/xz pasan por el framework
    /// `Compression` de Apple, que no expone nivel; se sumarán al migrar a zlib/liblzma.
    public var honorsCompressionLevel: Bool {
        self == .bzip2 || self == .tarBzip2 || self == .sevenZip
    }

    /// `false` para formatos solo de lectura (rar propietario; cpio/lha/cab no se escriben).
    public var isWritable: Bool { ![.rar, .cpio, .lha, .cab].contains(self) }

    /// Se lee/escribe con la libarchive del sistema (no en Swift puro).
    public var usesLibArchive: Bool { [.sevenZip, .rar, .iso, .cpio, .xar, .lha, .cab].contains(self) }

    /// Formato de escritura de libarchive (solo para los escribibles vía libarchive).
    public var libArchiveWriteFormat: LibArchive.WriteFormat? {
        switch self {
        case .sevenZip: return .sevenZip
        case .iso: return .iso
        case .xar: return .xar
        default: return nil
        }
    }

    // MARK: - Detección por nombre

    /// Formato deducido del **nombre** del fichero, con `.zip` como último recurso. Para
    /// `.gz`/`.xz`/`.bz2` es solo una primera aproximación: el codec lo refina al abrir.
    public static func detect(from url: URL) -> ArchiveFormat {
        detectByExtension(url) ?? .zip
    }

    /// Como `detect`, pero usa la **firma** (magic bytes) cuando la extensión no la
    /// reconoce, y solo cae a `.zip` si tampoco la firma decide.
    public static func detect(from url: URL, contents: Data) -> ArchiveFormat {
        detectByExtension(url) ?? detectByMagic(contents) ?? .zip
    }

    /// Formato según la extensión; `nil` si no es una extensión de archivo conocida.
    public static func detectByExtension(_ url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGzip }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") { return .tarBzip2 }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".gz") { return .gzip }
        if name.hasSuffix(".xz") { return .xz }
        if name.hasSuffix(".bz2") { return .bzip2 }
        if name.hasSuffix(".7z") { return .sevenZip }
        if name.hasSuffix(".rar") { return .rar }
        if name.hasSuffix(".iso") { return .iso }
        if name.hasSuffix(".cpio") { return .cpio }
        if name.hasSuffix(".xar") || name.hasSuffix(".pkg") { return .xar }
        if name.hasSuffix(".lha") || name.hasSuffix(".lzh") { return .lha }
        if name.hasSuffix(".cab") { return .cab }
        if name.hasSuffix(".zip") { return .zip }
        return nil
    }

    /// Formato según la **firma** de los primeros bytes; `nil` si no reconoce ninguna.
    /// Cubre las firmas comunes (TAR tiene "ustar" en el offset 257). gz/xz/bz2 que
    /// envuelven un tar se refinan luego en el codec.
    public static func detectByMagic(_ data: Data) -> ArchiveFormat? {
        func match(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            guard data.count >= offset + sig.count else { return false }
            let base = data.startIndex + offset
            return data[base..<(base + sig.count)].elementsEqual(sig)
        }
        if match([0x50, 0x4B, 0x03, 0x04]) || match([0x50, 0x4B, 0x05, 0x06]) || match([0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if match([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }   // 7z
        if match([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if match([0x1F, 0x8B]) { return .gzip }                              // gz / tar.gz
        if match([0x42, 0x5A, 0x68]) { return .bzip2 }                       // "BZh"
        if match([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }       // "Rar!\x1A\x07"
        if match([0x78, 0x61, 0x72, 0x21]) { return .xar }                   // "xar!"
        if match([0x4D, 0x53, 0x43, 0x46]) { return .cab }                   // "MSCF"
        if match([0x75, 0x73, 0x74, 0x61, 0x72], at: 257) { return .tar }    // "ustar"
        return nil
    }

    /// `true` si la extensión corresponde a un contenedor que sabemos abrir. Los
    /// volúmenes de continuación (`nombre_001.zip`) conservan la extensión, así que
    /// también casan aquí.
    public static func isOpenableArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".zip") || name.hasSuffix(".tar")
            || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".gz")
            || name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") || name.hasSuffix(".xz")
            || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") || name.hasSuffix(".bz2")
            || name.hasSuffix(".7z") || name.hasSuffix(".rar") || name.hasSuffix(".iso") || name.hasSuffix(".cpio")
            || name.hasSuffix(".xar") || name.hasSuffix(".pkg") || name.hasSuffix(".lha") || name.hasSuffix(".lzh") || name.hasSuffix(".cab")
    }
}
