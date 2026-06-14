import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser

/// Ventana modal de Ajustes (se presenta como hoja, bloqueando lo de debajo).
struct SettingsView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var settings: AppSettings
    var onClose: () -> Void

    /// Formatos ofrecidos como "por defecto" (se omiten los de un solo fichero: gz/xz).
    private var defaultFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { !$0.isSingleFileOnly }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("settings.title")).font(.title2).bold()
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)

            Form {
                Section {
                    Picker(loc("settings.language"), selection: $loc.language) {
                        ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker(loc("settings.appearance"), selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { Text(loc($0.nameKey)).tag($0) }
                    }
                }

                Section(loc("settings.appIcon")) {
                    iconPicker
                }

                Section {
                    Picker(loc("settings.defaultFormat"), selection: $settings.defaultFormat) {
                        ForEach(defaultFormats, id: \.self) { Text(loc($0.nameKey)).tag($0) }
                    }
                    Picker(loc("settings.defaultEncryption"), selection: $settings.defaultEncryption) {
                        Text(loc("save.encryption.none")).tag(ZipEncryption.none)
                        Text(loc("save.encryption.weak")).tag(ZipEncryption.zipCrypto)
                        Text(loc("save.encryption.strong")).tag(ZipEncryption.aes256)
                    }
                }

                Section {
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
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(loc("button.done"), action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    /// Selector horizontal de iconos (muestra los del catálogo `AppIconOption.all`).
    private var iconPicker: some View {
        HStack(spacing: 14) {
            ForEach(AppIconOption.all) { option in
                Button {
                    settings.appIconID = option.id
                } label: {
                    if let image = option.previewImage {
                        Image(nsImage: image)
                            .resizable().interpolation(.high)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(.tint, lineWidth: settings.appIconID == option.id ? 3 : 0)
                            }
                    }
                }
                .buttonStyle(.plain)
                .help(loc(option.labelKey))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func chooseFixedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = loc("panel.choose")
        if let current = settings.fixedExtractFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            settings.fixedExtractFolder = url
        }
    }
}
