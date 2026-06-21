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

/// Lo que se va a extraer: un nodo concreto o **todo** el archivo. El plan se construye
/// al confirmar (cuando ya tenemos la contraseña, si hacía falta).
private struct ExtractRequest: Identifiable {
    let id = UUID()
    let name: String
    let makePlan: () -> ExportPlan
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
    @EnvironmentObject var loc: Localizer
    @Binding var format: ArchiveFormat
    @Binding var encryption: ZipEncryption
    @Binding var password: String
    @Binding var splitEnabled: Bool
    @Binding var volumeSize: Double
    @Binding var volumeUnit: VolumeUnit
    /// Los formatos de un solo fichero (gz/xz) solo se ofrecen si el documento es un fichero.
    let allowSingleFileFormats: Bool
    /// Título de la hoja y etiqueta del botón de confirmar (Guardar vs Exportar).
    let title: String
    let confirmLabel: String
    var onSave: () -> Void
    var onCancel: () -> Void

    private var formats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isWritable && (!$0.isSingleFileOnly || allowSingleFileFormats) }
    }

    /// El botón Guardar se bloquea si falta la contraseña o el tamaño de volumen no es válido.
    private var canSave: Bool {
        if format.supportsEncryption && encryption != .none && password.isEmpty { return false }
        if splitEnabled && format.supportsVolumeSplit && volumeSize <= 0 { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                Picker(loc("save.format"), selection: $format) {
                    ForEach(formats, id: \.self) { fmt in
                        Text(loc(fmt.nameKey)).tag(fmt)
                    }
                }
                if format.supportsEncryption {
                    Picker(loc("save.encryption"), selection: $encryption) {
                        Text(loc("save.encryption.none")).tag(ZipEncryption.none)
                        Text(loc("save.encryption.weak")).tag(ZipEncryption.zipCrypto)
                        Text(loc("save.encryption.strong")).tag(ZipEncryption.aes256)
                    }
                    if encryption != .none {
                        SecureField(loc("save.password"), text: $password)
                            .onSubmit { if canSave { onSave() } }
                    }
                } else {
                    Text(loc("save.noEncryption"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if format.supportsVolumeSplit {
                    Toggle(loc("save.split"), isOn: $splitEnabled)
                    if splitEnabled {
                        HStack {
                            Text(loc("save.volumeSize"))
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
                        Text(loc("save.split.hint", format.fileExtension, format.fileExtension))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onSave)
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
    @EnvironmentObject var loc: Localizer
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
            Text(loc("extract.title", nodeName)).font(.headline)
            HStack(spacing: 6) {
                Text(loc("extract.in")).foregroundStyle(.secondary)
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable().frame(width: 16, height: 16)
                Text(destination.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(loc("extract.choose"), action: onChooseFolder)
            }
            if needsPassword {
                SecureField(loc("extract.password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !password.isEmpty { onExtract() } }
                if passwordWrong {
                    Text(loc("extract.wrongPassword")).font(.callout).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(loc("button.extract"), action: onExtract)
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
    @EnvironmentObject var loc: Localizer
    let title: String
    let confirmLabel: String
    @Binding var password: String
    var note: String? = nil
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            SecureField(loc("password.field"), text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if !password.isEmpty { onConfirm() } }
            if let note {
                Text(note).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(loc("button.cancel"), role: .cancel, action: onCancel)
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
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var doc = ArchiveDocument()
    @State private var errorMessage: String?
    @State private var conflict: ExtractionConflict?
    @State private var showingSaveOptions = false
    /// La hoja de opciones está abierta para **Exportar** (copia aparte) en vez de Guardar.
    @State private var optionsSheetIsExport = false
    @State private var saveFormatChoice: ArchiveFormat = .zip
    @State private var saveEncryptionChoice: ZipEncryption = .none
    @State private var saveOptionsPassword = ""
    @State private var splitEnabled = false
    @State private var volumeSizeValue: Double = 100
    @State private var volumeUnit: VolumeUnit = .megabytes
    @State private var showingEntryPassword = false
    @State private var entryPasswordInput = ""
    @State private var entryPasswordWrong = false
    @State private var showingOpenPassword = false
    @State private var openPasswordInput = ""
    @State private var openPasswordWrong = false
    @State private var extractRequest: ExtractRequest?
    @State private var extractDestination = FileManager.default.homeDirectoryForCurrentUser
    @State private var extractPassword = ""
    @State private var extractPasswordWrong = false

    var body: some View {
        VStack(spacing: 0) {
            if doc.isEmpty {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                documentBar          // grupo 2 · Archivo (cabecera)
                Divider()
                HStack(spacing: 0) {
                    interiorBar      // tira vertical de acciones (solo con archivo abierto)
                    Divider()        // línea separadora de la columna
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)   // el contenido sube a la zona del título
        .preferredColorScheme(settings.theme.colorScheme)
        .background(WindowGuard(edited: doc.hasUnsavedChanges))
        .alert(loc("error.title"),
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button(loc("button.ok")) {}
        } message: { Text($0) }
        .confirmationDialog(
            conflict.map { loc("conflict.title", $0.destination.lastPathComponent) } ?? "",
            isPresented: Binding(get: { conflict != nil },
                                 set: { if !$0 { conflict = nil } }),
            presenting: conflict
        ) { item in
            Button(loc("conflict.overwrite"), role: .destructive) {
                let plan = item.plan, destination = item.destination
                conflict = nil
                Task { await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: true) } }
            }
            Button(loc("conflict.saveAs", item.alternative.lastPathComponent)) {
                let plan = item.plan, destination = item.alternative
                conflict = nil
                Task { await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: false) } }
            }
            Button(loc("button.cancel"), role: .cancel) { conflict = nil }
        }
        .overlay { progressOverlay }
        .sheet(isPresented: $showingSaveOptions) {
            SaveOptionsSheet(format: $saveFormatChoice,
                             encryption: $saveEncryptionChoice,
                             password: $saveOptionsPassword,
                             splitEnabled: $splitEnabled,
                             volumeSize: $volumeSizeValue,
                             volumeUnit: $volumeUnit,
                             allowSingleFileFormats: doc.isSingleFile,
                             title: optionsSheetIsExport ? loc("export.title") : loc("save.title"),
                             confirmLabel: optionsSheetIsExport ? loc("button.export") : loc("button.saveEllipsis"),
                             onSave: { confirmSaveOptions() },
                             onCancel: { showingSaveOptions = false })
        }
        .sheet(isPresented: $showingEntryPassword) {
            PasswordSheet(title: loc("password.entryTitle"),
                          confirmLabel: loc("password.open"),
                          password: $entryPasswordInput,
                          note: entryPasswordWrong ? loc("password.wrong") : nil,
                          onConfirm: { confirmEntryPassword() },
                          onCancel: { showingEntryPassword = false })
        }
        .sheet(item: $extractRequest) { req in
            ExtractOptionsSheet(nodeName: req.name,
                                needsPassword: doc.requiresEntryPassword,
                                destination: $extractDestination,
                                password: $extractPassword,
                                passwordWrong: extractPasswordWrong,
                                onChooseFolder: { chooseExtractFolder() },
                                onExtract: { performExtract() },
                                onCancel: { extractRequest = nil })
        }
        .sheet(isPresented: $showingOpenPassword) {
            PasswordSheet(title: loc("password.openTitle"),
                          confirmLabel: loc("password.open"),
                          password: $openPasswordInput,
                          note: openPasswordWrong ? loc("password.wrong") : nil,
                          onConfirm: { confirmOpenPassword() },
                          onCancel: { showingOpenPassword = false; doc.close() })
        }
        .onChange(of: doc.requiresEntryPassword) { _, requires in
            if requires { promptEntryPassword() }
        }
        .onChange(of: doc.requiresOpenPassword) { _, requires in
            if requires {
                openPasswordInput = ""
                openPasswordWrong = false
                showingOpenPassword = true
            }
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

    private func confirmOpenPassword() {
        let password = openPasswordInput
        Task {
            if await doc.provideOpenPassword(password) {
                showingOpenPassword = false
            } else {
                openPasswordWrong = true
                openPasswordInput = ""
            }
        }
    }

    /// Nombre a mostrar del documento: el del fichero guardado, o "Sin título" (en el
    /// idioma actual) mientras no se haya guardado. La i18n vive en la vista, no en el modelo.
    private var documentDisplayName: String {
        doc.sourceURL == nil ? loc("doc.untitled") : doc.documentName
    }

    /// Traduce el token de progreso del modelo. Resolver el nombre vacío a "Sin título"
    /// reproduce el antiguo `displayName` para un documento aún sin guardar.
    private func progressLabel(_ kind: ProgressKind) -> String {
        switch kind {
        case .opening(let name): return loc("progress.opening", name)
        case .extracting: return loc("progress.extracting")
        case .compressing(let name): return loc("progress.compressing", name.isEmpty ? loc("doc.untitled") : name)
        case .encrypting(let name): return loc("progress.encrypting", name.isEmpty ? loc("doc.untitled") : name)
        case .splitting: return loc("progress.splitting")
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = doc.progress {
            ZStack {
                // Fondo opaco: oculta por completo lo que haya debajo.
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(progressLabel(progress.kind))
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
                               language: loc.language,
                               onExtract: { extract($0) },
                               onNeedPassword: { promptEntryPassword() })
        }
    }

    /// Barra intermedia: icono + nombre del archivo y acciones Cerrar / Guardar.
    private var documentBar: some View {
        HStack(spacing: 8) {
            Text(documentDisplayName)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if doc.saveEncryption != .none {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(loc("doc.encrypted.help"))
            }
            if doc.saveVolumeSize != nil {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
                    .help(loc("doc.volumes.help"))
            }
            if doc.hasUnsavedChanges {
                Text(loc("doc.unsaved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc("button.extractAll")) { extractAll() }
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button(loc("button.close")) { attemptClose() }
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button(loc("button.export")) { exportDocument() }
                .help(loc("button.export.help"))
            Button(loc("button.save")) { saveDocument() }
                .disabled(!doc.hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.top, 24)        // espacio arriba (bajo los semáforos)
        .padding(.bottom, 20)
        .padding(.leading, 100)   // libre la columna de semáforos + margen
        .padding(.trailing, 14)
        .background(.bar)
    }

    /// Tira **vertical** izquierda de acciones de interior (solo con archivo abierto).
    /// Icono + etiqueta para no perder descubribilidad.
    private var interiorBar: some View {
        VStack(spacing: 4) {
            interiorButton("toolbar.add", help: "toolbar.add.help",
                           icon: "plus", action: addAction)
            interiorButton("toolbar.newFolder", help: "toolbar.newFolder.help",
                           icon: "folder.badge.plus") {
                editGuarded { doc.createFolder(defaultName: loc("doc.newFolder")) }
            }
            interiorButton("toolbar.delete", help: "toolbar.delete.help",
                           icon: "trash", disabled: doc.selection == nil) {
                editGuarded { doc.removeSelected() }
            }
            interiorButton("toolbar.extract", help: "toolbar.extract.help",
                           icon: "square.and.arrow.up", disabled: doc.selection == nil,
                           action: extractAction)
            Spacer()
        }
        .padding(.top, 30)        // bajo la cabecera de la tabla
        .padding(.bottom, 10)
        .padding(.horizontal, 6)
        .frame(width: 78)
    }

    /// Un botón de la tira vertical: icono arriba, etiqueta pequeña debajo.
    private func interiorButton(_ title: String, help: String, icon: String,
                                disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17)).frame(height: 20)
                Text(loc(title))
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(loc(help))
    }

    private var dropPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text(loc("drop.title"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(loc("drop.subtitle"))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { addAction() }   // la zona de arrastre es también el punto de entrada (clic)
    }

    // MARK: - Barra superior


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
        panel.prompt = loc("panel.add")
        if panel.runModal() == .OK {
            handleOpen(panel.urls)
        }
    }

    /// Abre/añade lo seleccionado.
    private func handleOpen(_ urls: [URL]) {
        Task { await runAsync { try await doc.handleIncoming(urls) } }
    }

    private func extractAction() {
        guard let node = doc.selectedNode() else { return }
        extract(node)
    }

    /// Extrae un nodo concreto: abre el diálogo compacto de extracción.
    private func extract(_ node: FileNode) {
        prepareExtractDestination()
        extractRequest = ExtractRequest(name: node.name) { doc.exportPlan(for: node) }
    }

    /// Extrae **todo** el archivo a una carpeta con el nombre del archivo (como Finder).
    private func extractAll() {
        prepareExtractDestination()
        let name = strippedBaseName(documentDisplayName)
        extractRequest = ExtractRequest(name: name) { doc.exportPlanForAll(named: name) }
    }

    /// Fija el destino por defecto (carpeta del archivo o fija) y resetea la contraseña.
    private func prepareExtractDestination() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let archiveFolder = doc.sourceURL?.deletingLastPathComponent()
        switch settings.extractMode {
        case .archiveFolder:
            extractDestination = archiveFolder ?? settings.fixedExtractFolder ?? home
        case .fixedFolder:
            extractDestination = settings.fixedExtractFolder ?? archiveFolder ?? home
        }
        extractPassword = ""
        extractPasswordWrong = false
    }

    /// "Elegir…": abre el navegador de carpetas solo si se quiere cambiar el destino.
    private func chooseExtractFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = loc("panel.choose")
        panel.directoryURL = extractDestination
        if panel.runModal() == .OK, let url = panel.url {
            extractDestination = url
        }
    }

    /// Confirma la extracción (nodo o todo) al destino elegido.
    private func performExtract() {
        guard let req = extractRequest else { return }
        if doc.requiresEntryPassword {
            guard doc.provideEntryPassword(extractPassword) else {
                extractPasswordWrong = true
                extractPassword = ""
                return
            }
        }
        let destinationFolder = extractDestination
        extractRequest = nil

        let plan = req.makePlan()
        let destination = destinationFolder.appendingPathComponent(plan.name)
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
        // Re-guardar en el sitio solo si el formato es escribible (rar no lo es).
        if let url = doc.sourceURL, doc.saveFormat.isWritable {
            Task { await runAsync { try await doc.save(to: url) } }
        } else {
            optionsSheetIsExport = false
            prefillOptionsSheet()
            showingSaveOptions = true
        }
    }

    /// Exporta una copia aparte: siempre abre el diálogo de opciones (formato + cifrado +
    /// contraseña + volúmenes), prerrellenado con los ajustes actuales. **No** cambia el
    /// documento activo — sirve para cambiar contraseña/cifrado o convertir de formato.
    private func exportDocument() {
        if doc.requiresEntryPassword { promptEntryPassword(); return }
        optionsSheetIsExport = true
        prefillOptionsSheet()
        showingSaveOptions = true
    }

    /// Prerrellena la hoja de opciones con el formato/cifrado/volúmenes actuales
    /// (documento nuevo: defaults de Ajustes; abierto: lo que traía el archivo).
    private func prefillOptionsSheet() {
        let isNew = doc.sourceURL == nil
        var format = isNew ? settings.defaultFormat : doc.saveFormat
        if !format.isWritable { format = .zip }                            // rar → zip
        if format.isSingleFileOnly && !doc.isSingleFile { format = .zip }
        saveFormatChoice = format
        saveEncryptionChoice = isNew ? settings.defaultEncryption : doc.saveEncryption
        saveOptionsPassword = ""
        if let size = doc.saveVolumeSize {
            splitEnabled = true
            volumeUnit = .megabytes
            volumeSizeValue = max(1, (Double(size) / Double(VolumeUnit.megabytes.multiplier)).rounded())
        } else {
            splitEnabled = false
        }
    }

    /// Tras elegir opciones, pide ubicación y guarda o exporta con el formato/cifrado elegidos.
    private func confirmSaveOptions() {
        showingSaveOptions = false
        let isExport = optionsSheetIsExport
        let format = saveFormatChoice
        let encryption = format.supportsEncryption ? saveEncryptionChoice : .none
        let password = encryption == .none ? nil : saveOptionsPassword
        let volumeSize = (splitEnabled && format.supportsVolumeSplit && volumeSizeValue > 0)
            ? Int(volumeSizeValue * Double(volumeUnit.multiplier)) : nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .zip ? [.zip] : []
        panel.nameFieldStringValue = "\(strippedBaseName(documentDisplayName)).\(format.fileExtension)"
        panel.prompt = isExport ? loc("panel.export") : loc("panel.save")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await runAsync {
                if isExport {
                    try await doc.export(to: url, format: format, encryption: encryption,
                                         password: password, volumeSize: volumeSize)
                } else {
                    try await doc.save(to: url, format: format, encryption: encryption,
                                       password: password, volumeSize: volumeSize)
                }
            } }
        }
    }

    /// Nombre base sin la extensión de archivo conocida (zip/tar/tar.gz/tgz/gz).
    private func strippedBaseName(_ name: String) -> String {
        if name == loc("doc.untitled") { return name }
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tgz", ".tar", ".zip", ".gz"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return (name as NSString).deletingPathExtension
    }

    /// Cierra el documento; si hay cambios sin guardar, pide confirmación con el mismo
    /// aviso unificado que el cierre de ventana y el salir.
    private func attemptClose() {
        guard doc.hasUnsavedChanges else { doc.close(); return }
        UnsavedChangesAlert.present(on: NSApp.keyWindow) { discard in
            if discard { doc.close() }
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
        .environmentObject(Localizer.shared)
        .environmentObject(AppSettings.shared)
}
