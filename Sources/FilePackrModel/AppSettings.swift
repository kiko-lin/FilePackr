import SwiftUI
import AppKit
import Combine
import ArchiveBrowser

/// Tema de apariencia de la app.
public enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var nameKey: String { "theme.\(rawValue)" }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A dónde extraer por defecto.
public enum ExtractDestinationMode: String, CaseIterable, Identifiable {
    case lastUsedFolder, archiveFolder, fixedFolder
    public var id: String { rawValue }
    public var nameKey: String {
        switch self {
        case .archiveFolder: return "extract.dest.archiveFolder"
        case .fixedFolder: return "extract.dest.fixedFolder"
        case .lastUsedFolder: return "extract.dest.lastUsedFolder"
        }
    }
}

/// Qué hacer con los archivos ocultos y de sistema al **añadirlos** desde el disco
/// (botón Añadir o arrastre). No afecta a lo que se muestra dentro de un archivo abierto:
/// el contenido siempre se enseña íntegro. El filtro se aplica al expandir carpetas; un
/// elemento elegido/arrastrado de forma explícita en el primer nivel se respeta siempre.
public enum AddHiddenPolicy: String, CaseIterable, Identifiable {
    case includeAll, excludeSystemFiles, excludeAllHidden
    public var id: String { rawValue }
    public var nameKey: String { "settings.hidden.\(rawValue)" }

    /// Nombres y carpetas de sistema/metadatos que excluyen tanto `.excludeSystemFiles`
    /// como `.excludeAllHidden`.
    private static let systemNames: Set<String> = [
        ".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".apdisk", "__MACOSX", "Thumbs.db", "Desktop.ini"
    ]

    /// `true` si un elemento con este nombre debe excluirse al añadirlo desde el disco.
    public func excludes(_ name: String) -> Bool {
        switch self {
        case .includeAll: return false
        case .excludeSystemFiles: return name.hasPrefix("._") || Self.systemNames.contains(name)
        case .excludeAllHidden: return name.hasPrefix(".") || Self.systemNames.contains(name)
        }
    }
}

/// Pestañas de la ventana de Ajustes.
public enum SettingsTab: String, CaseIterable, Identifiable {
    case general, files
    public var id: String { rawValue }
    public var nameKey: String { self == .general ? "settings.tab.general" : "settings.tab.files" }
    public var systemImage: String { self == .general ? "gearshape" : "doc.zipper" }
}

