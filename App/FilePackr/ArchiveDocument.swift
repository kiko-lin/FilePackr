import Foundation
import Combine
import UniformTypeIdentifiers
import ArchiveBrowser

/// Estado de cifrado de un documento. Un único valor hace imposible representar estados
/// contradictorios (p. ej. pedir a la vez contraseña de apertura y de entrada).
enum LockState: Equatable {
    /// Sin cifrado pendiente: el documento es editable/extraíble.
    case unlocked
    /// Un 7z con cabeceras cifradas necesita contraseña para **abrirse**; `url` es el archivo
    /// pendiente de reintentar al darla.
    case needsOpenPassword(URL)
    /// El archivo está abierto pero sus **entradas** están cifradas y aún no hay contraseña.
    case needsEntryPassword
}

/// Documento de trabajo: el árbol de elementos que acabará siendo un ZIP.
/// Mantiene, si se abrió un ZIP existente, sus bytes originales para poder
/// extraer o copiar entradas sin recomprimir.
@MainActor
final class ArchiveDocument: ObservableObject {

    @Published var roots: [FileNode] = []
    /// Selección actual (varios elementos): para arrastrar, extraer o eliminar en lote.
    @Published var selectedIDs: Set<FileNode.ID> = []

    /// Nombre mostrado en la barra de documento (fichero abierto o "Sin título").
    @Published private(set) var documentName: String = ""
    /// Hay modificaciones sin guardar desde la última apertura/guardado.
    @Published private(set) var hasUnsavedChanges: Bool = false
    /// Fichero de origen, si se abrió/guardó uno (para "Guardar" sin volver a preguntar).
    @Published private(set) var sourceURL: URL?
    /// Se incrementa con cada cambio estructural (no al seleccionar). La vista de
    /// lista lo usa para recargar solo cuando hace falta.
    @Published private(set) var revision = 0
    /// Operación larga en curso (comprimir/extraer): muestra la barra de progreso.
    @Published var progress: ProgressState?
    /// Cifrado elegido al guardar (se recuerda para el botón Guardar).
    @Published private(set) var saveEncryption: ZipEncryption = .none
    private var savePassword: String?
    /// Formato del contenedor abierto (para leer las entradas de los nodos).
    @Published private(set) var format: ArchiveFormat = .zip
    /// Formato por defecto del diálogo Guardar (se recuerda tras guardar).
    @Published private(set) var saveFormat: ArchiveFormat = .zip
    /// Tamaño de volumen en bytes si el documento se guarda dividido (nil = un fichero).
    @Published private(set) var saveVolumeSize: Int?
    /// Nivel de compresión elegido al guardar (se recuerda para el botón Guardar).
    @Published private(set) var saveLevel: CompressionLevel = .default
    /// Estado de cifrado del documento (única fuente de verdad: estados imposibles de
    /// contradecir). La vista observa los derivados `requiresEntryPassword`/`requiresOpenPassword`.
    @Published private(set) var lockState: LockState = .unlocked
    /// Necesitamos la contraseña de las **entradas** cifradas del archivo abierto (para
    /// extraer/editar). Derivado de `lockState`.
    var requiresEntryPassword: Bool { lockState == .needsEntryPassword }
    /// Un 7z con cabeceras cifradas necesita contraseña para **abrirse** (no solo extraer).
    /// Derivado de `lockState`.
    var requiresOpenPassword: Bool { if case .needsOpenPassword = lockState { return true }; return false }
    /// Contraseña para descifrar las entradas del archivo abierto.
    private var entryPassword: String?

    private(set) var sourceArchiveData: Data?

    /// Temporal con las partes de un multivolumen concatenadas, mapeado en
    /// `sourceArchiveData`. Se borra al cerrar o al abrir otro archivo.
    private var joinedVolumesTemp: URL?

    /// Hay un documento activo (abierto o nuevo empezado). Sentinela para no reiniciar
    /// el estado al añadir/crear sobre un documento ya en marcha.
    private var hasActiveDocument = false

    var isEmpty: Bool { roots.isEmpty }

    // MARK: - Entrada de elementos (arrastre o botón Añadir)

