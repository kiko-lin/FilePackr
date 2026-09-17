import SwiftUI
import AppKit

/// Ventana **Acerca de FilePackr** propia, en lugar del panel estándar de macOS: el estándar
/// tiene un ancho fijo y pega los créditos a los bordes de su caja, y los créditos incluyen el
/// párrafo largo que exige la licencia de unrar. El texto sale de `Credits.rtf` (bundle).
struct AboutView: View {
    static let windowID = "about"

    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(info["CFBundleName"] as? String ?? "FilePackr")
                .font(.title2).bold()
            Text(loc("about.version",
                     info["CFBundleShortVersionString"] as? String ?? "",
                     info["CFBundleVersion"] as? String ?? ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            CreditsTextView()
                .frame(height: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .padding(.top, 4)
            if let copyright = info["NSHumanReadableCopyright"] as? String {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

/// `Credits.rtf` en un `NSTextView` de solo lectura con margen interior. El RTF no fija color:
/// se fuerza `labelColor` para que se lea en modo claro y oscuro.
private struct CreditsTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
           let credits = try? NSMutableAttributedString(url: url, options: [:], documentAttributes: nil) {
            credits.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                 range: NSRange(location: 0, length: credits.length))
            textView.textStorage?.setAttributedString(credits)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Sustituye «Acerca de FilePackr» del menú de la app para abrir `AboutView`.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(loc("about.title")) { openWindow(id: AboutView.windowID) }
        }
    }
}
