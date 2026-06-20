import Foundation

/// Una entrada dentro de un archivo comprimido, leída SIN descomprimir su contenido.
///
/// Los campos son **neutrales** (valen para cualquier formato). Los metadatos propios
/// del ZIP (necesarios para extraer/descifrar/copiar en crudo) viven en `zip`, presente
/// solo cuando la entrada procede de un ZIP. Así ningún otro formato tiene que inventar
/// valores de ZIP a cero, y un campo a `nil` significa de verdad "no aplica".
public struct ArchiveEntry: Equatable, Identifiable, Sendable {
    public var id: String { path }
    /// Ruta completa dentro del archivo, p.ej. "docs/anidado.txt".
    public let path: String
    /// Tamaño que ocupa comprimida dentro del archivo.
    public let compressedSize: UInt64
    /// Tamaño real una vez descomprimida.
    public let uncompressedSize: UInt64
    /// `true` si es una carpeta (la ruta acaba en "/").
    public let isDirectory: Bool
    /// Fecha de modificación, si la trae el formato.
    public let modificationDate: Date?
    /// La entrada está cifrada (cualquier método o formato).
    public let isEncrypted: Bool
    /// Offset en bytes, dentro del contenedor, donde empiezan los **datos** de la
    /// entrada, cuando el formato da acceso aleatorio directo a ellos (TAR). `nil` si
    /// no aplica (ZIP usa `zip.localHeaderOffset`; 7z/gz/xz/bz2 no exponen offset directo).
    public let dataOffset: UInt64?
    /// Metadatos específicos del ZIP (extracción, descifrado, copia en crudo). `nil`
    /// para entradas que no proceden de un ZIP.
    public let zip: ZipEntryInfo?

    public init(path: String, compressedSize: UInt64, uncompressedSize: UInt64,
                isDirectory: Bool, modificationDate: Date?, isEncrypted: Bool,
                dataOffset: UInt64? = nil, zip: ZipEntryInfo? = nil) {
        self.path = path
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.isEncrypted = isEncrypted
        self.dataOffset = dataOffset
        self.zip = zip
    }

    /// Cifrada con AES (WinZip). Solo posible en ZIP; `false` en cualquier otro caso.
    public var isAESEncrypted: Bool { zip?.isAES ?? false }
}

/// Metadatos de una entrada de **ZIP** necesarios para extraer, descifrar o copiar sus
/// bytes en crudo a otro ZIP. Aislados aquí para que `ArchiveEntry` no arrastre la jerga
/// del ZIP (método, CRC, offset del local header, hora DOS, flags, AES) a los demás
/// formatos, que no la tienen.
public struct ZipEntryInfo: Equatable, Sendable {
    /// Método de compresión ZIP (0 = almacenado, 8 = deflate, 99 = AES WinZip).
    public let compressionMethod: UInt16
    /// CRC-32 del contenido sin comprimir (lo exige el formato ZIP).
    public let crc32: UInt32
    /// Offset del *local file header* de esta entrada dentro del ZIP.
    public let localHeaderOffset: UInt64
    /// Hora MS-DOS en crudo (para la verificación de contraseña de ZipCrypto).
    public let dosTime: UInt16
    /// Bandera de propósito general (bit 0 = cifrada, bit 3 = descriptor de datos).
    public let flags: UInt16
    /// Fuerza AES (1/2/3) si la entrada usa AES de WinZip; `nil` en otro caso.
    public let aesStrength: UInt8?
    /// Método de compresión real cuando la entrada es AES (el de cabecera es 99).
    public let aesRealMethod: UInt16?

    public init(compressionMethod: UInt16, crc32: UInt32, localHeaderOffset: UInt64,
                dosTime: UInt16, flags: UInt16, aesStrength: UInt8?, aesRealMethod: UInt16?) {
        self.compressionMethod = compressionMethod
        self.crc32 = crc32
        self.localHeaderOffset = localHeaderOffset
        self.dosTime = dosTime
        self.flags = flags
        self.aesStrength = aesStrength
        self.aesRealMethod = aesRealMethod
    }

    /// Cifrada con AES (WinZip): método de cabecera 99.
    public var isAES: Bool { compressionMethod == 99 }
}
