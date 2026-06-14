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
    case archiveFolder, fixedFolder
    var id: String { rawValue }
    var nameKey: String {
        self == .archiveFolder ? "extract.dest.archiveFolder" : "extract.dest.fixedFolder"
    }
}

/// Un icono de app seleccionable. `assetName == nil` es el icono por defecto del bundle.
struct AppIconOption: Identifiable, Equatable {
    let id: String
    let assetName: String?
    let labelKey: String

    /// Icono por defecto (el del propio bundle).
    static let `default` = AppIconOption(id: "default", assetName: nil, labelKey: "")

    /// Catálogo de iconos disponibles. Añadir aquí una entrada por cada juego de
    /// imágenes que se incluya en Assets (p. ej. `AppIconOption(id: "blue",
    /// assetName: "AppIconBlue", labelKey: "")`).
    static let all: [AppIconOption] = [.default]

    /// Imagen para mostrar en el selector (la del bundle si es el por defecto).
    var previewImage: NSImage? {
        if let assetName { return NSImage(named: assetName) }
        return NSApp.applicationIconImage
    }
}

/// Preferencias de la app (aparte del idioma, que gestiona `Localizer`). Se guardan
/// en `UserDefaults` y se aplican en caliente.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    @Published var defaultFormat: ArchiveFormat {
        didSet { defaults.set(defaultFormat.rawValue, forKey: "defaultFormat") }
    }
    @Published var defaultEncryption: ZipEncryption {
        didSet { defaults.set(defaultEncryption.persistID, forKey: "defaultEncryption") }
    }
    @Published var extractMode: ExtractDestinationMode {
        didSet { defaults.set(extractMode.rawValue, forKey: "extractMode") }
    }
    /// Carpeta fija de extracción (cuando `extractMode == .fixedFolder`).
    @Published var fixedExtractFolder: URL? {
        didSet { defaults.set(fixedExtractFolder?.path, forKey: "fixedExtractFolder") }
    }
    @Published var appIconID: String {
        didSet {
            defaults.set(appIconID, forKey: "appIconID")
            applyAppIcon()
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        defaultFormat = ArchiveFormat(rawValue: defaults.string(forKey: "defaultFormat") ?? "") ?? .zip
        defaultEncryption = ZipEncryption(persistID: defaults.string(forKey: "defaultEncryption") ?? "") ?? .none
        extractMode = ExtractDestinationMode(rawValue: defaults.string(forKey: "extractMode") ?? "") ?? .archiveFolder
        fixedExtractFolder = defaults.string(forKey: "fixedExtractFolder").map { URL(fileURLWithPath: $0) }
        appIconID = defaults.string(forKey: "appIconID") ?? AppIconOption.default.id
    }

    /// El icono elegido (o el por defecto si el guardado ya no existe).
    var selectedIcon: AppIconOption {
        AppIconOption.all.first { $0.id == appIconID } ?? .default
    }

    /// Aplica el icono elegido al Dock/ventanas de la app en ejecución. Hay que
    /// llamarlo al arrancar (el icono nativo no persiste entre lanzamientos).
    func applyAppIcon() {
        let icon = selectedIcon
        if let assetName = icon.assetName {
            NSApp.applicationIconImage = NSImage(named: assetName)
        } else {
            NSApp.applicationIconImage = nil   // restaura el del bundle
        }
    }
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
