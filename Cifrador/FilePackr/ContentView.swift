import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Conflicto al extraer: ya existe un fichero/carpeta con ese nombre en destino.
private struct ExtractionConflict: Identifiable {
    let id = UUID()
    let plan: ExportPlan
    let destination: URL    // ruta que ya existe
    let alternative: URL    // nombre libre propuesto (p.ej. "3d_2.svg")
}

/// Petición de contraseña: para abrir un archivo cifrado o para guardar cifrando.
private enum PasswordRequest: Identifiable {
    case open(URL)
    case saveEncrypted(URL)

    var id: String {
        switch self {
        case .open(let url): return "open:" + url.path
        case .saveEncrypted(let url): return "save:" + url.path
        }
    }
    var title: String {
        switch self {
        case .open: return "Contraseña para abrir el archivo"
        case .saveEncrypted: return "Contraseña para cifrar el archivo"
        }
    }
    var confirmLabel: String {
        switch self {
        case .open: return "Abrir"
        case .saveEncrypted: return "Cifrar y guardar"
        }
    }
}

/// Hoja de introducción de contraseña.
private struct PasswordSheet: View {
    let title: String
    let confirmLabel: String
    @Binding var password: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            SecureField("Contraseña", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if !password.isEmpty { onConfirm() } }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
    }
}

/// Gestor de archivos comprimidos: barra superior + barra de documento + cuerpo
/// central (zona de arrastre cuando está vacío, o el navegador `NSOutlineView`).
struct ContentView: View {
    @StateObject private var doc = ArchiveDocument()
    @State private var errorMessage: String?
    @State private var conflict: ExtractionConflict?
    @State private var confirmingClose = false
    @State private var passwordRequest: PasswordRequest?
    @State private var passwordInput = ""

