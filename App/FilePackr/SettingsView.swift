import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser

/// Ajustes de la app. Se presenta como ventana propia desde el menú (⌘,).
struct SettingsView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Formatos ofrecidos como "por defecto" (escribibles y multi-fichero).
    private var defaultFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isWritable && !$0.isSingleFileOnly }
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
                Button(loc("button.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    private func chooseFixedFolder() {
        if let url = chooseFolderPanel(prompt: loc("panel.choose"), startingAt: settings.fixedExtractFolder) {
            settings.fixedExtractFolder = url
        }
    }
}
