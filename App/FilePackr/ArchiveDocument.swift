import Foundation
import Combine
import UniformTypeIdentifiers
import ArchiveBrowser

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
    /// El archivo abierto tiene entradas cifradas y aún no tenemos la contraseña.
    @Published private(set) var requiresEntryPassword = false
    /// Un 7z con cabeceras cifradas necesita contraseña para **abrirse** (no solo extraer).
    @Published private(set) var requiresOpenPassword = false
    private var pendingArchiveURL: URL?
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
    @discardableResult
    func addFile(_ url: URL, into target: FileNode?, replacing existing: FileNode? = nil,
                 renameTo newName: String? = nil) -> FileNode? {
        guard !isLocked else { return nil }
        if !hasActiveDocument { beginNewDocument() }
        if let existing { remove(existing) }
        let node = importFromDisk(url)
        if let newName { node.name = newName }
        insert(node, into: target)
        markChanged()
        return node
    }

    /// Decide qué hacer con lo que llega: abrir un ZIP como base o añadir ficheros.
    func handleIncoming(_ urls: [URL]) async throws {
        let cleaned = urls.filter { $0.isFileURL }
        guard !cleaned.isEmpty else { return }

        if isEmpty, cleaned.count == 1, !isDirectory(cleaned[0]), isOpenableArchive(cleaned[0]) {
            try await openArchive(cleaned[0])
        } else {
            if isEmpty { beginNewDocument() }
            addFiles(cleaned)
        }
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
            pendingArchiveURL = url
            requiresOpenPassword = true
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
        requiresOpenPassword = false
        // ZIP y 7z pueden tener entradas cifradas; si no dimos contraseña al abrir,
        // se pedirá al extraer/previsualizar. tar/gz/xz/bz2 nunca cifran.
        requiresEntryPassword = passphrase == nil
            && (result.format == .zip || result.format.usesLibArchive)
            && result.entries.contains { $0.isEncrypted }
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
        guard let archive = sourceArchiveData,
              let node = firstEncryptedFile(in: roots),
              case .zipEntry(let entry) = node.source else {
            entryPassword = password
            requiresEntryPassword = false
            return true
        }
        do {
            _ = try format.codec.entryData(for: entry, in: archive, password: password)
        } catch {
            return false
        }
        entryPassword = password
        savePassword = password   // misma contraseña para re-guardar cifrado
        requiresEntryPassword = false
        changed()
        return true
    }

    /// Da la contraseña para **abrir** un 7z con cabeceras cifradas. Reintenta la
    /// apertura; devuelve `false` si es incorrecta (sigue pidiéndola).
    func provideOpenPassword(_ password: String) async -> Bool {
        guard let url = pendingArchiveURL else { return false }
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
            } else if case .zipEntry(let entry) = node.source, entry.isEncrypted {
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
        requiresEntryPassword = false
        requiresOpenPassword = false
        pendingArchiveURL = nil
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
    func addFiles(_ urls: [URL], into target: FileNode?) -> [FileNode] {
        guard !isLocked else { return [] }
        if !hasActiveDocument { beginNewDocument() }
        var added: [FileNode] = []
        for url in urls {
            let node = importFromDisk(url)
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
        requiresEntryPassword = false
        requiresOpenPassword = false
        pendingArchiveURL = nil
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
    func performExtraction(of plan: ExportPlan, to destination: URL, overwrite: Bool) async throws {
        if overwrite, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let total = max(1, plan.fileCount())
        progress = ProgressState(kind: .extracting, fraction: 0)
        defer { progress = nil }
        try await runExtraction(plan, to: destination, total: total)
    }

    nonisolated private func runExtraction(_ plan: ExportPlan, to destination: URL, total: Int) async throws {
        try await Task.detached(priority: .userInitiated) {
            var done = 0
            try plan.writeContents(to: destination) {
                done += 1
                let fraction = Double(done) / Double(total)
                Task { @MainActor in self.progress?.fraction = fraction }
            }
        }.value
    }

    /// Devuelve una ruta libre añadiendo "_2", "_3"… cuando ya existe el nombre.
    func conflictFreeURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
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
        case .zipEntry(let entry):
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

    /// Datos sin comprimir de un nodo, leídos según el formato del archivo de origen.
    /// Sirve para reconstruir el contenido al guardar en otro formato o al extraer.
    private func nodeData(_ node: FileNode) -> Data? {
        switch node.source {
        case .folder: return nil
        case .diskFile(let url): return try? Data(contentsOf: url)
        case .zipEntry(let entry):
            guard let archive = sourceArchiveData else { return nil }
            return try? format.codec.entryData(for: entry, in: archive, password: entryPassword)
        }
    }

    /// Escribe el documento en `url` con el formato/cifrado/volúmenes dados, en streaming
    /// a disco y en segundo plano con progreso. **No toca el estado del documento** — es
    /// la pieza común de `save` (que además adopta el fichero) y `export` (que no).
    private func writeArchive(to url: URL, format outputFormat: ArchiveFormat,
                              encryption: ZipEncryption, password: String?, volumeSize: Int?) async throws {
        let volumes = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        let cipher = outputFormat.supportsEncryption ? encryption : .none
        let pwd = outputFormat.supportsEncryption ? password : nil
        progress = ProgressState(kind: cipher == .none ? .compressing(documentName) : .encrypting(documentName),
                                 fraction: outputFormat == .zip ? 0 : nil)
        defer { progress = nil }

        // 1) Producir el archivo completo en un fichero temporal. El documento decide
        // *qué* escribir (lee el árbol); el ArchiveSaver decide *cómo* (codifica a disco).
        let payload = try makeSavePayload(for: outputFormat, encryption: cipher, password: pwd)
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
              encryption: ZipEncryption, password: String?, volumeSize: Int? = nil) async throws {
        saveFormat = outputFormat
        saveVolumeSize = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        if outputFormat == .zip {
            saveEncryption = outputFormat.supportsEncryption ? encryption : .none
            savePassword = outputFormat.supportsEncryption ? password : nil
        }
        try await writeArchive(to: url, format: outputFormat, encryption: encryption,
                               password: password, volumeSize: volumeSize)
        markSaved(as: url)
    }

    /// Re-guarda con los ajustes ya elegidos (botón Guardar de un documento existente).
    func save(to url: URL) async throws {
        try await save(to: url, format: saveFormat, encryption: saveEncryption,
                       password: savePassword, volumeSize: saveVolumeSize)
    }

    /// Exporta el documento a `url` con el formato/cifrado/volúmenes elegidos **sin**
    /// cambiar el documento activo: el original sigue siendo el actual, con sus ajustes
    /// y su `sourceURL` intactos. Es la vía para cambiar cifrado/contraseña o convertir
    /// de formato escribiendo una copia aparte.
    func export(to url: URL, format outputFormat: ArchiveFormat,
                encryption: ZipEncryption, password: String?, volumeSize: Int? = nil) async throws {
        try await writeArchive(to: url, format: outputFormat, encryption: encryption,
                               password: password, volumeSize: volumeSize)
    }

    /// Ensambla, leyendo el árbol, el `SavePayload` (`Sendable`) para el formato de
    /// salida. Lanza para formatos de solo lectura o si un formato de un solo fichero
    /// no tiene contenido. El ArchiveSaver lo escribe luego a disco.
    private func makeSavePayload(for outputFormat: ArchiveFormat,
                                 encryption: ZipEncryption, password: String?) throws -> SavePayload {
        switch outputFormat {
        case .zip:
            return .zip(inputs: makeSaveInputs(), encryption: encryption, password: password)
        case .tar:
            let items = makeTarItems()
            return .stream { handle in
                let next = Tar.reader(items)
                while let chunk = try next() { try handle.write(contentsOf: chunk) }
            }
        case .tarGzip:
            let items = makeTarItems()
            let name = documentName.isEmpty ? nil : documentName
            return .stream { handle in
                try Gzip.compress(next: Tar.reader(items), sink: { try handle.write(contentsOf: $0) }, filename: name)
            }
        case .tarXz:
            let items = makeTarItems()
            return .stream { handle in
                try Xz.compress(next: Tar.reader(items), sink: { try handle.write(contentsOf: $0) })
            }
        case .tarBzip2:
            let items = makeTarItems()
            return .stream { handle in
                try Bzip2.compress(next: Tar.reader(items), sink: { try handle.write(contentsOf: $0) })
            }
        case .gzip:
            guard let node = roots.first(where: { !$0.isDirectory }) else { throw CocoaError(.fileWriteUnknown) }
            let name = node.name
            return try singleFilePayload(node,
                stream: { try Gzip.compress(from: $0, to: $1, filename: name) },
                memory: { Gzip.compress($0, filename: name) })
        case .xz:
            guard let node = roots.first(where: { !$0.isDirectory }) else { throw CocoaError(.fileWriteUnknown) }
            return try singleFilePayload(node, stream: { try Xz.compress(from: $0, to: $1) },
                                         memory: { Xz.compress($0) })
        case .bzip2:
            guard let node = roots.first(where: { !$0.isDirectory }) else { throw CocoaError(.fileWriteUnknown) }
            return try singleFilePayload(node, stream: { try Bzip2.compress(from: $0, to: $1) },
                                         memory: { Bzip2.compress($0) })
        case .sevenZip, .iso, .xar:
            guard let writeFormat = outputFormat.libArchiveWriteFormat else {
                throw CocoaError(.fileWriteUnsupportedScheme)
            }
            return .libArchive(items: makeLibArchiveItems(), format: writeFormat)
        case .rar, .cpio, .lha, .cab:
            throw CocoaError(.fileWriteUnsupportedScheme)   // formatos de solo lectura
        }
    }

    /// Payload para formatos de un solo fichero (gz/xz/bz2). Si el contenido es un
    /// fichero de disco, comprime en **streaming** (memoria constante); si ya está en
    /// RAM (entrada de un archivo abierto), usa la ruta en memoria.
    private func singleFilePayload(_ node: FileNode,
                                   stream: @escaping @Sendable (FileHandle, FileHandle) throws -> Void,
                                   memory: @escaping @Sendable (Data) -> Data) throws -> SavePayload {
        if case .diskFile(let url) = node.source {
            return .stream { out in
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                try stream(input, out)
            }
        }
        guard let data = nodeData(node) else { throw CocoaError(.fileWriteUnknown) }
        return .data { memory(data) }
    }

    /// Construye las entradas para escribir un TAR. Los ficheros de disco van como **URL**
    /// (se leen al vuelo al escribir, sin cargarlos en RAM); las entradas de un archivo ya
    /// abierto van como bytes (reconstruidos en memoria, que es donde están).
    private func makeTarItems() -> [Tar.WriteItem] {
        var items: [Tar.WriteItem] = []
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix + node.name
                if node.isDirectory {
                    items.append(Tar.WriteItem(path: path + "/", data: Data(),
                                               modifiedAt: node.modificationDate, isDirectory: true))
                    walk(node.children, prefix: path + "/")
                } else if case .diskFile(let url) = node.source {
                    items.append(Tar.WriteItem(path: path, fileURL: url, modifiedAt: node.modificationDate))
                } else if let data = nodeData(node) {
                    items.append(Tar.WriteItem(path: path, data: data,
                                               modifiedAt: node.modificationDate, isDirectory: false))
                }
            }
        }
        walk(roots, prefix: "")
        return items
    }

    /// Como `makeTarItems`, pero para el escritor de 7z/iso/xar de libarchive: los ficheros
    /// de disco van como URL (se leen al vuelo); las entradas de un archivo abierto, en memoria.
    private func makeLibArchiveItems() -> [LibArchive.WriteItem] {
        var items: [LibArchive.WriteItem] = []
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix + node.name
                if node.isDirectory {
                    items.append(LibArchive.WriteItem(path: path, data: Data(),
                                                      modifiedAt: node.modificationDate, isDirectory: true))
                    walk(node.children, prefix: path + "/")
                } else if case .diskFile(let url) = node.source {
                    items.append(LibArchive.WriteItem(path: path, fileURL: url, modifiedAt: node.modificationDate))
                } else if let data = nodeData(node) {
                    items.append(LibArchive.WriteItem(path: path, data: data,
                                                      modifiedAt: node.modificationDate, isDirectory: false))
                }
            }
        }
        walk(roots, prefix: "")
        return items
    }

    /// Construye las entradas a escribir. Es ligero: los ficheros nuevos van como
    /// `.file(url)` (se leen al vuelo) y las entradas de un zip abierto como bytes
    /// comprimidos en crudo (rebanada barata del archivo origen ya mapeado).
    private func makeSaveInputs() -> [ZipEntryInput] {
        let extractor = ZipExtractor()
        var items: [ZipEntryInput] = []
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix + node.name
                if node.isDirectory {
                    items.append(ZipEntryInput(path: path + "/", modifiedAt: node.modificationDate, source: .directory))
                    walk(node.children, prefix: path + "/")
                } else if case .diskFile(let url) = node.source {
                    items.append(ZipEntryInput(path: path, modifiedAt: node.modificationDate, source: .file(url)))
                } else if case .zipEntry(let entry) = node.source, let archive = sourceArchiveData {
                    if format != .zip {
                        // Origen tar/gz: reconstruir el texto claro y dejar que el escritor comprima.
                        if let data = nodeData(node) {
                            items.append(ZipEntryInput(path: path, modifiedAt: node.modificationDate, source: .data(data)))
                        }
                    } else if entry.isEncrypted {
                        // Cifrada: descifrar a texto claro; el escritor la re-cifra (o no) limpiamente.
                        if let data = try? extractor.extractedData(for: entry, in: archive, password: entryPassword) {
                            items.append(ZipEntryInput(path: path, modifiedAt: entry.modificationDate, source: .data(data)))
                        }
                    } else if let zip = entry.zip, let raw = try? extractor.rawCompressedData(for: entry, in: archive) {
                        // Sin cifrar: copiar los bytes comprimidos en crudo (más rápido).
                        items.append(ZipEntryInput(path: path, modifiedAt: entry.modificationDate,
                            source: .rawEntry(method: zip.compressionMethod, crc32: zip.crc32,
                                              compressed: raw, uncompressedSize: entry.uncompressedSize)))
                    }
                }
            }
        }
        walk(roots, prefix: "")
        return items
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
                        existing.zipDate = entry.modificationDate
                        if !entry.isDirectory { existing.source = .zipEntry(entry) }
                    }
                    parent = existing
                    continue
                }
                let node = FileNode(
                    name: part,
                    isDirectory: isDir,
                    source: (isLast && !entry.isDirectory) ? .zipEntry(entry) : .folder
                )
                if isLast { node.zipDate = entry.modificationDate }
                node.parent = parent
                if let parent { parent.children.append(node) } else { rootNodes.append(node) }
                index[accumulated] = node
                parent = node
            }
        }
        return rootNodes
    }

    private func importFromDisk(_ url: URL) -> FileNode {
        if isDirectory(url) {
            let folder = FileNode(name: url.lastPathComponent, isDirectory: true, source: .folder)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let node = importFromDisk(child)
                node.parent = folder
                folder.children.append(node)
            }
            return folder
        }
        return FileNode(name: url.lastPathComponent, isDirectory: false, source: .diskFile(url))
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


