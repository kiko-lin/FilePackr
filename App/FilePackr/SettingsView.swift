import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser
import FilePackrModel

/// Ajustes de la app. Se presenta como ventana propia desde el menú (⌘,), con pestañas
/// General (preferencias) y Archivos (asociación de formatos en el Finder).
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Formatos ofrecidos como "por defecto" (escribibles y multi-fichero).
    private var defaultFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isWritable && !$0.isSingleFileOnly }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $settings.selectedSettingsTab) {
                general
                    .tabItem { Label(loc("settings.tab.general"), systemImage: SettingsTab.general.systemImage) }
                    .tag(SettingsTab.general)

                FileFormatsSettingsView()
                    .tabItem { Label(loc("settings.tab.files"), systemImage: SettingsTab.files.systemImage) }
                    .tag(SettingsTab.files)
            }

            Divider()
            HStack {
                Spacer()
                Button(loc("button.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 480, height: 460)
    }

    /// Pestaña General: apariencia + los valores por defecto de cada operación (comprimir,
    /// extraer, añadir). El idioma lo gobierna el sistema (Ajustes → Idioma y región), no la app.
    private var general: some View {
        Form {
            Section {
                Picker(loc("settings.appearance"), selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text(loc($0.nameKey)).tag($0) }
                }
            }

            // Valores por defecto de cada operación: comprimir (formato/cifrado/nivel),
            // extraer (destino) y añadir (política de ocultos). Todos se preseleccionan y se
            // pueden cambiar en su operación (salvo la política de añadir, que rige siempre).
            Section {
                Picker(loc("settings.defaultFormat"), selection: $settings.defaultFormat) {
                    Text(loc("settings.lastUsed")).tag(ArchiveFormat?.none)
                    ForEach(defaultFormats, id: \.self) { Text(loc($0.nameKey)).tag(ArchiveFormat?.some($0)) }
                }
                Picker(loc("settings.defaultEncryption"), selection: $settings.defaultEncryption) {
                    Text(loc("settings.lastUsed")).tag(ZipEncryption?.none)
                    Text(loc("save.encryption.none")).tag(ZipEncryption?.some(.none))
                    Text(loc("save.encryption.weak")).tag(ZipEncryption?.some(.zipCrypto))
                    Text(loc("save.encryption.strong")).tag(ZipEncryption?.some(.aes256))
                }
                Picker(loc("settings.defaultLevel"), selection: $settings.defaultCompressionLevel) {
                    Text(loc("settings.lastUsed")).tag(CompressionLevel?.none)
                    ForEach(CompressionLevel.allCases, id: \.self) { Text(loc($0.nameKey)).tag(CompressionLevel?.some($0)) }
                }
                Picker(loc("settings.extractTo"), selection: $settings.extractMode) {
                    ForEach(ExtractDestinationMode.allCases) { Text(loc($0.nameKey)).tag($0) }
                }
                if settings.extractMode == .fixedFolder {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                            .resizable().frame(width: 16, height: 16)
                        Text(settings.fixedExtractFolder?.lastPathComponent ?? loc("settings.noFolder"))
                            .foregroundStyle(settings.fixedExtractFolder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(loc("extract.choose"), action: chooseFixedFolder)
                    }
                } else if settings.extractMode == .lastUsedFolder {
                    // Solo informativa: la fija cada extracción, no se elige aquí.
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                            .resizable().frame(width: 16, height: 16)
                        Text(settings.lastUsedExtractFolder?.lastPathComponent ?? loc("settings.noFolder"))
                            .foregroundStyle(settings.lastUsedExtractFolder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                Picker(loc("settings.addHidden"), selection: $settings.addHiddenPolicy) {
                    ForEach(AddHiddenPolicy.allCases) { Text(loc($0.nameKey)).tag($0) }
                }
            } header: {
                Text(loc("settings.section.defaults"))
            } footer: {
                Text(loc("settings.addHidden.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFixedFolder() {
        if let url = chooseFolderPanel(prompt: loc("panel.choose"), startingAt: settings.fixedExtractFolder) {
            settings.fixedExtractFolder = url
        }
    }
}