    /// Si lo que llega es un único archivo abrible con el documento vacío, devuelve su URL
    /// (para abrirlo como base); si no, `nil` (hay que añadirlo al documento actual). La vista
    /// usa esto para decidir y, en el caso de añadir, resolver conflictos de nombre.
    func archiveToOpen(from urls: [URL]) -> URL? {
        let cleaned = urls.filter { $0.isFileURL }
        guard isEmpty, cleaned.count == 1,
              !isDirectory(cleaned[0]), isOpenableArchive(cleaned[0]) else { return nil }
        return cleaned[0]
    }

    /// Carpeta destino para Añadir (según la selección), expuesta para que la vista detecte
    /// conflictos de nombre antes de insertar.
    func addTargetFolder() -> FileNode? { destinationFolderForAdding() }

    /// Hijo existente con ese nombre dentro de `target` (o en la raíz), si lo hay.
    func child(named name: String, in target: FileNode?) -> FileNode? {
        (target?.children ?? roots).first { $0.name == name }
    }

    /// Nombre de fichero libre dentro de `target` («nombre 2.ext», «nombre 3.ext»…),
    /// conservando la extensión.
    func uniqueChildName(_ name: String, in target: FileNode?) -> String {
        let taken = Set((target?.children ?? roots).map(\.name))
        guard taken.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Añade un único fichero/carpeta del disco dentro de `target` y devuelve el nodo creado.
    /// `replacing` elimina antes el elemento existente (sobrescribir); `renameTo` fuerza un
    /// nombre libre (conservar ambos). No toca la selección: la fija la vista al acabar el lote.
    /// Devuelve el nodo añadido y cuántos elementos omitió la política al expandir las carpetas.
    @discardableResult
    func addFile(_ url: URL, into target: FileNode?, replacing existing: FileNode? = nil,
                 renameTo newName: String? = nil,
                 hiddenPolicy: AddHiddenPolicy = .excludeSystemFiles) -> (node: FileNode?, excluded: Int) {
        guard !isLocked else { return (nil, 0) }
        if !hasActiveDocument { beginNewDocument() }
        if let existing { remove(existing) }
        let imported = importFromDisk(url, hiddenPolicy: hiddenPolicy)
        if let newName { imported.node.name = newName }
        insert(imported.node, into: target)
        markChanged()
        return (imported.node, imported.excluded)
    }

    /// Abre un ZIP existente y muestra su contenido (sin descomprimirlo). La lectura
    /// y el parseo del índice van en segundo plano para no bloquear la interfaz.
    func openArchive(_ url: URL, passphrase: String? = nil) async throws {
        // Si forma parte de un juego de volúmenes, reunimos las partes en orden;
        // la primera (nombre.zip) da el nombre base y el formato.
        let parts = VolumeStore.parts(for: url)
        let baseURL = parts.first ?? url
        // Por extensión y, si no la reconoce, por la firma (magic bytes) de la cabecera.
        let detected = ArchiveFormat.detectByExtension(baseURL)
            ?? peekHeader(baseURL).flatMap(ArchiveFormat.detectByMagic)
            ?? .zip
        progress = ProgressState(kind: .opening(baseURL.lastPathComponent),
                                 fraction: detected == .zip ? 0 : nil)
        defer { progress = nil }

        // Si venía troceado, limpiamos cualquier temporal de una apertura anterior.
        discardJoinedVolumesTemp()
        let fallbackName = baseURL.deletingPathExtension().lastPathComponent
        let report = makeProgressReporter()
        let result: ArchiveReadResult
        let joinedTemp: URL?
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (ArchiveReadResult, URL?) in
                // Multivolumen: concatenar las partes a un temporal y **mapearlo**, en vez
                // de cargar todas las partes en RAM (Volumes.join). Mono-volumen: mapear directo.
                let temp = parts.count == 1 ? nil : try VolumeStore.joinToTemporaryFile(parts)
                let data = try Data(contentsOf: temp ?? parts[0], options: .mappedIfSafe)
                // Solo ZIP reporta progreso por fracción; limitamos los saltos a la UI
                // (cada ~1%) para no inundar el hilo principal.
                var lastReported = 0.0
                let progress: ((Double) -> Void)? = detected == .zip ? { fraction in
                    if fraction - lastReported >= 0.01 || fraction >= 1 {
                        lastReported = fraction
                        report(fraction)
                    }
                } : nil
                do {
                    let r = try detected.codec.open(data, fallbackName: fallbackName,
                                                    passphrase: passphrase, progress: progress)
                    return (r, temp)
                } catch {
                    if let temp { try? FileManager.default.removeItem(at: temp) }
                    throw error
                }
            }.value
            result = loaded.0
            joinedTemp = loaded.1
        } catch let error as LibArchiveError where error == .passphraseRequired {
            // 7z con cabeceras cifradas: hay que pedir contraseña para abrir.
            lockState = .needsOpenPassword(url)
            return
        }

