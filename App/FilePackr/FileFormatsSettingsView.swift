import SwiftUI
import AppKit
import ArchiveBrowser

/// Pestaña "Archivos" de Ajustes: lista de formatos que FilePackr puede abrir, cada uno
/// con su icono y un check para hacerse app por defecto en el Finder (vía `DefaultHandler`).
struct FileFormatsSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    private let formats = ArchiveFormat.allCases
    private var allSelected: Bool { settings.associatedFormats.count == formats.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc("settings.files.header"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(allSelected ? loc("settings.files.deselectAll") : loc("settings.files.selectAll"),
                       action: toggleAll)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)

            List {
                ForEach(formats, id: \.self) { format in
                    HStack(spacing: 10) {
                        Toggle(isOn: binding(for: format)) { }
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Image(nsImage: NSImage(named: format.iconAssetName) ?? NSImage())
                            .resizable().scaledToFit()
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(loc(format.nameKey))
                            Text(format.displayExtensions)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Text(loc("settings.files.note"))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
    }

    /// Pertenencia del formato al conjunto; al marcar, lo registra como handler por defecto.
    private func binding(for format: ArchiveFormat) -> Binding<Bool> {
        Binding(
            get: { settings.associatedFormats.contains(format) },
            set: { on in
                if on {
                    settings.associatedFormats.insert(format)
                    DefaultHandler.setAsDefault(format)
                } else {
                    settings.associatedFormats.remove(format)
                }
            }
        )
    }

    private func toggleAll() {
        if allSelected {
            settings.associatedFormats = []
        } else {
            settings.associatedFormats = Set(formats)
            DefaultHandler.apply(settings.associatedFormats)
        }
    }
}
