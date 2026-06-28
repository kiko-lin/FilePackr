import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveBrowser

/// Gestor de archivos comprimidos: barra superior + barra de documento + cuerpo
/// central (zona de arrastre cuando está vacío, o el navegador `NSOutlineView`).
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @StateObject private var doc = ArchiveDocument()
    /// Máquinas de estado de las colas de añadir y extraer (cola + diálogo de conflicto).
    @StateObject private var addCoord = AddCoordinator()
    @StateObject private var extractCoord = ExtractCoordinator()
    /// Máquina de estado del flujo Guardar/Exportar (hoja de opciones + acción pendiente).
    @StateObject private var saveCoord = SaveCoordinator()
    @State private var errorMessage: String?
    @State private var showingEntryPassword = false
    /// Edición a ejecutar tras desbloquear (si se pidió contraseña al pulsarla).
    @State private var pendingEditAction: (() -> Void)?
    @State private var entryPasswordInput = ""
    @State private var entryPasswordWrong = false
    @State private var showingOpenPassword = false
    @State private var openPasswordInput = ""
    @State private var openPasswordWrong = false
    /// La app se lanzó abriendo un archivo desde el Finder: no es momento de ofrecer el
    /// diálogo de "compresor por defecto".
    @State private var openingExternalFile = false
    /// Aviso discreto en la barra de estado (p. ej. "Se excluyeron N archivos de sistema"),
    /// con un token para que un auto-descarte antiguo no borre un aviso más reciente.
    @State private var exclusionNotice: String?
    @State private var exclusionNoticeToken = 0

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
                                extracting: doc.extractionCancellable,
                                onSave: { proceed in saveDocument(then: proceed) },
                                onCancelExtraction: { cancelExtraction() }))
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
            Button(loc("conflict.keepBoth")) {
                extractCoord.resolveConflict(item, overwrite: false, doc: doc, perform: runExtraction)
            }
            Button(loc("button.cancel"), role: .cancel) { extractCoord.cancelConflict() }
        } message: { item in
            Text(loc("conflict.message", item.destination.lastPathComponent))
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
        .sheet(isPresented: $saveCoord.showingOptions) {
            SaveOptionsSheet(coord: saveCoord,
                             allowSingleFileFormats: doc.isSingleFile,
                             title: saveOptionsTitle,
                             confirmLabel: saveCoord.isExport ? loc("button.export") : loc("button.saveEllipsis"),
                             onChooseFolder: { saveCoord.chooseFolder(prompt: loc("panel.choose")) },
                             onConfirm: { saveCoord.confirm(perform: runSave) },
                             onCancel: { saveCoord.cancel() })
        }
        .sheet(isPresented: $showingEntryPassword, onDismiss: { runAfterUnlock() }) {
            PasswordSheet(title: loc("password.entryTitle"),
                          confirmLabel: loc("password.continue"),
                          password: $entryPasswordInput,
                          note: entryPasswordWrong ? loc("password.wrong") : nil,
                          onConfirm: { confirmEntryPassword() },
                          onCancel: { pendingEditAction = nil; showingEntryPassword = false })
        }
        .sheet(item: $extractCoord.request) { req in
            ExtractOptionsSheet(title: req.title,
                                destination: $extractCoord.destination,
                                onChooseFolder: { extractCoord.chooseFolder(prompt: loc("panel.choose")) },
                                onExtract: { extractCoord.confirm(doc: doc, settings: settings, perform: runExtraction) },
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
        .onOpenURL { url in
            openingExternalFile = true
            handleOpen([url])
        }
        .onAppear { promptDefaultCompressorIfNeeded() }
        .onDisappear {
            // Al cerrar la ventana, no dejar la descompresión corriendo de fondo.
            doc.cancelExtraction()
            extractCoord.cancelBatch()
        }
    }

    /// Primer arranque: ofrece (una sola vez) hacer de FilePackr el compresor por defecto.
    /// Si el usuario acepta, abre Ajustes en la pestaña Archivos para elegir formatos.
    private func promptDefaultCompressorIfNeeded() {
        guard !settings.firstRunPromptShown else { return }

        // `onAppear` se dispara antes de que la ventana sea key; un salto al siguiente turno
        // del run loop garantiza que la hoja se adjunte a una ventana ya visible (y deja que
        // `onOpenURL` marque si la app se abrió por un archivo, en cuyo caso no preguntamos).
        DispatchQueue.main.async {
            guard !openingExternalFile else { return }
            settings.firstRunPromptShown = true

            let alert = NSAlert()
            alert.messageText = loc("firstrun.title")
            alert.informativeText = loc("firstrun.message")
            alert.alertStyle = .informational
            alert.addButton(withTitle: loc("firstrun.yes"))     // 1º → por defecto (Intro)
            let later = alert.addButton(withTitle: loc("firstrun.later"))
            later.keyEquivalent = "\u{1b}"                       // Escape pospone

            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { openFilesSettings() } }
            } else if alert.runModal() == .alertFirstButtonReturn {
                openFilesSettings()
            }
        }
    }

    /// Abre la ventana de Ajustes de la app en la pestaña Archivos. Usa la acción oficial
    /// `openSettings` del entorno (fiable, a diferencia del selector privado que podía abrir
    /// los Ajustes del Sistema). El salto de run loop deja cerrarse antes la hoja.
    private func openFilesSettings() {
        settings.selectedSettingsTab = .files
        DispatchQueue.main.async { openSettings() }
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
            // Solo cerrar la hoja. La acción pendiente se ejecuta en `onDismiss`, ya cerrada la
            // hoja, para no presentar el panel/hoja siguiente sobre una que aún se está cerrando.
            showingEntryPassword = false
        } else {
            entryPasswordWrong = true
            entryPasswordInput = ""
        }
    }

    /// Ejecuta la acción que esperaba al desbloqueo (extraer/exportar/editar), una vez la hoja
    /// de contraseña está completamente cerrada. Nil si se canceló o no había acción.
    private func runAfterUnlock() {
        let action = pendingEditAction
        pendingEditAction = nil
        action?()
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

    /// Título del diálogo de Guardar/Exportar según el contexto: exportar a otro formato,
    /// guardar un documento nuevo, o guardar los cambios de uno existente.
    private var saveOptionsTitle: String {
        if saveCoord.isExport { return loc("export.title") }
        return doc.sourceURL == nil ? loc("save.title") : loc("save.title.changes")
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
                // Atenúa la app de fondo (sigue viéndose, sin taparla por completo).
                Color.black.opacity(0.4).ignoresSafeArea()
                // Tarjeta flotante compacta centrada con el progreso.
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text(progressLabel(progress.kind))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        // Reservamos siempre la línea del nombre (aunque esté vacía) para que la
                        // caja no se agrande al aparecer el nombre del fichero.
                        Text(progress.detail ?? " ")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240)
                    }
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 240)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    // Botón "Cancelar" rojo con borde (destructivo), solo en extracción cancelable.
                    if doc.extractionCancellable {
                        Button(loc("button.cancel"), role: .destructive, action: cancelExtraction)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 28)
                .frame(width: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
            }
        }
    }

    /// Cancela la extracción en curso y vacía la cola pendiente del lote.
    private func cancelExtraction() {
        doc.cancelExtraction()
        extractCoord.cancelBatch()
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
            if let notice = exclusionNotice {
                Label(notice, systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: exclusionNotice)
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

    /// Ejecuta una acción que necesita el archivo desbloqueado (editar, extraer, exportar). Si
    /// está cifrado y bloqueado, pide la contraseña y, **al desbloquear**, ejecuta la acción (no
    /// la descarta); si ya está desbloqueado, la ejecuta de inmediato.
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
            addCoord.start(urls, into: doc.addTargetFolder(), doc: doc,
                           hiddenPolicy: settings.addHiddenPolicy,
                           onFinish: { noteExcluded($0) })
        }
    }

    /// Añade ficheros arrastrados del Finder a una carpeta concreta. Si el archivo está
    /// cifrado y bloqueado, pide la contraseña y los añade tras desbloquear.
    private func addDropped(_ urls: [URL], into folder: FileNode?) {
        editGuarded {
            addCoord.start(urls, into: folder, doc: doc,
                           hiddenPolicy: settings.addHiddenPolicy,
                           onFinish: { noteExcluded($0) })
        }
    }

    /// Muestra el aviso discreto de elementos omitidos por la política de ocultos/sistema y
    /// lo retira solo tras unos segundos (el token evita que un descarte previo borre uno nuevo).
    private func noteExcluded(_ count: Int) {
        guard count > 0 else { return }
        exclusionNoticeToken += 1
        let token = exclusionNoticeToken
        let key = count == 1 ? "status.excluded.one" : "status.excluded.many"
        exclusionNotice = loc(key, count)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if exclusionNoticeToken == token { exclusionNotice = nil }
        }
    }

    private func extractAction() {
        let nodes = doc.selectedNodes()
        guard !nodes.isEmpty else { return }
        if nodes.count == 1 { extract(nodes[0]) } else { extractNodes(nodes) }
    }

    /// Extrae un nodo concreto: abre el diálogo compacto de extracción (desbloqueando antes
    /// si hace falta, para poder leer las entradas cifradas).
    private func extract(_ node: FileNode) {
        editGuarded {
            extractCoord.prepareDestination(doc: doc, settings: settings)
            extractCoord.begin(title: loc("extract.title.one")) { [doc.exportPlan(for: node)] }
        }
    }

    /// Extrae varios nodos seleccionados: cada uno se coloca en la carpeta destino.
    private func extractNodes(_ nodes: [FileNode]) {
        editGuarded {
            extractCoord.prepareDestination(doc: doc, settings: settings)
            extractCoord.begin(title: loc("extract.title.many")) {
                nodes.map { doc.exportPlan(for: $0) }
            }
        }
    }

    /// Extrae **todo** el archivo a una carpeta con el nombre del archivo (como Finder).
    private func extractAll() {
        editGuarded {
            extractCoord.prepareDestination(doc: doc, settings: settings)
            let name = strippedBaseName(documentDisplayName)
            extractCoord.begin(title: loc("extract.title.all")) { [doc.exportPlanForAll(named: name)] }
        }
    }

    /// Ejecuta la extracción de un plan (la inyecta el coordinador); canaliza el error a la
    /// alerta de la vista.
    private func runExtraction(_ plan: ExportPlan, to destination: URL, overwrite: Bool) async {
        await runAsync { try await doc.performExtraction(of: plan, to: destination, overwrite: overwrite) }
    }

    /// Guarda: si ya tiene fichero escribible, re-guarda con los ajustes; si no, abre la hoja
    /// propia de opciones. `completion` se ejecuta solo tras un guardado con éxito (lo usa
    /// "Guardar" del aviso de cambios sin guardar).
    private func saveDocument(then completion: (() -> Void)? = nil) {
        // Si está cifrado y bloqueado, pide la clave y **reanuda** el guardado al desbloquear
        // (necesita la clave para leer las entradas cifradas); no descartar la acción.
        editGuarded {
            // Re-guardar en el sitio solo si el formato es escribible (rar no lo es).
            if let url = doc.sourceURL, doc.saveFormat.isWritable {
                Task {
                    await runAsync { try await doc.save(to: url) }
                    if !doc.hasUnsavedChanges { completion?() }
                }
            } else {
                saveCoord.prefill(doc: doc, settings: settings, baseName: strippedBaseName(documentDisplayName))
                saveCoord.beginSave(then: completion)
            }
        }
    }

    /// Exporta una copia aparte: abre la hoja propia de opciones (formato/cifrado/contraseña/
    /// volúmenes + nombre/carpeta). **No** cambia el documento activo — sirve para cambiar
    /// contraseña/cifrado o convertir de formato. Si está bloqueado, pide la clave y reanuda.
    private func exportDocument() {
        editGuarded {
            saveCoord.prefill(doc: doc, settings: settings, baseName: strippedBaseName(documentDisplayName))
            saveCoord.beginExport()
        }
    }

    /// Escribe el guardado/exportación a la `url` resuelta por la hoja, con las opciones
    /// elegidas. La inyecta `saveCoord.confirm`; devuelve `true` si el documento quedó guardado.
    private func runSave(isExport: Bool, url: URL, format: ArchiveFormat, encryption: ZipEncryption,
                         password: String?, volumeSize: Int?, level: CompressionLevel) async -> Bool {
        await runAsync {
            if isExport {
                try await doc.export(to: url, format: format, encryption: encryption,
                                     password: password, volumeSize: volumeSize, level: level)
            } else {
                try await doc.save(to: url, format: format, encryption: encryption,
                                   password: password, volumeSize: volumeSize, level: level)
            }
        }
        return !doc.hasUnsavedChanges
    }

    /// Nombre base sin la extensión de archivo conocida (zip/tar/tar.gz/tgz/gz).
    private func strippedBaseName(_ name: String) -> String {
        name == loc("doc.untitled") ? name : archiveBaseName(name)
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
        do { try op() } catch { errorMessage = localizedErrorMessage(error) }
    }

    private func runAsync(_ op: () async throws -> Void) async {
        do { try await op() }
        catch is CancellationError { /* cancelado por el usuario: parada limpia, sin alerta */ }
        catch { errorMessage = localizedErrorMessage(error) }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
}