        joinedVolumesTemp = joinedTemp
        format = result.format
        sourceArchiveData = result.container
        roots = buildTree(from: result.entries)
        selectedIDs = []
        sourceURL = baseURL
        documentName = baseURL.lastPathComponent
        hasActiveDocument = true
        entryPassword = passphrase
        // ZIP y 7z pueden tener entradas cifradas; si no dimos contraseña al abrir,
        // se pedirá al extraer/previsualizar. tar/gz/xz/bz2 nunca cifran.
        let entriesLocked = passphrase == nil
            && (result.format == .zip || result.format.usesLibArchive)
            && result.entries.contains { $0.isEncrypted }
        lockState = entriesLocked ? .needsEntryPassword : .unlocked
        // Al re-guardar, conservar el cifrado original (con su contraseña, cuando se dé).
        saveEncryption = result.format == .zip ? detectedEncryption(in: result.entries) : .none
        savePassword = nil
        saveFormat = result.format
        // Si venía en volúmenes, recordar el tamaño (el de la primera parte) para re-guardar igual.
        if parts.count > 1, let size = try? parts[0].resourceValues(forKeys: [.fileSizeKey]).fileSize {
            saveVolumeSize = size
        } else {
            saveVolumeSize = nil
        }
        hasUnsavedChanges = false
        changed()
    }

    /// Tipo de cifrado de las entradas (para conservarlo al re-guardar).
    private func detectedEncryption(in entries: [ArchiveEntry]) -> ZipEncryption {
        if entries.contains(where: { $0.isAESEncrypted }) { return .aes256 }
        if entries.contains(where: { $0.isEncrypted }) { return .zipCrypto }
        return .none
    }

    /// Da la contraseña para las entradas cifradas del archivo abierto. La valida
    /// extrayendo la primera entrada cifrada; devuelve `false` si es incorrecta.
    func provideEntryPassword(_ password: String) -> Bool {
        // Si hay una entrada cifrada, validar la contraseña extrayéndola; si no la hay,
        // aceptarla sin más. En ambos casos se aplican los mismos efectos (una sola vez).
        if let archive = sourceArchiveData,
           let node = firstEncryptedFile(in: roots),
           case .entry(let entry) = node.source {
            do {
                _ = try format.codec.entryData(for: entry, in: archive, password: password)
            } catch {
                return false
            }
        }
        entryPassword = password
        savePassword = password   // misma contraseña para re-guardar cifrado
        lockState = .unlocked
        changed()
        return true
    }

    /// Da la contraseña para **abrir** un 7z con cabeceras cifradas. Reintenta la
    /// apertura; devuelve `false` si es incorrecta (sigue pidiéndola).
    func provideOpenPassword(_ password: String) async -> Bool {
        guard case .needsOpenPassword(let url) = lockState else { return false }
        do {
            try await openArchive(url, passphrase: password)
            return !requiresOpenPassword   // openArchive la limpia si funcionó
        } catch {
            return false   // contraseña incorrecta
        }
    }

    private func firstEncryptedFile(in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.isDirectory {
                if let found = firstEncryptedFile(in: node.children) { return found }
            } else if case .entry(let entry) = node.source, entry.isEncrypted {
                return node
            }
        }
        return nil
    }

    /// Empieza un documento nuevo, aún sin guardar. El nombre mostrado ("Sin título")
    /// lo resuelve la vista; el modelo deja `documentName` vacío hasta que se guarde.
    func beginNewDocument() {
        sourceURL = nil
        documentName = ""
        hasActiveDocument = true
        hasUnsavedChanges = false
        entryPassword = nil
        lockState = .unlocked
        saveEncryption = .none
        savePassword = nil
        format = .zip
        saveFormat = .zip
        saveVolumeSize = nil
    }

    /// Añade ficheros/carpetas del disco dentro de la carpeta destino actual.
    func addFiles(_ urls: [URL]) {
        addFiles(urls, into: destinationFolderForAdding())
    }

    /// Añade ficheros/carpetas del disco dentro de `target` (o la raíz si es `nil`).
    /// Deja seleccionados los elementos añadidos para que la vista los revele
    /// (desplegando la carpeta destino) y les dé el foco, como al crear una carpeta.
    @discardableResult
    func addFiles(_ urls: [URL], into target: FileNode?,
                  hiddenPolicy: AddHiddenPolicy = .excludeSystemFiles) -> [FileNode] {
        guard !isLocked else { return [] }
        if !hasActiveDocument { beginNewDocument() }
        var added: [FileNode] = []
        for url in urls {
            let node = importFromDisk(url, hiddenPolicy: hiddenPolicy).node
            insert(node, into: target)
            added.append(node)
        }
        if !added.isEmpty { selectedIDs = Set(added.map(\.id)) }
        markChanged()
        return added
    }

    // MARK: - Acciones de la barra superior

    /// El archivo está cifrado y bloqueado (sin contraseña): no se puede editar.
    var isLocked: Bool { requiresEntryPassword }

    /// Crea una carpeta. El nombre por defecto ("Nueva carpeta") lo inyecta la vista,
    /// ya localizado, para que el modelo no dependa de la i18n.
    func createFolder(defaultName: String) {
        guard !isLocked else { return }
        if !hasActiveDocument { beginNewDocument() }
        let parent = folderForNewFolder()
        let siblings = parent?.children ?? roots
        let name = uniqueName(defaultName, among: siblings)
        let node = FileNode(name: name, isDirectory: true, source: .folder)
        insert(node, into: parent)
        selectedIDs = [node.id]
        markChanged()
    }

    /// Elimina todos los elementos seleccionados (borrado en lote).
    func removeSelected() {
        guard !isLocked else { return }
        let nodes = selectedNodes()
        guard !nodes.isEmpty else { return }
        for node in nodes { remove(node) }
        selectedIDs = []
        markChanged()
    }

    /// Elimina un nodo concreto (el del menú contextual, por ejemplo).
    func delete(_ node: FileNode) {
        guard !isLocked else { return }
        remove(node)
        selectedIDs.remove(node.id)
        markChanged()
    }

    /// Renombra un nodo. Ignora si el nombre está vacío o ya existe entre hermanos.
    func rename(_ node: FileNode, to newName: String) {
        guard !isLocked else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        let siblings = node.parent?.children ?? roots
        guard !siblings.contains(where: { $0.id != node.id && $0.name == trimmed }) else { return }
        node.name = trimmed
        markChanged()
    }

    /// Mueve un nodo dentro de `target` (o a la raíz si es `nil`). No permite
    /// moverlo a sí mismo, a un descendiente, ni donde ya exista ese nombre.
    func move(_ node: FileNode, into target: FileNode?) {
        guard !isLocked, !isSelfOrDescendant(target, of: node) else { return }
        let destination = target?.children ?? roots
        guard !destination.contains(where: { $0.name == node.name }) else { return }
        remove(node)
        insert(node, into: target)
        markChanged()
    }

    /// `true` si `node` puede moverse a `target` (no a sí mismo ni a un descendiente).
    func canMove(_ node: FileNode, into target: FileNode?) -> Bool {
        !isLocked && !isSelfOrDescendant(target, of: node)
    }

    /// Carpetas válidas como destino para mover `node` (excluye su carpeta actual,
    /// sí mismo y sus descendientes).
    func moveDestinations(for node: FileNode) -> [FileNode] {
        allFolders().filter { folder in
            folder.id != node.parent?.id && !isSelfOrDescendant(folder, of: node)
        }
    }

    private func allFolders() -> [FileNode] {
        var result: [FileNode] = []
        func walk(_ nodes: [FileNode]) {
            for n in nodes where n.isDirectory {
                result.append(n)
                walk(n.children)
            }
        }
        walk(roots)
        return result
    }

    /// `true` si `candidate` es `node` o está dentro de `node`.
    private func isSelfOrDescendant(_ candidate: FileNode?, of node: FileNode) -> Bool {
        var current = candidate
        while let cur = current {
            if cur.id == node.id { return true }
            current = cur.parent
        }
        return false
    }

    // MARK: - Documento: cerrar y guardar

    /// Borra el temporal de volúmenes concatenados, si lo hay. En Unix es seguro
    /// aunque `sourceArchiveData` siga mapeado: las páginas siguen válidas hasta soltarlo.
    private func discardJoinedVolumesTemp() {
        if let temp = joinedVolumesTemp { try? FileManager.default.removeItem(at: temp) }
        joinedVolumesTemp = nil
    }

    /// Cierra el documento y vuelve al estado vacío (zona de arrastre).
    func close() {
        discardJoinedVolumesTemp()
        roots = []
        selectedIDs = []
        sourceArchiveData = nil
        sourceURL = nil
        documentName = ""
        hasActiveDocument = false
        hasUnsavedChanges = false
        entryPassword = nil
        lockState = .unlocked
        saveEncryption = .none
        savePassword = nil
        format = .zip
        saveFormat = .zip
        saveVolumeSize = nil
        changed()
    }

    /// Marca el documento como guardado en `url` (actualiza nombre y origen).
    func markSaved(as url: URL) {
        sourceURL = url
        documentName = url.lastPathComponent
        hasUnsavedChanges = false
        changed()
    }

    /// Escribe un plan en una ruta destino concreta (en segundo plano, con progreso),
    /// opcionalmente sobrescribiendo.
    /// `true` mientras hay una extracción cancelable en curso (botón Extraer **o** arrastre al
    /// Finder). La vista lo usa para mostrar la (X) del overlay.
    @Published private(set) var extractionCancellable = false
    /// Token de la extracción activa; lo comparte la ruta de fondo que descomprime.
    private var cancelToken: CancelToken?

    /// Registra una extracción cancelable y prepara el progreso. Lo llaman ambas rutas (el
    /// botón aquí mismo; el arrastre al Finder desde el delegado de promesas). Hilo principal.
    func registerExtraction(token: CancelToken, total: Int64) {
        cancelToken = token
        extractionCancellable = true
        // Determinado si conocemos el tamaño total; si no (entradas sin tamaño), indeterminado.
        progress = ProgressState(kind: .extracting, fraction: total > 0 ? 0 : nil)
    }

    /// Fin de la extracción: limpia progreso, flag y token.
    func endExtraction() {
        progress = nil
        extractionCancellable = false
        cancelToken = nil
    }

    /// Cancela la extracción en curso (X del overlay o cierre de la ventana): la descompresión
    /// aborta en el siguiente trozo y `writeFileAtomically` descarta el temporal a medias.
    func cancelExtraction() { cancelToken?.cancel() }

    func performExtraction(of plan: ExportPlan, to destination: URL, overwrite: Bool) async throws {
        if overwrite, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let total = plan.byteCount()
        let token = CancelToken()
        registerExtraction(token: token, total: total)
        defer { endExtraction() }

        // Tarea separada (fondo): la descompresión consulta el token en cada trozo y lanza
        // `CancellationError` al cancelar. Coalescemos progreso/nombre a saltos del ~1%.
        try await Task.detached(priority: .userInitiated) {
            guard total > 0 else {
                try plan.writeContents(to: destination, isCancelled: { token.isCancelled })
                return
            }
            var done: Int64 = 0
            var lastReported = 0.0
            try plan.writeContents(to: destination, onProgress: { name, bytes in
                done += bytes
                let fraction = min(1, Double(done) / Double(total))
                guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
                lastReported = fraction
                Task { @MainActor in
                    self.progress?.fraction = fraction
                    self.progress?.detail = name
                }
            }, isCancelled: { token.isCancelled })
        }.value
    }

    /// Crea un plan de exportación ligero (sin tocar disco) para arrastrar al
    /// Finder. La extracción real ocurre luego, en segundo plano, al soltar.
    func exportPlan(for node: FileNode) -> ExportPlan {
        if node.isDirectory {
            return ExportPlan(name: node.name, payload: .folder(node.children.map { exportPlan(for: $0) }))
        }
        switch node.source {
        case .diskFile(let url):
            return ExportPlan(name: node.name, payload: .diskFile(url))
        case .entry(let entry):
            return ExportPlan(name: node.name, payload: .archiveEntry(
                entry: entry, archive: sourceArchiveData ?? Data(), password: entryPassword, format: format))
        case .folder:
            return ExportPlan(name: node.name, payload: .folder([]))
        }
    }

    /// Plan de exportación de **todo** el contenido, agrupado en una carpeta llamada
    /// `name` (para "Extraer todo": descomprime el archivo entero, como hace Finder).
    func exportPlanForAll(named name: String) -> ExportPlan {
        ExportPlan(name: name, payload: .folder(roots.map { exportPlan(for: $0) }))
    }

    /// Escribe el documento en `url` con el formato/cifrado/volúmenes dados, en streaming
    /// a disco y en segundo plano con progreso. **No toca el estado del documento** — es
    /// la pieza común de `save` (que además adopta el fichero) y `export` (que no).
    private func writeArchive(to url: URL, format outputFormat: ArchiveFormat,
                              encryption: ZipEncryption, password: String?, volumeSize: Int?,
                              level: CompressionLevel) async throws {
        let volumes = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        let cipher = outputFormat.supportsEncryption ? encryption : .none
        let pwd = outputFormat.supportsEncryption ? password : nil
        // Arranca **indeterminado** (spinner): el ensamblado del payload no reporta fracción
        // (puede descomprimir entradas de origen). El escritor ZIP la fija al empezar a escribir,
        // y la barra pasa a determinada; los demás formatos siguen indeterminados.
        progress = ProgressState(kind: cipher == .none ? .compressing(documentName) : .encrypting(documentName),
                                 fraction: nil)
        defer { progress = nil }

        // 1) Producir el archivo completo en un fichero temporal. El documento decide
        // *qué* escribir y el ArchiveSaver decide *cómo* (codifica a disco). El ensamblado del
        // payload puede descomprimir/descifrar las entradas de origen (p. ej. re-guardar un
        // tar.gz/7z/zip cifrado), así que se hace en **segundo plano** sobre una instantánea
        // `Sendable` del árbol; en el hilo principal solo se toma esa instantánea (barata).
        let snapshot = roots.map(NodeSnapshot.init)
        let builder = SavePayloadBuilder(roots: snapshot, documentName: documentName,
                                         sourceFormat: format, sourceArchiveData: sourceArchiveData,
                                         entryPassword: entryPassword)
        let payload = try await Task.detached(priority: .userInitiated) {
            try builder.payload(for: outputFormat, encryption: cipher, password: pwd, level: level)
        }.value
        let work = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).filepackr.work")
        do {
            try await ArchiveSaver.encode(payload, to: work, progress: makeProgressReporter())
            // 2) Colocar el resultado: un solo fichero o dividido en volúmenes.
            if let volumes {
                progress = ProgressState(kind: .splitting, fraction: nil)
                try await VolumeStore.split(file: work, base: url, volumeSize: volumes)
                try? FileManager.default.removeItem(at: work)
            } else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: work, to: url)
                VolumeStore.removeContinuations(of: url)   // limpiar restos de un split previo
            }
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Guarda en `url`, **adopta** el fichero como documento activo y recuerda los ajustes
    /// para re-guardar. (Primer guardado / botón Guardar.)
    func save(to url: URL, format outputFormat: ArchiveFormat,
              encryption: ZipEncryption, password: String?, volumeSize: Int? = nil,
              level: CompressionLevel = .default) async throws {
        saveFormat = outputFormat
        saveLevel = level
        saveVolumeSize = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        if outputFormat == .zip {
            saveEncryption = outputFormat.supportsEncryption ? encryption : .none
            savePassword = outputFormat.supportsEncryption ? password : nil
        }
        try await writeArchive(to: url, format: outputFormat, encryption: encryption,
                               password: password, volumeSize: volumeSize, level: level)
        markSaved(as: url)
    }

    /// Re-guarda con los ajustes ya elegidos (botón Guardar de un documento existente).
    func save(to url: URL) async throws {
        try await save(to: url, format: saveFormat, encryption: saveEncryption,
                       password: savePassword, volumeSize: saveVolumeSize, level: saveLevel)
    }

    /// Exporta el documento a `url` con el formato/cifrado/volúmenes elegidos **sin**
    /// cambiar el documento activo: el original sigue siendo el actual, con sus ajustes
    /// y su `sourceURL` intactos. Es la vía para cambiar cifrado/contraseña o convertir
    /// de formato escribiendo una copia aparte.
    func export(to url: URL, format outputFormat: ArchiveFormat,
                encryption: ZipEncryption, password: String?, volumeSize: Int? = nil,
                level: CompressionLevel = .default) async throws {
        try await writeArchive(to: url, format: outputFormat, encryption: encryption,
                               password: password, volumeSize: volumeSize, level: level)
    }

    // MARK: - Navegación del árbol

    /// Nodo "principal" de la selección (el primero), para decidir destino de Añadir
    /// o Nueva carpeta. Con selección única equivale al elemento seleccionado.
    func selectedNode() -> FileNode? { node(with: selectedIDs.first) }

    /// Todos los nodos seleccionados (para borrado/extracción en lote).
    func selectedNodes() -> [FileNode] { selectedIDs.compactMap { node(with: $0) } }

    /// Ficheros (no carpetas) hermanos de `node`, en orden, para navegar en Quick Look.
    func siblingFiles(of node: FileNode) -> [FileNode] {
        let siblings = node.parent?.children ?? roots
        return siblings.filter { !$0.isDirectory }
    }

    func node(with id: FileNode.ID?) -> FileNode? {
        guard let id else { return nil }
        func search(_ nodes: [FileNode]) -> FileNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: - Implementación

    private func buildTree(from entries: [ArchiveEntry]) -> [FileNode] {
        var rootNodes: [FileNode] = []
        var index: [String: FileNode] = [:]

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            var parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.first == "." { parts.removeFirst() }   // tar suele prefijar "./"
            guard !parts.isEmpty else { continue }

            var accumulated = ""
            var parent: FileNode?
            for (i, part) in parts.enumerated() {
                let isLast = i == parts.count - 1
                accumulated = accumulated.isEmpty ? part : "\(accumulated)/\(part)"
                let isDir = !isLast || entry.isDirectory

                if let existing = index[accumulated] {
                    if isLast {
                        existing.entryDate = entry.modificationDate
                        if !entry.isDirectory { existing.source = .entry(entry) }
                    }
                    parent = existing
                    continue
                }
                let node = FileNode(
                    name: part,
                    isDirectory: isDir,
                    source: (isLast && !entry.isDirectory) ? .entry(entry) : .folder
                )
                if isLast { node.entryDate = entry.modificationDate }
                node.parent = parent
                if let parent { parent.children.append(node) } else { rootNodes.append(node) }
                index[accumulated] = node
                parent = node
            }
        }
        return rootNodes
    }

    /// Importa recursivamente un elemento del disco y devuelve el nodo creado junto al número
    /// de elementos omitidos por la política. Al expandir una carpeta, omite los hijos que la
    /// política marque como ocultos/sistema (enumeramos sin `.skipsHiddenFiles` para decidirlo
    /// nosotros: así `.includeAll` puede de verdad incluir los ocultos), contando cada nombre
    /// omitido como uno. El elemento raíz no se filtra aquí —se respeta la elección explícita;
    /// el filtro lo aplica quien añade.
    private func importFromDisk(_ url: URL, hiddenPolicy: AddHiddenPolicy) -> (node: FileNode, excluded: Int) {
        if isDirectory(url) {
            let folder = FileNode(name: url.lastPathComponent, isDirectory: true, source: .folder)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) ?? []
            var excluded = 0
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if hiddenPolicy.excludes(child.lastPathComponent) {
                    excluded += 1
                    continue
                }
                let imported = importFromDisk(child, hiddenPolicy: hiddenPolicy)
                imported.node.parent = folder
                folder.children.append(imported.node)
                excluded += imported.excluded
            }
            return (folder, excluded)
        }
        return (FileNode(name: url.lastPathComponent, isDirectory: false, source: .diskFile(url)), 0)
    }


    // MARK: - Inserción / borrado / utilidades

    private func insert(_ node: FileNode, into parent: FileNode?) {
        node.parent = parent
        if let parent { parent.children.append(node) } else { roots.append(node) }
    }

    private func remove(_ node: FileNode) {
        if let parent = node.parent {
            parent.children.removeAll { $0.id == node.id }
        } else {
            roots.removeAll { $0.id == node.id }
        }
    }

    /// Carpeta donde Añadir mete los elementos: la seleccionada si es carpeta,
    /// si no el padre del seleccionado, si no la raíz.
    private func destinationFolderForAdding() -> FileNode? {
        guard let node = selectedNode() else { return nil }
        return node.isDirectory ? node : node.parent
    }

    /// Dónde crear una carpeta nueva (decisión: dentro si hay carpeta seleccionada,
    /// al mismo nivel si hay fichero seleccionado, en la raíz si no hay selección).
    private func folderForNewFolder() -> FileNode? {
        guard let node = selectedNode() else { return nil }
        return node.isDirectory ? node : node.parent
    }

    private func uniqueName(_ base: String, among siblings: [FileNode]) -> String {
        let taken = Set(siblings.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// El documento es un único fichero (apto para guardar como `.gz`).
    var isSingleFile: Bool { roots.count == 1 && !roots[0].isDirectory }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// `true` si el fichero es un contenedor que sabemos abrir: por extensión o, si esta
    /// no la reconoce, por la firma de su cabecera (p. ej. un `.bin` que en realidad es 7z).
    private func isOpenableArchive(_ url: URL) -> Bool {
        if ArchiveFormat.isOpenableArchive(url) { return true }
        return peekHeader(url).flatMap(ArchiveFormat.detectByMagic) != nil
    }

    /// Lee unos pocos bytes de cabecera para la detección por firma. `nil` si no se puede.
    private func peekHeader(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 512)
    }

    /// Reporter `@Sendable` para actualizar la barra de progreso desde tareas en
    /// segundo plano sin capturar `self` directamente en el código concurrente.
    private func makeProgressReporter() -> @Sendable (Double) -> Void {
        { fraction in
            Task { @MainActor in self.progress?.fraction = fraction }
        }
    }

    /// Resumen del contenido para la barra de estado (recalculado al cambiar la
    /// estructura, no en cada render): nº de ficheros y tamaño total descomprimido.
    private(set) var contentFileCount = 0
    private(set) var contentSize: UInt64 = 0
    /// Tamaño comprimido total. Solo lo conocen las entradas de un archivo abierto;
    /// los ficheros añadidos aún sin comprimir no tienen tamaño comprimido conocido.
    private(set) var contentCompressedSize: UInt64 = 0
    /// `true` solo si **todas** las entradas tienen tamaño comprimido conocido. Si hay
    /// ficheros recién añadidos (aún sin comprimir), el total sería una mezcla engañosa
    /// de tamaños reales y ceros, así que la barra de estado oculta la cifra.
    private(set) var contentCompressedKnown = false

    private func recomputeContentSummary() {
        var files = 0
        var bytes: UInt64 = 0
        var compressed: UInt64 = 0
        var compressedKnown = true
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                if node.isDirectory { walk(node.children) }
                else {
                    files += 1
                    bytes += node.fileSize ?? 0
                    if let c = node.compressedSize { compressed += c }
                    else { compressedKnown = false }
                }
            }
        }
        walk(roots)
        contentFileCount = files
        contentSize = bytes
        contentCompressedSize = compressed
        contentCompressedKnown = files > 0 && compressedKnown
    }

    /// Las mutaciones tocan nodos (clases); subir `revision` (publicado) avisa a
    /// SwiftUI y le dice a la vista de lista que debe recargar.
    private func changed() {
        recomputeContentSummary()
        revision &+= 1
    }

    /// Como `changed()`, pero además marca el documento con cambios sin guardar.
    private func markChanged() {
        hasUnsavedChanges = true
        changed()
    }
}


