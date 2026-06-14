import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser

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

    var id: String {
        switch self {
        case .open(let url): return "open:" + url.path
        }
    }
    var title: String { "Contraseña para abrir el archivo" }
    var confirmLabel: String { "Abrir" }
}

/// Unidad de tamaño de volumen.
enum VolumeUnit: String, CaseIterable, Identifiable {
    case kilobytes = "KB", megabytes = "MB", gigabytes = "GB"
    var id: String { rawValue }
    var multiplier: Int {
        switch self {
        case .kilobytes: return 1024
        case .megabytes: return 1024 * 1024
        case .gigabytes: return 1024 * 1024 * 1024
        }
    }
}

/// Hoja "Guardar archivo": formato, cifrado, contraseña y división en volúmenes.
private struct SaveOptionsSheet: View {
    @Binding var format: ArchiveFormat
    @Binding var encryption: ZipEncryption
    @Binding var password: String
    @Binding var splitEnabled: Bool
    @Binding var volumeSize: Double
    @Binding var volumeUnit: VolumeUnit
    /// `.gz` (un solo fichero) solo se ofrece cuando el documento es un único fichero.
    let allowGzip: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    private var formats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0 != .gzip || allowGzip }
    }

    /// El botón Guardar se bloquea si falta la contraseña o el tamaño de volumen no es válido.
    private var canSave: Bool {
        if format.supportsEncryption && encryption != .none && password.isEmpty { return false }
        if splitEnabled && format.supportsVolumeSplit && volumeSize <= 0 { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Guardar archivo").font(.headline)
            Form {
                Picker("Formato", selection: $format) {
                    ForEach(formats, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                if format.supportsEncryption {
                    Picker("Cifrado", selection: $encryption) {
                        Text("No cifrado").tag(ZipEncryption.none)
                        Text("Débil (PKZip2 compatible)").tag(ZipEncryption.zipCrypto)
                        Text("Fuerte (AES-256)").tag(ZipEncryption.aes256)
                    }
                    if encryption != .none {
                        SecureField("Contraseña", text: $password)
                            .onSubmit { if canSave { onSave() } }
                    }
                } else {
                    Text("Este formato no admite cifrado.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if format.supportsVolumeSplit {
                    Toggle("Dividir en volúmenes", isOn: $splitEnabled)
                    if splitEnabled {
                        HStack {
                            Text("Tamaño de cada volumen")
                            Spacer()
                            TextField("", value: $volumeSize, format: .number)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $volumeUnit) {
                                ForEach(VolumeUnit.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }
                        Text("Se generarán «nombre.\(format.fileExtension).001», «.002»… Para abrirlo, selecciona el «.001».")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Guardar…", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Hoja compacta de extracción: destino (carpeta del zip por defecto) + contraseña.
/// El navegador de carpetas solo aparece al pulsar "Elegir…".
private struct ExtractOptionsSheet: View {
    let nodeName: String
    let needsPassword: Bool
    @Binding var destination: URL
    @Binding var password: String
    var passwordWrong: Bool
    var onChooseFolder: () -> Void
    var onExtract: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Extraer «\(nodeName)»").font(.headline)
            HStack(spacing: 6) {
                Text("En:").foregroundStyle(.secondary)
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable().frame(width: 16, height: 16)
                Text(destination.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Elegir…", action: onChooseFolder)
            }
            if needsPassword {
                SecureField("Contraseña del archivo", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !password.isEmpty { onExtract() } }
                if passwordWrong {
                    Text("Contraseña incorrecta.").font(.callout).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Extraer", action: onExtract)
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsPassword && password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Hoja de introducción de contraseña.
private struct PasswordSheet: View {
    let title: String
    let confirmLabel: String
    @Binding var password: String
    var note: String? = nil
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            SecureField("Contraseña", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if !password.isEmpty { onConfirm() } }
            if let note {
                Text(note).font(.callout).foregroundStyle(.red)
            }
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
    @State private var showingSaveOptions = false
    @State private var saveFormatChoice: ArchiveFormat = .zip
    @State private var saveEncryptionChoice: ZipEncryption = .none
    @State private var saveOptionsPassword = ""
    @State private var splitEnabled = false
    @State private var volumeSizeValue: Double = 100
    @State private var volumeUnit: VolumeUnit = .megabytes
    @State private var showingEntryPassword = false
    @State private var entryPasswordInput = ""
    @State private var entryPasswordWrong = false
    @State private var extractNode: FileNode?
    @State private var extractDestination = FileManager.default.homeDirectoryForCurrentUser
    @State private var extractPassword = ""
    @State private var extractPasswordWrong = false

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
        .sheet(isPresented: $showingSaveOptions) {
            SaveOptionsSheet(format: $saveFormatChoice,
                             encryption: $saveEncryptionChoice,
                             password: $saveOptionsPassword,
                             splitEnabled: $splitEnabled,
                             volumeSize: $volumeSizeValue,
                             volumeUnit: $volumeUnit,
                             allowGzip: doc.isSingleFile,
                             onSave: { confirmSaveOptions() },
                             onCancel: { showingSaveOptions = false })
        }
        .sheet(isPresented: $showingEntryPassword) {
            PasswordSheet(title: "Contraseña del archivo",
                          confirmLabel: "Abrir",
                          password: $entryPasswordInput,
                          note: entryPasswordWrong ? "Contraseña incorrecta." : nil,
                          onConfirm: { confirmEntryPassword() },
                          onCancel: { showingEntryPassword = false })
        }
        .sheet(item: $extractNode) { node in
            ExtractOptionsSheet(nodeName: node.name,
                                needsPassword: doc.requiresEntryPassword,
                                destination: $extractDestination,
                                password: $extractPassword,
                                passwordWrong: extractPasswordWrong,
                                onChooseFolder: { chooseExtractFolder() },
                                onExtract: { performExtract() },
                                onCancel: { extractNode = nil })
        }
        .onChange(of: doc.requiresEntryPassword) { _, requires in
            if requires { promptEntryPassword() }
        }
    }

    /// Muestra la hoja para introducir la contraseña del archivo cifrado.
    private func promptEntryPassword() {
        guard doc.requiresEntryPassword else { return }
        entryPasswordInput = ""
        entryPasswordWrong = false
        showingEntryPassword = true
    }

    private func confirmEntryPassword() {
        if doc.provideEntryPassword(entryPasswordInput) {
            showingEntryPassword = false
        } else {
            entryPasswordWrong = true
            entryPasswordInput = ""
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = doc.progress {
            ZStack {
                // Fondo opaco: oculta por completo lo que haya debajo.
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(progress.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 260)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
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
            ArchiveOutlineView(doc: doc,
                               onExtract: { extract($0) },
                               onNeedPassword: { promptEntryPassword() })
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
            if doc.isEncrypted || doc.saveEncryption != .none {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Archivo cifrado")
            }
            if doc.saveVolumeSize != nil {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
                    .help("Guardado en volúmenes")
            }
            if doc.hasUnsavedChanges {
                Text("— sin guardar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cerrar") { attemptClose() }
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
            Text("Un .zip, .tar, .tar.gz o .gz se abrirá para editarlo; otros archivos crearán uno nuevo.")
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

            Button { editGuarded { doc.removeSelected() } } label: {
                Label("Eliminar", systemImage: "trash")
            }
            .disabled(doc.selection == nil)
            .help("Eliminar el elemento seleccionado")

            Button { editGuarded { doc.createFolder() } } label: {
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

    /// Ejecuta una edición; si el archivo está cifrado y bloqueado, pide la contraseña.
    private func editGuarded(_ action: () -> Void) {
        if doc.isLocked { promptEntryPassword() } else { action() }
    }

    private func addAction() {
        if doc.isLocked { promptEntryPassword(); return }
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
            Task { await runAsync { try await doc.handleIncoming(urls) } }
        }
    }

    private func confirmPassword(_ request: PasswordRequest) {
        let password = passwordInput
        dismissPassword()
        switch request {
        case .open(let url):
            Task { await runAsync { try await doc.openEncrypted(url, password: password) } }
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
    /// Abre el diálogo compacto de extracción (destino por defecto: carpeta del zip).
    private func extract(_ node: FileNode) {
        extractDestination = doc.sourceURL?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        extractPassword = ""
        extractPasswordWrong = false
        extractNode = node
    }

    /// "Elegir…": abre el navegador de carpetas solo si se quiere cambiar el destino.
    private func chooseExtractFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Elegir"
        panel.directoryURL = extractDestination
        if panel.runModal() == .OK, let url = panel.url {
            extractDestination = url
        }
    }

    /// Confirma la extracción del nodo del diálogo al destino elegido.
    private func performExtract() {
        guard let node = extractNode else { return }
        if doc.requiresEntryPassword {
            guard doc.provideEntryPassword(extractPassword) else {
                extractPasswordWrong = true
                extractPassword = ""
                return
            }
        }
        let destinationFolder = extractDestination
        extractNode = nil

        let plan = doc.exportPlan(for: node)
        let destination = destinationFolder.appendingPathComponent(node.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            conflict = ExtractionConflict(plan: plan,
                                          destination: destination,
                                          alternative: doc.conflictFreeURL(for: destination))
        } else {
            Task { await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: false) } }
        }
    }

    /// Guarda: si ya tiene fichero, re-guarda con los ajustes; si es nuevo, abre el
    /// diálogo de opciones (formato + cifrado + contraseña).
    private func saveDocument() {
        if doc.requiresEntryPassword { promptEntryPassword(); return }
        if let url = doc.sourceURL {
            Task { await runAsync { try await doc.save(to: url) } }
        } else {
            saveFormatChoice = doc.isSingleFile ? doc.saveFormat : (doc.saveFormat == .gzip ? .zip : doc.saveFormat)
            saveEncryptionChoice = doc.saveEncryption
            saveOptionsPassword = ""
            if let size = doc.saveVolumeSize {
                splitEnabled = true
                volumeUnit = .megabytes
                volumeSizeValue = max(1, (Double(size) / Double(VolumeUnit.megabytes.multiplier)).rounded())
            } else {
                splitEnabled = false
            }
            showingSaveOptions = true
        }
    }

    /// Tras elegir opciones, pide ubicación y guarda el archivo con el formato/cifrado elegidos.
    private func confirmSaveOptions() {
        showingSaveOptions = false
        let format = saveFormatChoice
        let encryption = format.supportsEncryption ? saveEncryptionChoice : .none
        let password = encryption == .none ? nil : saveOptionsPassword
        let volumeSize = (splitEnabled && format.supportsVolumeSplit && volumeSizeValue > 0)
            ? Int(volumeSizeValue * Double(volumeUnit.multiplier)) : nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .zip ? [.zip] : []
        panel.nameFieldStringValue = "\(strippedBaseName(doc.documentName)).\(format.fileExtension)"
        panel.prompt = "Guardar"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await runAsync {
                try await doc.save(to: url, format: format, encryption: encryption,
                                   password: password, volumeSize: volumeSize)
            } }
        }
    }

    /// Nombre base sin la extensión de archivo conocida (zip/tar/tar.gz/tgz/gz/fpkz).
    private func strippedBaseName(_ name: String) -> String {
        if name == ArchiveDocument.untitledName { return name }
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tgz", ".tar", ".zip", ".gz", ".fpkz"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return (name as NSString).deletingPathExtension
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
