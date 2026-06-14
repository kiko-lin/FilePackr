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

/// Un icono de app seleccionable (image set de Assets).
struct AppIconOption: Identifiable, Equatable {
    let id: String
    let assetName: String
    let labelKey: String

    /// Catálogo de iconos disponibles.
    static let all: [AppIconOption] = [
        AppIconOption(id: "orange", assetName: "AppIconOrange", labelKey: "icon.orange"),
        AppIconOption(id: "green",  assetName: "AppIconGreen",  labelKey: "icon.green"),
        AppIconOption(id: "purple", assetName: "AppIconPurple", labelKey: "icon.purple"),
        AppIconOption(id: "blue",   assetName: "AppIconBlue",   labelKey: "icon.blue"),
        AppIconOption(id: "red",    assetName: "AppIconRed",    labelKey: "icon.red"),
    ]

    /// Por defecto: naranja (color de marca).
    static let `default` = all[0]

    /// Imagen para mostrar en el selector.
    var previewImage: NSImage? { NSImage(named: assetName) }
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
        guard let image = NSImage(named: selectedIcon.assetName) else { return }
        NSApp.applicationIconImage = Self.rounded(image)
    }

    /// Recorta la imagen a un cuadrado de esquinas redondeadas (estilo macOS), ya que
    /// `applicationIconImage` no aplica la máscara del sistema.
    private static func rounded(_ image: NSImage) -> NSImage {
        let side: CGFloat = 512
        let size = NSSize(width: side, height: side)
        let result = NSImage(size: size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: side * 0.2237, yRadius: side * 0.2237).addClip()
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
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
