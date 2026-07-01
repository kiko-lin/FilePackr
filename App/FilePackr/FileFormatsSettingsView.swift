import SwiftUI
import AppKit
import ArchiveBrowser
import FilePackrModel

/// Pestaña "Archivos" de Ajustes: lista de formatos que FilePackr puede abrir, cada uno con su
/// icono y una casilla para hacerse (o dejar de ser) la app por defecto en el Finder.
///
/// Las casillas reflejan la **realidad del sistema** (consultada a `DefaultHandler`), no una
/// preferencia interna: marcada = FilePackr es AHORA el predeterminado del tipo. Así se evita
/// el desajuste "marcada pero sin aplicar" (p. ej. si el usuario declina el aviso de macOS 26).
struct FileFormatsSettingsView: View {
    /// Estado real "¿FilePackr es el predeterminado?" por formato. Se relee de macOS al abrir
    /// y tras cada cambio (los cambios son asíncronos: median un aviso de confirmación del SO).
    @State private var isDefault: [ArchiveFormat: Bool] = [:]

    private let formats = ArchiveFormat.allCases
    private var allSelected: Bool { formats.allSatisfy { isDefault[$0] == true } }

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
        .onAppear(perform: refreshStates)
    }

    /// Relee de macOS quién es el predeterminado de cada tipo. Se llama al abrir y tras cada
    /// cambio (asíncrono), para que las casillas reflejen la asociación REAL.
    private func refreshStates() {
        var map: [ArchiveFormat: Bool] = [:]
        for format in formats { map[format] = DefaultHandler.isDefault(format) }
        isDefault = map
    }

    /// Marcar → FilePackr se hace el predeterminado. Desmarcar → se lo devuelve a otra app que
    /// abra el tipo (si la hay). En ambos casos macOS 26 pide confirmación; al terminar se relee
    /// el estado real, así que si el usuario declina, la casilla vuelve a su sitio.
    private func binding(for format: ArchiveFormat) -> Binding<Bool> {
        Binding(
            get: { isDefault[format] ?? false },
            set: { on in
                if on { DefaultHandler.setAsDefault(format, completion: refreshStates) }
                else  { DefaultHandler.clearDefault(format, completion: refreshStates) }
            }
        )
    }

    private func toggleAll() {
        let turnOn = !allSelected
        for format in formats {
            if turnOn { DefaultHandler.setAsDefault(format, completion: refreshStates) }
            else      { DefaultHandler.clearDefault(format, completion: refreshStates) }
        }
    }
}