/// Preferencias de la app (el idioma lo gobierna el sistema, no la app). Se guardan
/// en `UserDefaults` y se aplican en caliente.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @Published public var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    // Formato/cifrado/nivel por defecto para Guardar/Exportar. `nil` = **"Último usado"** (la
    // primera opción del Picker): se resuelve al último valor realmente usado (`lastUsed*`).
    @Published public var defaultFormat: ArchiveFormat? {
        didSet { defaults.set(defaultFormat?.rawValue, forKey: "defaultFormat") }
    }
    @Published public var defaultEncryption: ZipEncryption? {
        didSet { defaults.set(defaultEncryption?.persistID, forKey: "defaultEncryption") }
    }
    @Published public var defaultCompressionLevel: CompressionLevel? {
        didSet { defaults.set(defaultCompressionLevel?.rawValue, forKey: "defaultCompressionLevel") }
    }

    // Últimos valores realmente usados al guardar/exportar; alimentan la opción "Último usado".
    @Published public var lastUsedFormat: ArchiveFormat {
        didSet { defaults.set(lastUsedFormat.rawValue, forKey: "lastUsedFormat") }
    }
    @Published public var lastUsedEncryption: ZipEncryption {
        didSet { defaults.set(lastUsedEncryption.persistID, forKey: "lastUsedEncryption") }
    }
    @Published public var lastUsedLevel: CompressionLevel {
        didSet { defaults.set(lastUsedLevel.rawValue, forKey: "lastUsedLevel") }
    }

    /// Valor resuelto para prerrellenar la hoja: el fijo elegido, o el último usado si es "Último usado".
    public var resolvedFormat: ArchiveFormat { defaultFormat ?? lastUsedFormat }
    public var resolvedEncryption: ZipEncryption { defaultEncryption ?? lastUsedEncryption }
    public var resolvedLevel: CompressionLevel { defaultCompressionLevel ?? lastUsedLevel }
    @Published public var extractMode: ExtractDestinationMode {
        didSet { defaults.set(extractMode.rawValue, forKey: "extractMode") }
    }
    /// Carpeta fija de extracción (cuando `extractMode == .fixedFolder`).
    @Published public var fixedExtractFolder: URL? {
        didSet { defaults.set(fixedExtractFolder?.path, forKey: "fixedExtractFolder") }
    }
    /// Última carpeta a la que se extrajo (cuando `extractMode == .lastUsedFolder`). La fija
    /// `ExtractCoordinator.confirm` al confirmar una extracción.
    @Published public var lastUsedExtractFolder: URL? {
        didSet { defaults.set(lastUsedExtractFolder?.path, forKey: "lastUsedExtractFolder") }
    }
    /// Política de exclusión de ocultos/sistema al añadir ficheros desde el disco.
    @Published public var addHiddenPolicy: AddHiddenPolicy {
        didSet { defaults.set(addHiddenPolicy.rawValue, forKey: "addHiddenPolicy") }
    }

    /// Tras «Descomprimir aquí» (extensión del Finder), revelar la carpeta extraída en el Finder.
    /// Desactivado por defecto: se extrae en la misma ubicación que el usuario ya está viendo.
    @Published public var revealAfterExtract: Bool {
        didSet { defaults.set(revealAfterExtract, forKey: "revealAfterExtract") }
    }

    /// Formatos de los que FilePackr se ofrece como app por defecto en el Finder
    /// (pestaña Archivos de Ajustes). Se persisten como lista de `rawValue`.
    @Published public var associatedFormats: Set<ArchiveFormat> {
        didSet { defaults.set(associatedFormats.map(\.rawValue), forKey: "associatedFormats") }
    }

    /// `true` tras mostrar (una vez) el diálogo de "compresor por defecto" del primer arranque.
    @Published public var firstRunPromptShown: Bool {
        didSet { defaults.set(firstRunPromptShown, forKey: "firstRunPromptShown") }
    }

    /// Pestaña activa de la ventana de Ajustes (no se persiste; el primer arranque
    /// la fija en `.files` antes de abrir Ajustes).
    @Published public var selectedSettingsTab: SettingsTab = .general

    /// Formatos que FilePackr se ofrece a reclamar en el primer arranque: los que puede
    /// **crear** (editables). Los de solo lectura (rar/cpio/lha/cab) se excluyen a propósito
    /// —ahí FilePackr es visor, no editor, y no tiene sentido ser su app por defecto.
    public static let defaultAssociatedFormats: Set<ArchiveFormat> =
        Set(ArchiveFormat.allCases.filter(\.isWritable))

    private let defaults: UserDefaults

    /// Inyectable para tests (un `UserDefaults` aislado en vez del global). La app usa siempre
    /// `.shared`, que toma `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        // Sin clave guardada → `nil` = "Último usado" (por defecto en instalación nueva).
        defaultFormat = defaults.string(forKey: "defaultFormat").flatMap(ArchiveFormat.init(rawValue:))
        defaultEncryption = defaults.string(forKey: "defaultEncryption").flatMap(ZipEncryption.init(persistID:))
        defaultCompressionLevel = defaults.string(forKey: "defaultCompressionLevel").flatMap(CompressionLevel.init(rawValue:))
        lastUsedFormat = ArchiveFormat(rawValue: defaults.string(forKey: "lastUsedFormat") ?? "") ?? .zip
        lastUsedEncryption = ZipEncryption(persistID: defaults.string(forKey: "lastUsedEncryption") ?? "") ?? .none
        lastUsedLevel = CompressionLevel(rawValue: defaults.string(forKey: "lastUsedLevel") ?? "") ?? .default
        extractMode = ExtractDestinationMode(rawValue: defaults.string(forKey: "extractMode") ?? "") ?? .archiveFolder
        fixedExtractFolder = defaults.string(forKey: "fixedExtractFolder").map { URL(fileURLWithPath: $0) }
        lastUsedExtractFolder = defaults.string(forKey: "lastUsedExtractFolder").map { URL(fileURLWithPath: $0) }
        addHiddenPolicy = AddHiddenPolicy(rawValue: defaults.string(forKey: "addHiddenPolicy") ?? "") ?? .excludeSystemFiles
        revealAfterExtract = defaults.bool(forKey: "revealAfterExtract")   // por defecto false
        firstRunPromptShown = defaults.bool(forKey: "firstRunPromptShown")
        if let raw = defaults.array(forKey: "associatedFormats") as? [String] {
            associatedFormats = Set(raw.compactMap(ArchiveFormat.init(rawValue:)))
        } else {
            // Instalación nueva: sin ninguna asociación hasta que el usuario la acepte en el
            // primer arranque o marque formatos en Ajustes ▸ Archivos. Así las casillas de
            // Ajustes reflejan la asociación REAL, no una sugerencia sin aplicar.
            associatedFormats = []
        }
    }
}

/// Clave de localización del nivel de compresión para los `Picker` de la UI.
extension CompressionLevel {
    public var nameKey: String { "level.\(rawValue)" }
}

/// Persistencia estable del cifrado (el enum del paquete no es `RawRepresentable`).
extension ZipEncryption {
    public var persistID: String {
        switch self {
        case .none: return "none"
        case .zipCrypto: return "weak"
        case .aes256: return "strong"
        }
    }
    public init?(persistID: String) {
        switch persistID {
        case "none": self = .none
        case "weak": self = .zipCrypto
        case "strong": self = .aes256
        default: return nil
        }
    }
}
