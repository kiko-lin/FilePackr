import SwiftUI
import UniformTypeIdentifiers
import CryptoCore

/// Cifra o descifra un fichero elegido por el usuario.
/// El mismo panel sirve para ambas operaciones (requisito: cifrar Y descifrar).
struct CipherView: View {
    private let core = CryptoCore()

    @State private var sourceURL: URL?
    @State private var password = ""
    @State private var status: String = ""
    @State private var working = false

    var body: some View {
        Form {
            Section("Fichero") {
                HStack {
                    Text(sourceURL?.lastPathComponent ?? "Ningún fichero seleccionado")
                        .foregroundStyle(sourceURL == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Elegir…", action: chooseFile)
                }
            }

            Section("Contraseña") {
                SecureField("Contraseña", text: $password)
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        run { try encrypt() }
                    } label: {
                        Label("Cifrar", systemImage: "lock.fill")
                    }
                    .disabled(!canRun)

                    Button {
                        run { try decrypt() }
                    } label: {
                        Label("Descifrar", systemImage: "lock.open.fill")
                    }
                    .disabled(!canRun)

                    if working { ProgressView().controlSize(.small) }
                }
            }

            if !status.isEmpty {
                Section { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var canRun: Bool { sourceURL != nil && !password.isEmpty && !working }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { sourceURL = panel.url; status = "" }
    }

    private func run(_ op: @escaping () throws -> Void) {
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            do { try op() } catch { setStatus("Error: \(error)") }
            DispatchQueue.main.async { working = false }
        }
    }

    private func encrypt() throws {
        guard let src = sourceURL else { return }
        let dst = src.appendingPathExtension("cifr")
        try core.encryptFile(at: src, to: dst, password: password)
        setStatus("Cifrado en \(dst.lastPathComponent)")
    }

    private func decrypt() throws {
        guard let src = sourceURL else { return }
        // "foto.png.cifr" -> "foto.png"; si no tenía ".cifr", añadimos un sufijo claro.
        let recovered = src.pathExtension == "cifr"
            ? src.deletingPathExtension()
            : src.deletingPathExtension().appendingPathExtension("descifrado.\(src.pathExtension)")
        let dst = uniqueURL(for: recovered)
        try core.decryptFile(at: src, to: dst, password: password)
        setStatus("Descifrado en \(dst.lastPathComponent)")
    }

    /// Evita sobrescribir: si el destino existe, añade " (1)", " (2)", …
    private func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent("\(base) (\(n))")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { status = text }
    }
}

#Preview {
    CipherView()
}
