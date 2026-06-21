import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser

/// Gestor de archivos comprimidos: barra superior + barra de documento + cuerpo
/// central (zona de arrastre cuando está vacío, o el navegador `NSOutlineView`).
struct ContentView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var doc = ArchiveDocument()
    /// Máquinas de estado de las colas de añadir y extraer (cola + diálogo de conflicto).
    @StateObject private var addCoord = AddCoordinator()
    @StateObject private var extractCoord = ExtractCoordinator()
    @State private var errorMessage: String?
    @State private var showingSaveOptions = false
    /// La hoja de opciones está abierta para **Exportar** (copia aparte) en vez de Guardar.
    @State private var optionsSheetIsExport = false
    /// Acción a ejecutar tras un guardado con éxito (p. ej. cerrar al elegir "Guardar"
    /// en el aviso de cambios sin guardar). Se descarta si se cancela el guardado.
    @State private var pendingAfterSave: (() -> Void)?
    @State private var saveFormatChoice: ArchiveFormat = .zip
    @State private var saveEncryptionChoice: ZipEncryption = .none
    @State private var saveOptionsPassword = ""
    @State private var splitEnabled = false
    @State private var volumeSizeValue: Double = 100
    @State private var volumeUnit: VolumeUnit = .megabytes
    @State private var showingEntryPassword = false
    /// Edición a ejecutar tras desbloquear (si se pidió contraseña al pulsarla).
    @State private var pendingEditAction: (() -> Void)?
    @State private var entryPasswordInput = ""
    @State private var entryPasswordWrong = false
    @State private var showingOpenPassword = false
    @State private var openPasswordInput = ""
    @State private var openPasswordWrong = false

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
                Divider()
                statusBar            // recuento + peso del contenido
            }
        }
        .ignoresSafeArea(.container, edges: .top)   // el contenido sube a la zona del título
        .preferredColorScheme(settings.theme.colorScheme)
        .background(WindowGuard(edited: doc.hasUnsavedChanges,
                                onSave: { proceed in saveDocument(then: proceed) }))
        .alert(loc("error.title"),
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button(loc("button.ok")) {}
        } message: { Text($0) }
        .confirmationDialog(
            extractCoord.conflict.map { loc("conflict.title", $0.destination.lastPathComponent) } ?? "",
            isPresented: Binding(get: { extractCoord.conflict != nil },
                                 set: { if !$0 { extractCoord.conflict = nil } }),
            presenting: extractCoord.conflict
        ) { item in
            Button(loc("conflict.overwrite"), role: .destructive) {
                extractCoord.resolveConflict(item, overwrite: true, doc: doc, perform: runExtraction)
            }
            Button(loc("conflict.saveAs", item.alternative.lastPathComponent)) {
                extractCoord.resolveConflict(item, overwrite: false, doc: doc, perform: runExtraction)
            }
            Button(loc("button.cancel"), role: .cancel) { extractCoord.cancelConflict() }
        }
        .confirmationDialog(
            addCoord.conflict.map { loc("add.conflict.title", $0.name) } ?? "",
            isPresented: Binding(get: { addCoord.conflict != nil },
                                 set: { if !$0 { addCoord.conflict = nil } }),
            presenting: addCoord.conflict
        ) { item in
            Button(loc("add.conflict.overwrite"), role: .destructive) {
                addCoord.overwrite(item, doc: doc)
            }
            Button(loc("add.conflict.keepBoth")) {
                addCoord.keepBoth(item, doc: doc)
            }
            Button(loc("button.cancel"), role: .cancel) {
                addCoord.cancel(doc: doc)
            }
        } message: { item in
            Text(loc("add.conflict.message", item.name))
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
                             onCancel: { showingSaveOptions = false; pendingAfterSave = nil })
        }
        .sheet(isPresented: $showingEntryPassword) {
            PasswordSheet(title: loc("password.entryTitle"),
                          confirmLabel: loc("password.open"),
                          password: $entryPasswordInput,
                          note: entryPasswordWrong ? loc("password.wrong") : nil,
                          onConfirm: { confirmEntryPassword() },
                          onCancel: { showingEntryPassword = false; pendingEditAction = nil })
        }
        .sheet(item: $extractCoord.request) { req in
            ExtractOptionsSheet(nodeName: req.name,
                                needsPassword: doc.requiresEntryPassword,
                                destination: $extractCoord.destination,
                                password: $extractCoord.password,
                                passwordWrong: extractCoord.passwordWrong,
                                onChooseFolder: { extractCoord.chooseFolder(prompt: loc("panel.choose")) },
                                onExtract: { extractCoord.confirm(doc: doc, perform: runExtraction) },
                                onCancel: { extractCoord.request = nil })
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
            if requires { pendingEditAction = nil; promptEntryPassword() }
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
            let action = pendingEditAction      // ya desbloqueado: ejecutar lo pendiente
            pendingEditAction = nil
            action?()
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
                               onNeedPassword: { promptEntryPassword() },
                               onAddFiles: { urls, folder in addDropped(urls, into: folder) })
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
        .padding(.leading, 90)    // libre la columna de semáforos + margen
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
                           icon: "trash", disabled: doc.selectedIDs.isEmpty) {
                editGuarded { doc.removeSelected() }
            }
            interiorButton("toolbar.extract", help: "toolbar.extract.help",
                           icon: "square.and.arrow.up", disabled: doc.selectedIDs.isEmpty,
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

    /// Barra de estado inferior: nº de ficheros y peso total (estilo Finder).
    private var statusBar: some View {
        HStack {
            Spacer()
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var statusText: String {
        let count = doc.contentFileCount
        let word = count == 1 ? loc("status.file") : loc("status.files")
        let size = ByteCountFormatter.string(fromByteCount: Int64(doc.contentSize), countStyle: .file)
        var text = "\(count) \(word) · \(size)"
        // El tamaño comprimido solo se muestra cuando se conoce para todo el contenido
        // y hay compresión real: si no (ficheros sin comprimir, o un .tar que almacena
        // sin comprimir → comprimido == tamaño), la cifra sería engañosa o redundante.
        if doc.contentCompressedKnown && doc.contentCompressedSize < doc.contentSize {
            let packed = ByteCountFormatter.string(fromByteCount: Int64(doc.contentCompressedSize), countStyle: .file)
            text += " · \(packed) \(loc("status.compressed"))"
            if doc.contentSize > 0 {
                let ratio = Int((Double(doc.contentCompressedSize) / Double(doc.contentSize) * 100).rounded())
                text += " (\(ratio) %)"
            }
        }
        return text
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

    // MARK: - Acciones con paneles del sistema

    /// Ejecuta una edición; si el archivo está cifrado y bloqueado, pide la contraseña y,
    /// al desbloquear, ejecuta la acción (en vez de descartarla).
    private func editGuarded(_ action: @escaping () -> Void) {
        if doc.isLocked {
            pendingEditAction = action
            promptEntryPassword()
        } else {
            action()
        }
    }

    private func addAction() {
        editGuarded {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = loc("panel.add")
            if panel.runModal() == .OK {
                handleOpen(panel.urls)
            }
        }
    }

    /// Abre/añade lo seleccionado: un único archivo abrible (con el documento vacío) se abre
    /// como base; el resto se añade a la carpeta destino resolviendo conflictos de nombre.
    private func handleOpen(_ urls: [URL]) {
        if let archive = doc.archiveToOpen(from: urls) {
            Task { await runAsync { try await doc.openArchive(archive) } }
        } else {
            addCoord.start(urls, into: doc.addTargetFolder(), doc: doc)
        }
    }

    /// Añade ficheros arrastrados del Finder a una carpeta concreta. Si el archivo está
    /// cifrado y bloqueado, pide la contraseña y los añade tras desbloquear.
    private func addDropped(_ urls: [URL], into folder: FileNode?) {
        editGuarded { addCoord.start(urls, into: folder, doc: doc) }
    }

    private func extractAction() {
        let nodes = doc.selectedNodes()
        guard !nodes.isEmpty else { return }
        if nodes.count == 1 { extract(nodes[0]) } else { extractNodes(nodes) }
    }

    /// Extrae un nodo concreto: abre el diálogo compacto de extracción.
    private func extract(_ node: FileNode) {
        extractCoord.prepareDestination(doc: doc, settings: settings)
        extractCoord.begin(name: node.name) { [doc.exportPlan(for: node)] }
    }

    /// Extrae varios nodos seleccionados: cada uno se coloca en la carpeta destino.
    private func extractNodes(_ nodes: [FileNode]) {
        extractCoord.prepareDestination(doc: doc, settings: settings)
        extractCoord.begin(name: loc("extract.items", String(nodes.count))) {
            nodes.map { doc.exportPlan(for: $0) }
        }
    }

    /// Extrae **todo** el archivo a una carpeta con el nombre del archivo (como Finder).
    private func extractAll() {
        extractCoord.prepareDestination(doc: doc, settings: settings)
        let name = strippedBaseName(documentDisplayName)
        extractCoord.begin(name: name) { [doc.exportPlanForAll(named: name)] }
    }

    /// Ejecuta la extracción de un plan (la inyecta el coordinador); canaliza el error a la
    /// alerta de la vista.
    private func runExtraction(_ plan: ExportPlan, to destination: URL, overwrite: Bool) async {
        await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: overwrite) }
    }

    /// Guarda: si ya tiene fichero, re-guarda con los ajustes; si es nuevo, abre el
    /// diálogo de opciones (formato + cifrado + contraseña). `completion` se ejecuta solo
    /// tras un guardado con éxito (lo usa "Guardar" del aviso de cambios sin guardar).
    private func saveDocument(then completion: (() -> Void)? = nil) {
        if doc.requiresEntryPassword { promptEntryPassword(); return }
        // Re-guardar en el sitio solo si el formato es escribible (rar no lo es).
        if let url = doc.sourceURL, doc.saveFormat.isWritable {
            Task {
                await runAsync { try await doc.save(to: url) }
                if !doc.hasUnsavedChanges { completion?() }
            }
        } else {
            pendingAfterSave = completion
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
            Task {
                await runAsync {
                    if isExport {
                        try await doc.export(to: url, format: format, encryption: encryption,
                                             password: password, volumeSize: volumeSize)
                    } else {
                        try await doc.save(to: url, format: format, encryption: encryption,
                                           password: password, volumeSize: volumeSize)
                    }
                }
                // Tras guardar (no exportar) con éxito, ejecutar lo pendiente (p. ej. cerrar).
                if !isExport, !doc.hasUnsavedChanges {
                    let after = pendingAfterSave
                    pendingAfterSave = nil
                    after?()
                }
            }
        } else {
            pendingAfterSave = nil   // se canceló la ubicación: no continuar
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
        UnsavedChangesAlert.present(on: NSApp.keyWindow) { choice in
            switch choice {
            case .cancel: break
            case .discard: doc.close()
            case .save: saveDocument(then: { doc.close() })
            }
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