    var body: some View {
        VStack(spacing: 0) {
            if !doc.isEmpty {
                documentBar
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        .confirmationDialog("Hay cambios sin guardar en «\(doc.documentName)»",
                            isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Cerrar sin guardar", role: .destructive) { doc.close() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Si cierras ahora perderás los cambios no guardados.")
        }
        .alert("No se pudo completar la operación",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button("Aceptar") {}
        } message: { Text($0) }
        .confirmationDialog(
            conflict.map { "Ya existe «\($0.destination.lastPathComponent)» en el destino" } ?? "",
            isPresented: Binding(get: { conflict != nil },
                                 set: { if !$0 { conflict = nil } }),
            presenting: conflict
        ) { item in
            Button("Sobrescribir", role: .destructive) {
                let plan = item.plan, destination = item.destination
                conflict = nil
                Task { await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: true) } }
            }
            Button("Guardar como \(item.alternative.lastPathComponent)") {
                let plan = item.plan, destination = item.alternative
                conflict = nil
                Task { await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: false) } }
            }
            Button("Cancelar", role: .cancel) { conflict = nil }
        }
        .overlay { progressOverlay }
        .sheet(item: $passwordRequest) { request in
            PasswordSheet(title: request.title,
                          confirmLabel: request.confirmLabel,
                          password: $passwordInput,
                          onConfirm: { confirmPassword(request) },
                          onCancel: { dismissPassword() })
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = doc.progress {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(progress.label).font(.callout)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(width: 240)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Cuerpo central

    @ViewBuilder
    private var content: some View {
        if doc.isEmpty {
            dropPrompt
                .dropDestination(for: URL.self) { urls, _ in
                    handleOpen(urls)
                    return true
                }
        } else {
            ArchiveOutlineView(doc: doc, onExtract: { extract($0) })
        }
    }

    /// Barra intermedia: icono + nombre del archivo y acciones Cerrar / Guardar.
    private var documentBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: .zip))
                .resizable()
                .frame(width: 16, height: 16)
            Text(doc.documentName)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if doc.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Archivo cifrado")
            }
            if doc.hasUnsavedChanges {
                Text("— sin guardar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cerrar") { attemptClose() }
            Button { promptSaveEncrypted() } label: {
                Image(systemName: "lock")
            }
            .help("Guardar cifrado con contraseña…")
            .disabled(doc.isEmpty)
            Button("Guardar") { saveDocument() }
                .disabled(!doc.hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var dropPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Arrastra archivos aquí")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Un .zip se abrirá para editarlo; otros archivos crearán uno nuevo.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Barra superior

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: addAction) {
                Label("Añadir", systemImage: "plus")
            }
            .help("Añadir archivos, o abrir un .zip si es el primero")

            Button(action: doc.removeSelected) {
                Label("Eliminar", systemImage: "trash")
            }
            .disabled(doc.selection == nil)
            .help("Eliminar el elemento seleccionado")

            Button(action: doc.createFolder) {
                Label("Crear carpeta", systemImage: "folder.badge.plus")
            }
            .help("Crear una carpeta")

            Button(action: extractAction) {
                Label("Extraer", systemImage: "square.and.arrow.up")
            }
            .disabled(doc.selection == nil)
            .help("Extraer el elemento seleccionado a una ubicación")
        }
    }

    // MARK: - Acciones con paneles del sistema

    private func addAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir"
        if panel.runModal() == .OK {
            handleOpen(panel.urls)
        }
    }

    /// Abre lo seleccionado; si es un único archivo cifrado, pide contraseña.
    private func handleOpen(_ urls: [URL]) {
        if doc.isEmpty, urls.count == 1, doc.isEncryptedFile(urls[0]) {
            passwordInput = ""
            passwordRequest = .open(urls[0])
        } else {
            run { try doc.handleIncoming(urls) }
        }
    }

    private func promptSaveEncrypted() {
        let panel = NSSavePanel()
        let base = doc.documentName == ArchiveDocument.untitledName
            ? doc.documentName
            : (doc.documentName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(ArchiveDocument.encryptedExtension)"
        panel.prompt = "Cifrar y guardar"
        if panel.runModal() == .OK, let url = panel.url {
            passwordInput = ""
            passwordRequest = .saveEncrypted(url)
        }
    }

    private func confirmPassword(_ request: PasswordRequest) {
        let password = passwordInput
        dismissPassword()
        switch request {
        case .open(let url):
            Task { await runAsync { try await doc.openEncrypted(url, password: password) } }
        case .saveEncrypted(let url):
            Task { await runAsync { try await doc.saveEncrypted(to: url, password: password) } }
        }
    }

    private func dismissPassword() {
        passwordRequest = nil
        passwordInput = ""
    }

    private func extractAction() {
        guard let node = doc.selectedNode() else { return }
        extract(node)
    }

    /// Extrae un nodo concreto: pide carpeta destino y gestiona conflictos de nombre.
    private func extract(_ node: FileNode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extraer aquí"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let plan = doc.exportPlan(for: node)
        let destination = dir.appendingPathComponent(node.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            conflict = ExtractionConflict(plan: plan,
                                          destination: destination,
                                          alternative: doc.conflictFreeURL(for: destination))
        } else {
            Task { await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: false) } }
        }
    }

    /// Guarda: sobre el fichero de origen si existe, o pide ubicación si es nuevo.
    private func saveDocument() {
        if let url = doc.sourceURL {
            Task { await runAsync { try await doc.save(to: url) } }
        } else {
            saveAsPanel()
        }
    }

    private func saveAsPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let base = doc.documentName == ArchiveDocument.untitledName
            ? doc.documentName
            : (doc.documentName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).zip"
        panel.prompt = "Guardar"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await runAsync { try await doc.save(to: url) } }
        }
    }

    /// Cierra el documento; si hay cambios sin guardar, pide confirmación.
    private func attemptClose() {
        if doc.hasUnsavedChanges {
            confirmingClose = true
        } else {
            doc.close()
        }
    }

    private func run(_ op: () throws -> Void) {
        do { try op() } catch { errorMessage = "\(error)" }
    }

    private func runAsync(_ op: () async throws -> Void) async {
        do { try await op() } catch { errorMessage = "\(error)" }
    }
}

#Preview {
    ContentView()
}
