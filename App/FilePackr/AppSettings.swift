import SwiftUI
import AppKit
import Combine
import ArchiveBrowser

/// Tema de apariencia de la app.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var nameKey: String { "theme.\(rawValue)" }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A dónde extraer por defecto.
enum ExtractDestinationMode: String, CaseIterable, Identifiable {
    case lastUsedFolder, archiveFolder, fixedFolder
    var id: String { rawValue }
    var nameKey: String {
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
enum AddHiddenPolicy: String, CaseIterable, Identifiable {
    case includeAll, excludeSystemFiles, excludeAllHidden
    var id: String { rawValue }
    var nameKey: String { "settings.hidden.\(rawValue)" }

    /// Nombres y carpetas de sistema/metadatos que excluyen tanto `.excludeSystemFiles`
    /// como `.excludeAllHidden`.
    private static let systemNames: Set<String> = [
        ".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".apdisk", "__MACOSX", "Thumbs.db", "Desktop.ini"
    ]

    /// `true` si un elemento con este nombre debe excluirse al añadirlo desde el disco.
    func excludes(_ name: String) -> Bool {
        switch self {
        case .includeAll: return false
        case .excludeSystemFiles: return name.hasPrefix("._") || Self.systemNames.contains(name)
        case .excludeAllHidden: return name.hasPrefix(".") || Self.systemNames.contains(name)
        }
    }
}

/// Pestañas de la ventana de Ajustes.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, files
    var id: String { rawValue }
    var nameKey: String { self == .general ? "settings.tab.general" : "settings.tab.files" }
    var systemImage: String { self == .general ? "gearshape" : "doc.zipper" }
}

/// Preferencias de la app (el idioma lo gobierna el sistema, no la app). Se guardan
/// en `UserDefaults` y se aplican en caliente.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    // Formato/cifrado/nivel por defecto para Guardar/Exportar. `nil` = **"Último usado"** (la
    // primera opción del Picker): se resuelve al último valor realmente usado (`lastUsed*`).
    @Published var defaultFormat: ArchiveFormat? {
        didSet { defaults.set(defaultFormat?.rawValue, forKey: "defaultFormat") }
    }
    @Published var defaultEncryption: ZipEncryption? {
        didSet { defaults.set(defaultEncryption?.persistID, forKey: "defaultEncryption") }
    }
    @Published var defaultCompressionLevel: CompressionLevel? {
        didSet { defaults.set(defaultCompressionLevel?.rawValue, forKey: "defaultCompressionLevel") }
    }

    // Últimos valores realmente usados al guardar/exportar; alimentan la opción "Último usado".
    @Published var lastUsedFormat: ArchiveFormat {
        didSet { defaults.set(lastUsedFormat.rawValue, forKey: "lastUsedFormat") }
    }
    @Published var lastUsedEncryption: ZipEncryption {
        didSet { defaults.set(lastUsedEncryption.persistID, forKey: "lastUsedEncryption") }
    }
    @Published var lastUsedLevel: CompressionLevel {
        didSet { defaults.set(lastUsedLevel.rawValue, forKey: "lastUsedLevel") }
    }

    /// Valor resuelto para prerrellenar la hoja: el fijo elegido, o el último usado si es "Último usado".
    var resolvedFormat: ArchiveFormat { defaultFormat ?? lastUsedFormat }
    var resolvedEncryption: ZipEncryption { defaultEncryption ?? lastUsedEncryption }
    var resolvedLevel: CompressionLevel { defaultCompressionLevel ?? lastUsedLevel }
    @Published var extractMode: ExtractDestinationMode {
        didSet { defaults.set(extractMode.rawValue, forKey: "extractMode") }
    }
    /// Carpeta fija de extracción (cuando `extractMode == .fixedFolder`).
    @Published var fixedExtractFolder: URL? {
        didSet { defaults.set(fixedExtractFolder?.path, forKey: "fixedExtractFolder") }
    }
    /// Última carpeta a la que se extrajo (cuando `extractMode == .lastUsedFolder`). La fija
    /// `ExtractCoordinator.confirm` al confirmar una extracción.
    @Published var lastUsedExtractFolder: URL? {
        didSet { defaults.set(lastUsedExtractFolder?.path, forKey: "lastUsedExtractFolder") }
    }
    /// Política de exclusión de ocultos/sistema al añadir ficheros desde el disco.
    @Published var addHiddenPolicy: AddHiddenPolicy {
        didSet { defaults.set(addHiddenPolicy.rawValue, forKey: "addHiddenPolicy") }
    }

    /// Formatos de los que FilePackr se ofrece como app por defecto en el Finder
    /// (pestaña Archivos de Ajustes). Se persisten como lista de `rawValue`.
    @Published var associatedFormats: Set<ArchiveFormat> {
        didSet { defaults.set(associatedFormats.map(\.rawValue), forKey: "associatedFormats") }
    }

    /// `true` tras mostrar (una vez) el diálogo de "compresor por defecto" del primer arranque.
    @Published var firstRunPromptShown: Bool {
        didSet { defaults.set(firstRunPromptShown, forKey: "firstRunPromptShown") }
    }

    /// Pestaña activa de la ventana de Ajustes (no se persiste; el primer arranque
    /// la fija en `.files` antes de abrir Ajustes).
    @Published var selectedSettingsTab: SettingsTab = .general

    /// Formatos premarcados por defecto: los más habituales (ZIP > RAR > 7Z + Unix).
    static let defaultAssociatedFormats: Set<ArchiveFormat> = [.zip, .sevenZip, .rar, .tarGzip, .gzip, .tar]

    private let defaults = UserDefaults.standard

    private init() {
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
        firstRunPromptShown = defaults.bool(forKey: "firstRunPromptShown")
        if let raw = defaults.array(forKey: "associatedFormats") as? [String] {
            associatedFormats = Set(raw.compactMap(ArchiveFormat.init(rawValue:)))
        } else {
            associatedFormats = Self.defaultAssociatedFormats
        }
    }
}

/// Clave de localización del nivel de compresión para los `Picker` de la UI.
extension CompressionLevel {
    var nameKey: String { "level.\(rawValue)" }
}

/// Persistencia estable del cifrado (el enum del paquete no es `RawRepresentable`).
extension ZipEncryption {
    var persistID: String {
        switch self {
        case .none: return "none"
        case .zipCrypto: return "weak"
        case .aes256: return "strong"
        }
    }
    init?(persistID: String) {
        switch persistID {
        case "none": self = .none
        case "weak": self = .zipCrypto
        case "strong": self = .aes256
        default: return nil
        }
    }
}
