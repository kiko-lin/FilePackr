import SwiftUI
import AppKit

/// Ventana de **Ayuda** de la app, abierta desde el menú Ayuda (⌘?) —ver `HelpCommands`.
///
/// El contenido son secciones fijas (título + viñetas) resueltas por `loc(...)` contra el
/// catálogo (`Localizable.xcstrings`), así que sigue el idioma del sistema como el resto de la
/// interfaz. Cada `body` guarda sus viñetas en una sola cadena separada por saltos de línea;
/// la vista las divide y admite **negrita** Markdown por línea (`**texto**`).
struct HelpView: View {
    /// (títuloClave, cuerpoClave) de cada sección, en orden de lectura.
    private let sections: [(String, String)] = [
        ("help.open.title", "help.open.body"),
        ("help.navigate.title", "help.navigate.body"),
        ("help.edit.title", "help.edit.body"),
        ("help.extract.title", "help.extract.body"),
        ("help.save.title", "help.save.body"),
        ("help.password.title", "help.password.body"),
        ("help.settings.title", "help.settings.body"),
        ("help.shortcuts.title", "help.shortcuts.body"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ForEach(sections, id: \.0) { section($0.0, $0.1) }
                Divider()
                Text(loc("help.footer"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 640)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("help.title")).font(.title2).bold()
                Text(loc("help.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(titleKey)).font(.headline)
            ForEach(bulletLines(loc(bodyKey)), id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(markdown(line)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Divide el cuerpo de una sección en viñetas (una por línea no vacía).
    private func bulletLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Interpreta la negrita Markdown (`**…**`); si falla, muestra el texto tal cual.
    private func markdown(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line)) ?? AttributedString(line)
    }
}
