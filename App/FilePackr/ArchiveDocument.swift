import Foundation
import Combine
import UniformTypeIdentifiers
import ArchiveBrowser

/// Origen del contenido de un nodo del árbol.
enum NodeSource {
    case folder                   // carpeta (puede contener hijos)
    case diskFile(URL)            // fichero nuevo que vive en disco, aún sin comprimir
    case zipEntry(ArchiveEntry)   // entrada que proviene de un archivo abierto (zip/tar/gz)
}

/// Formato del contenedor abierto o de salida.
enum ArchiveFormat: String, Sendable, CaseIterable, Hashable {
    case zip, tar, tarGzip, tarXz, tarBzip2, gzip, xz, bzip2
    case sevenZip, rar, iso, cpio, xar, lha, cab

    /// Clave de localización del nombre mostrado en el selector de formato.
    var nameKey: String {
        switch self {
        case .zip: return "format.zip"
        case .tar: return "format.tar"
        case .tarGzip: return "format.tarGzip"
        case .tarXz: return "format.tarXz"
        case .tarBzip2: return "format.tarBzip2"
        case .gzip: return "format.gzip"
        case .xz: return "format.xz"
        case .bzip2: return "format.bzip2"
        case .sevenZip: return "format.sevenZip"
        case .rar: return "format.rar"
        case .iso: return "format.iso"
        case .cpio: return "format.cpio"
        case .xar: return "format.xar"
        case .lha: return "format.lha"
        case .cab: return "format.cab"
        }
    }

    /// Extensión de fichero asociada.
    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarXz: return "tar.xz"
        case .tarBzip2: return "tar.bz2"
        case .gzip: return "gz"
        case .xz: return "xz"
        case .bzip2: return "bz2"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .iso: return "iso"
        case .cpio: return "cpio"
        case .xar: return "xar"
        case .lha: return "lha"
        case .cab: return "cab"
        }
    }

    /// Solo ZIP admite cifrado con contraseña al **escribir** (7z se descifra al leer).
    var supportsEncryption: Bool { self == .zip }

    /// La división en volúmenes (por bytes, sufijo `.001`/`.002`…) es genérica y
    /// vale para todos los formatos de salida que escribimos.
    var supportsVolumeSplit: Bool { true }

    /// Formatos de un solo fichero (gzip/xz/bzip2): solo si el documento es un fichero.
    var isSingleFileOnly: Bool { self == .gzip || self == .xz || self == .bzip2 }

    /// `false` para formatos solo de lectura (rar propietario; cpio/lha/cab no se escriben).
    var isWritable: Bool { ![.rar, .cpio, .lha, .cab].contains(self) }

    /// Se lee/escribe con la libarchive del sistema (no en Swift puro).
    var usesLibArchive: Bool { [.sevenZip, .rar, .iso, .cpio, .xar, .lha, .cab].contains(self) }

    /// Formato de escritura de libarchive (solo para los escribibles vía libarchive).
    var libArchiveWriteFormat: LibArchive.WriteFormat? {
        switch self {
        case .sevenZip: return .sevenZip
        case .iso: return .iso
        case .xar: return .xar
        default: return nil
        }
    }
}

/// Nodo del árbol editable que se muestra en el cuerpo central.
final class FileNode: Identifiable {
    let id = UUID()
    var name: String
    let isDirectory: Bool
    var source: NodeSource
    var children: [FileNode]
    weak var parent: FileNode?
    /// Fecha que trae la entrada del ZIP (ficheros y carpetas). `nil` si no procede de un ZIP.
    var zipDate: Date?

    init(name: String, isDirectory: Bool, source: NodeSource, children: [FileNode] = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.source = source
        self.children = children
    }

    /// `nil` en ficheros (para que la lista no muestre flecha de despliegue),
    /// la lista de hijos en carpetas.
    var childrenOrNil: [FileNode]? { isDirectory ? children : nil }

    /// Tamaño real (descomprimido). Carpetas: nil.
    var fileSize: UInt64? {
        guard !isDirectory else { return nil }
        switch source {
        case .zipEntry(let e): return e.uncompressedSize
        case .diskFile(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size.map(UInt64.init)
        case .folder: return nil
        }
    }

    /// Tamaño comprimido dentro del archivo (solo se conoce para entradas del ZIP).
    var compressedSize: UInt64? {
        if case .zipEntry(let e) = source, !isDirectory { return e.compressedSize }
        return nil
    }

    /// Fecha de modificación: del ZIP, del disco (ficheros nuevos) o, para carpetas
    /// sin fecha propia (zips sin entrada de carpeta), la del contenido más reciente.
    var modificationDate: Date? {
        if let zipDate { return zipDate }
        if case .diskFile(let url) = source {
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        if isDirectory {
            return children.compactMap(\.modificationDate).max()
        }
        return nil
    }

    /// Descripción del tipo ("Carpeta", "Imagen PNG", …), como la "Clase" del Finder.
    var kindDescription: String {
        if isDirectory { return Localizer.shared("kind.folder") }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
            return desc.prefix(1).uppercased() + desc.dropFirst()
        }
        return ext.isEmpty ? Localizer.shared("kind.document")
                           : Localizer.shared("kind.documentExt", ext.uppercased())
    }

    /// Ruta completa "carpeta/subcarpeta/nombre" para mostrar en menús.
    var pathLabel: String {
        var parts = [name]
        var ancestor = parent
        while let current = ancestor {
            parts.insert(current.name, at: 0)
            ancestor = current.parent
        }
        return parts.joined(separator: "/")
    }
}

/// Documento de trabajo: el árbol de elementos que acabará siendo un ZIP.
/// Mantiene, si se abrió un ZIP existente, sus bytes originales para poder
/// extraer o copiar entradas sin recomprimir.
@MainActor
final class ArchiveDocument: ObservableObject {

    @Published var roots: [FileNode] = []
    @Published var selection: FileNode.ID?

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

    static var untitledName: String { Localizer.shared("doc.untitled") }

    private(set) var sourceArchiveData: Data?

    private let writer = ZipWriter()

    var isEmpty: Bool { roots.isEmpty }

    /// Nombre a mostrar: el del fichero guardado, o "Sin título"/"Untitled" (en el
    /// idioma actual) mientras no se haya guardado. Reactivo al cambio de idioma.
    var displayName: String { sourceURL == nil ? Self.untitledName : documentName }

    // MARK: - Entrada de elementos (arrastre o botón Añadir)

    /// Decide qué hacer con lo que llega: abrir un ZIP como base o añadir ficheros.
    func handleIncoming(_ urls: [URL]) async throws {
        let cleaned = urls.filter { $0.isFileURL }
        guard !cleaned.isEmpty else { return }

        if isEmpty, cleaned.count == 1, isOpenableArchive(cleaned[0]), !isDirectory(cleaned[0]) {
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
        let parts = volumeParts(for: url)
        let baseURL = parts.first ?? url
        let detected = detectFormat(for: baseURL)
        progress = ProgressState(label: Localizer.shared("progress.opening", baseURL.lastPathComponent),
                                 fraction: detected == .zip ? 0 : nil)
        defer { progress = nil }

        let fallbackName = baseURL.deletingPathExtension().lastPathComponent
        let report = makeProgressReporter()
        let result: (ArchiveFormat, Data, [ArchiveEntry])
        do {
            result = try await Task.detached(priority: .userInitiated) { () -> (ArchiveFormat, Data, [ArchiveEntry]) in
            let data = parts.count == 1
                ? try Data(contentsOf: parts[0], options: .mappedIfSafe)
                : Volumes.join(try parts.map { try Data(contentsOf: $0) })
            switch detected {
            case .zip:
                var lastReported = 0.0
                let entries = try ZipReader().listEntries(in: data) { fraction in
                    // Limitamos los saltos a la UI (cada ~1%) para no inundar el hilo principal.
                    if fraction - lastReported >= 0.01 || fraction >= 1 {
                        lastReported = fraction
                        report(fraction)
                    }
                }
                return (.zip, data, entries)
            case .tar:
                return (.tar, data, try Tar.listEntries(in: data))
            case .tarGzip:
                let tar = try Gzip.decompress(data)
                return (.tarGzip, tar, try Tar.listEntries(in: tar))
            case .tarXz:
                let tar = try Xz.decompress(data)
                return (.tarXz, tar, try Tar.listEntries(in: tar))
            case .tarBzip2:
                let tar = try Bzip2.decompress(data)
                return (.tarBzip2, tar, try Tar.listEntries(in: tar))
            case .gzip:
                // Un `.gz` puede ser un fichero suelto o un tar.gz: lo distinguimos al descomprimir.
                let inner = try Gzip.decompress(data)
                if Self.isUstar(inner) {
                    return (.tarGzip, inner, try Tar.listEntries(in: inner))
                }
                return (.gzip, data, Gzip.entries(in: data, fallbackName: fallbackName))
            case .xz:
                // Un `.xz` puede ser un fichero suelto o un tar.xz: igual que con gzip.
                let inner = try Xz.decompress(data)
                if Self.isUstar(inner) {
                    return (.tarXz, inner, try Tar.listEntries(in: inner))
                }
                return (.xz, data, Xz.entries(in: data, fallbackName: fallbackName))
            case .bzip2:
                // Un `.bz2` puede ser un fichero suelto o un tar.bz2.
                let inner = try Bzip2.decompress(data)
                if Self.isUstar(inner) {
                    return (.tarBzip2, inner, try Tar.listEntries(in: inner))
                }
                return (.bzip2, data, Bzip2.entries(in: data, fallbackName: fallbackName))
            case .sevenZip, .rar, .iso, .cpio, .xar, .lha, .cab:
                // Formatos de libarchive (lectura). 7z puede lanzar passphraseRequired.
                let (entries, _) = try LibArchive.listEntries(in: data, passphrase: passphrase)
                return (detected, data, entries)
            }
            }.value
        } catch let error as LibArchiveError where error == .passphraseRequired {
            // 7z con cabeceras cifradas: hay que pedir contraseña para abrir.
            pendingArchiveURL = url
            requiresOpenPassword = true
            return
        }

        format = result.0
        sourceArchiveData = result.1
        roots = buildTree(from: result.2)
        selection = nil
        sourceURL = baseURL
        documentName = baseURL.lastPathComponent
        entryPassword = passphrase
        requiresOpenPassword = false
        // ZIP y 7z pueden tener entradas cifradas; si no dimos contraseña al abrir,
        // se pedirá al extraer/previsualizar. tar/gz/xz/bz2 nunca cifran.
        requiresEntryPassword = passphrase == nil
            && (result.0 == .zip || result.0.usesLibArchive)
            && result.2.contains { $0.isEncrypted }
        // Al re-guardar, conservar el cifrado original (con su contraseña, cuando se dé).
        saveEncryption = result.0 == .zip ? detectedEncryption(in: result.2) : .none
        savePassword = nil
        saveFormat = result.0
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
            switch format {
            case .sevenZip, .rar: _ = try LibArchive.extractEntry(path: entry.path, in: archive, passphrase: password)
            default: _ = try ZipExtractor().extractedData(for: entry, in: archive, password: password)
            }
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

    /// Empieza un documento nuevo, aún sin guardar.
    func beginNewDocument() {
        sourceURL = nil
        documentName = Self.untitledName
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
    func addFiles(_ urls: [URL], into target: FileNode?) {
        guard !isLocked else { return }
        if documentName.isEmpty { beginNewDocument() }
        for url in urls {
            let node = importFromDisk(url)
            insert(node, into: target)
        }
        markChanged()
    }

    // MARK: - Acciones de la barra superior

    /// El archivo está cifrado y bloqueado (sin contraseña): no se puede editar.
    var isLocked: Bool { requiresEntryPassword }

    func createFolder() {
        guard !isLocked else { return }
        if documentName.isEmpty { beginNewDocument() }
        let parent = folderForNewFolder()
        let siblings = parent?.children ?? roots
        let name = uniqueName(Localizer.shared("doc.newFolder"), among: siblings)
        let node = FileNode(name: name, isDirectory: true, source: .folder)
        insert(node, into: parent)
        selection = node.id
        markChanged()
    }

    func removeSelected() {
        guard let node = selectedNode() else { return }
        delete(node)
    }

    /// Elimina un nodo concreto (el del menú contextual, por ejemplo).
    func delete(_ node: FileNode) {
        guard !isLocked else { return }
        remove(node)
        if selection == node.id { selection = nil }
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

    /// Cierra el documento y vuelve al estado vacío (zona de arrastre).
    func close() {
        roots = []
        selection = nil
        sourceArchiveData = nil
        sourceURL = nil
        documentName = ""
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
        progress = ProgressState(label: Localizer.shared("progress.extracting"), fraction: 0)
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

    /// Datos sin comprimir de un nodo, leídos según el formato del archivo de origen.
    /// Sirve para reconstruir el contenido al guardar en otro formato o al extraer.
    private func nodeData(_ node: FileNode) -> Data? {
        switch node.source {
        case .folder: return nil
        case .diskFile(let url): return try? Data(contentsOf: url)
        case .zipEntry(let entry):
            guard let archive = sourceArchiveData else { return nil }
            switch format {
            case .zip: return try? ZipExtractor().extractedData(for: entry, in: archive, password: entryPassword)
            case .tar, .tarGzip, .tarXz, .tarBzip2: return try? Tar.entryData(for: entry, in: archive)
            case .gzip: return try? Gzip.decompress(archive)
            case .xz: return try? Xz.decompress(archive)
            case .bzip2: return try? Bzip2.decompress(archive)
            case .sevenZip, .rar, .iso, .cpio, .xar, .lha, .cab:
                return try? LibArchive.extractEntry(path: entry.path, in: archive, passphrase: entryPassword)
            }
        }
    }

    /// Guarda el ZIP en `url` con el formato/cifrado elegidos, en streaming a disco
    /// y en segundo plano con progreso. Recuerda los ajustes para re-guardar.
    func save(to url: URL, format outputFormat: ArchiveFormat,
              encryption: ZipEncryption, password: String?, volumeSize: Int? = nil) async throws {
        saveFormat = outputFormat
        let volumes = (outputFormat.supportsVolumeSplit && (volumeSize ?? 0) > 0) ? volumeSize : nil
        saveVolumeSize = volumes
        let cipher = outputFormat.supportsEncryption ? encryption : .none
        let pwd = outputFormat.supportsEncryption ? password : nil
        if outputFormat == .zip { saveEncryption = cipher; savePassword = pwd }
        progress = ProgressState(label: cipher == .none ? Localizer.shared("progress.compressing", displayName)
                                                         : Localizer.shared("progress.encrypting", displayName),
                                 fraction: outputFormat == .zip ? 0 : nil)
        defer { progress = nil }

        // 1) Producir el archivo completo en un fichero temporal.
        let work = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).filepackr.work")
        do {
            switch outputFormat {
            case .zip:
                let inputs = makeSaveInputs()
                try await streamZip(inputs, to: work, encryption: cipher, password: pwd, writer: writer)
            case .tar:
                let items = makeTarItems()
                try await writeData({ Tar.write(items) }, to: work)
            case .tarGzip:
                let items = makeTarItems()
                let name = documentName
                try await writeData({ Gzip.compress(Tar.write(items), filename: name) }, to: work)
            case .tarXz:
                let items = makeTarItems()
                try await writeData({ Xz.compress(Tar.write(items)) }, to: work)
            case .tarBzip2:
                let items = makeTarItems()
                try await writeData({ Bzip2.compress(Tar.write(items)) }, to: work)
            case .gzip:
                guard let node = roots.first(where: { !$0.isDirectory }), let data = nodeData(node) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let name = node.name
                try await writeData({ Gzip.compress(data, filename: name) }, to: work)
            case .xz:
                guard let node = roots.first(where: { !$0.isDirectory }), let data = nodeData(node) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try await writeData({ Xz.compress(data) }, to: work)
            case .bzip2:
                guard let node = roots.first(where: { !$0.isDirectory }), let data = nodeData(node) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try await writeData({ Bzip2.compress(data) }, to: work)
            case .sevenZip, .iso, .xar:
                guard let writeFormat = outputFormat.libArchiveWriteFormat else { throw CocoaError(.fileWriteUnsupportedScheme) }
                let items = makeLibArchiveItems()
                try await writeLibArchive(items, to: work, format: writeFormat)
            case .rar, .cpio, .lha, .cab:
                throw CocoaError(.fileWriteUnsupportedScheme)   // formatos de solo lectura
            }
            // 2) Colocar el resultado: un solo fichero o dividido en volúmenes.
            if let volumes {
                progress = ProgressState(label: Localizer.shared("progress.splitting"), fraction: nil)
                try await splitFile(work, base: url, volumeSize: volumes)
                try? FileManager.default.removeItem(at: work)
            } else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: work, to: url)
                removeContinuationVolumes(of: url)   // limpiar restos de un split previo
            }
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        markSaved(as: url)
    }

    /// Re-guarda con los ajustes ya elegidos (botón Guardar de un documento existente).
    func save(to url: URL) async throws {
        try await save(to: url, format: saveFormat, encryption: saveEncryption,
                       password: savePassword, volumeSize: saveVolumeSize)
    }

    /// Borra los volúmenes de continuación ("nombre_001.zip"…) junto al fichero base.
    private func removeContinuationVolumes(of base: URL) {
        let directory = base.deletingLastPathComponent()
        let baseName = base.lastPathComponent
        var index = 2
        while true {
            let part = directory.appendingPathComponent(Volumes.partName(base: baseName, index: index))
            guard FileManager.default.fileExists(atPath: part.path) else { break }
            try? FileManager.default.removeItem(at: part)
            index += 1
        }
    }

    /// Divide `source` en volúmenes "nombre.zip", "nombre_001.zip"… de `volumeSize`
    /// bytes, en segundo plano y leyendo por trozos (sin cargar todo en memoria).
    /// Borra volúmenes de continuación sobrantes de un guardado anterior con más partes.
    nonisolated private func splitFile(_ source: URL, base: URL, volumeSize: Int) async throws {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let fm = FileManager.default
            let directory = base.deletingLastPathComponent()
            let baseName = base.lastPathComponent
            var index = 1

            func writePart(_ data: Data) throws {
                let part = directory.appendingPathComponent(Volumes.partName(base: baseName, index: index))
                try? fm.removeItem(at: part)
                try data.write(to: part)
                index += 1
            }

            var wroteAny = false
            while let chunk = try handle.read(upToCount: volumeSize), !chunk.isEmpty {
                try writePart(chunk)
                wroteAny = true
            }
            if !wroteAny { try writePart(Data()) }   // archivo vacío: al menos un volumen

            while true {   // limpiar volúmenes de continuación sobrantes (índice ≥2)
                let stale = directory.appendingPathComponent(Volumes.partName(base: baseName, index: index))
                guard fm.fileExists(atPath: stale.path) else { break }
                try fm.removeItem(at: stale)
                index += 1
            }
        }.value
    }

    /// Construye las entradas (con datos en memoria) para escribir un TAR.
    private func makeTarItems() -> [Tar.WriteItem] {
        var items: [Tar.WriteItem] = []
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix + node.name
                if node.isDirectory {
                    items.append(Tar.WriteItem(path: path + "/", data: Data(),
                                               modifiedAt: node.modificationDate, isDirectory: true))
                    walk(node.children, prefix: path + "/")
                } else if let data = nodeData(node) {
                    items.append(Tar.WriteItem(path: path, data: data,
                                               modifiedAt: node.modificationDate, isDirectory: false))
                }
            }
        }
        walk(roots, prefix: "")
        return items
    }

    /// Como `makeTarItems`, pero para el escritor de 7z de libarchive.
    private func makeLibArchiveItems() -> [LibArchive.WriteItem] {
        var items: [LibArchive.WriteItem] = []
        func walk(_ nodes: [FileNode], prefix: String) {
            for node in nodes {
                let path = prefix + node.name
                if node.isDirectory {
                    items.append(LibArchive.WriteItem(path: path, data: Data(),
                                                      modifiedAt: node.modificationDate, isDirectory: true))
                    walk(node.children, prefix: path + "/")
                } else if let data = nodeData(node) {
                    items.append(LibArchive.WriteItem(path: path, data: data,
                                                      modifiedAt: node.modificationDate, isDirectory: false))
                }
            }
        }
        walk(roots, prefix: "")
        return items
    }

    /// Escribe `make()` (cómputo en segundo plano) en `url` de forma atómica.
    nonisolated private func writeData(_ make: @escaping @Sendable () -> Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try make().write(to: url, options: .atomic)
        }.value
    }

    /// Escribe un archivo de libarchive (7z/iso/xar) en `url`, en segundo plano.
    nonisolated private func writeLibArchive(_ items: [LibArchive.WriteItem], to url: URL,
                                             format: LibArchive.WriteFormat) async throws {
        try await Task.detached(priority: .userInitiated) {
            try LibArchive.write(items, to: url, format: format)
        }.value
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
                    } else if let raw = try? extractor.rawCompressedData(for: entry, in: archive) {
                        // Sin cifrar: copiar los bytes comprimidos en crudo (más rápido).
                        items.append(ZipEntryInput(path: path, modifiedAt: entry.modificationDate,
                            source: .rawEntry(method: entry.compressionMethod, crc32: entry.crc32,
                                              compressed: raw, uncompressedSize: entry.uncompressedSize)))
                    }
                }
            }
        }
        walk(roots, prefix: "")
        return items
    }

    nonisolated private func streamZip(_ inputs: [ZipEntryInput], to url: URL,
                                       encryption: ZipEncryption, password: String?,
                                       writer: ZipWriter) async throws {
        try await Task.detached(priority: .userInitiated) {
            // Escribe a un temporal y luego reemplaza, para no dejar a medias el destino.
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).filepackr.tmp")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try writer.write(inputs, to: handle, encryption: encryption, password: password) { fraction in
                    Task { @MainActor in self.progress?.fraction = fraction }
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        }.value
    }

    // MARK: - Navegación del árbol

    func selectedNode() -> FileNode? { node(with: selection) }

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

    /// `true` si la extensión corresponde a un contenedor que sabemos abrir. Los
    /// volúmenes de continuación ("nombre_001.zip") conservan la extensión, así que
    /// también casan aquí.
    func isOpenableArchive(_ url: URL) -> Bool {
        hasArchiveSuffix(url.lastPathComponent.lowercased())
    }

    private func hasArchiveSuffix(_ name: String) -> Bool {
        name.hasSuffix(".zip") || name.hasSuffix(".tar")
            || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".gz")
            || name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") || name.hasSuffix(".xz")
            || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") || name.hasSuffix(".bz2")
            || name.hasSuffix(".7z") || name.hasSuffix(".rar") || name.hasSuffix(".iso") || name.hasSuffix(".cpio")
            || name.hasSuffix(".xar") || name.hasSuffix(".pkg") || name.hasSuffix(".lha") || name.hasSuffix(".lzh") || name.hasSuffix(".cab")
    }

    /// Volúmenes que forman el archivo, en orden (nombre.zip, nombre_001.zip…). Si
    /// `url` no forma parte de un juego, devuelve `[url]`.
    private func volumeParts(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        // ¿Es un volumen de continuación cuyo nombre base existe?
        if let cont = Volumes.continuationVolume(url.lastPathComponent) {
            let baseURL = directory.appendingPathComponent(cont.base)
            if FileManager.default.fileExists(atPath: baseURL.path) {
                return gatherVolumes(base: baseURL)
            }
            return [url]   // sin fichero base: tratar como fichero suelto
        }
        // ¿Es la primera parte (existe nombre_001.<ext>)?
        let secondPart = directory.appendingPathComponent(
            Volumes.partName(base: url.lastPathComponent, index: 2))
        if FileManager.default.fileExists(atPath: secondPart.path) {
            return gatherVolumes(base: url)
        }
        return [url]
    }

    /// Reúne las partes contiguas a partir del volumen base.
    private func gatherVolumes(base: URL) -> [URL] {
        let directory = base.deletingLastPathComponent()
        var parts = [base]
        var index = 2
        while true {
            let part = directory.appendingPathComponent(
                Volumes.partName(base: base.lastPathComponent, index: index))
            guard FileManager.default.fileExists(atPath: part.path) else { break }
            parts.append(part)
            index += 1
        }
        return parts
    }

    /// Formato deducido del nombre del fichero (refinado al leer para `.gz`/`.xz`).
    private func detectFormat(for url: URL) -> ArchiveFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGzip }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") || name.hasSuffix(".tbz2") { return .tarBzip2 }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".gz") { return .gzip }
        if name.hasSuffix(".xz") { return .xz }
        if name.hasSuffix(".bz2") { return .bzip2 }
        if name.hasSuffix(".7z") { return .sevenZip }
        if name.hasSuffix(".rar") { return .rar }
        if name.hasSuffix(".iso") { return .iso }
        if name.hasSuffix(".cpio") { return .cpio }
        if name.hasSuffix(".xar") || name.hasSuffix(".pkg") { return .xar }
        if name.hasSuffix(".lha") || name.hasSuffix(".lzh") { return .lha }
        if name.hasSuffix(".cab") { return .cab }
        return .zip
    }

    /// `true` si `data` empieza con la firma ustar (es un TAR).
    nonisolated private static func isUstar(_ data: Data) -> Bool {
        guard data.count >= 263 else { return false }
        return Array(data[257..<262]) == Array("ustar".utf8)
    }

    /// El documento es un único fichero (apto para guardar como `.gz`).
    var isSingleFile: Bool { roots.count == 1 && !roots[0].isDirectory }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Reporter `@Sendable` para actualizar la barra de progreso desde tareas en
    /// segundo plano sin capturar `self` directamente en el código concurrente.
    private func makeProgressReporter() -> @Sendable (Double) -> Void {
        { fraction in
            Task { @MainActor in self.progress?.fraction = fraction }
        }
    }

    /// Las mutaciones tocan nodos (clases); subir `revision` (publicado) avisa a
    /// SwiftUI y le dice a la vista de lista que debe recargar.
    private func changed() { revision &+= 1 }

    /// Como `changed()`, pero además marca el documento con cambios sin guardar.
    private func markChanged() {
        hasUnsavedChanges = true
        changed()
    }
}

/// Instantánea inmutable y `Sendable` de un nodo para poder extraerlo en segundo
/// plano (al soltar en el Finder) sin acceder al documento, que es `@MainActor`.
struct ExportPlan: Sendable {
    let name: String
    let payload: Payload

    enum Payload: Sendable {
        case folder([ExportPlan])
        case diskFile(URL)
        case archiveEntry(entry: ArchiveEntry, archive: Data, password: String?, format: ArchiveFormat)
    }

    nonisolated var isDirectory: Bool {
        if case .folder = payload { return true }
        return false
    }

    /// Extrae el contenido a una carpeta temporal y devuelve la URL resultante.
    nonisolated func materialize() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CifradorExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(name)
        try writeContents(to: destination)
        return destination
    }

    /// Número de ficheros (hojas) que contiene, para calcular el progreso.
    nonisolated func fileCount() -> Int {
        switch payload {
        case .folder(let children): return children.reduce(0) { $0 + $1.fileCount() }
        case .diskFile, .archiveEntry: return 1
        }
    }

    /// Escribe el contenido en la ruta `destination` (nombre final incluido).
    /// Llama a `onFile` tras escribir cada fichero (para reportar progreso).
    nonisolated func writeContents(to destination: URL, onFile: () -> Void = {}) throws {
        switch payload {
        case .folder(let children):
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in children {
                try child.writeContents(to: destination.appendingPathComponent(child.name), onFile: onFile)
            }
        case .diskFile(let url):
            try FileManager.default.copyItem(at: url, to: destination)
            onFile()
        case .archiveEntry(let entry, let archive, let password, let format):
            let data: Data
            switch format {
            case .zip: data = try ZipExtractor().extractedData(for: entry, in: archive, password: password)
            case .tar, .tarGzip, .tarXz, .tarBzip2: data = try Tar.entryData(for: entry, in: archive)
            case .gzip: data = try Gzip.decompress(archive)
            case .xz: data = try Xz.decompress(archive)
            case .bzip2: data = try Bzip2.decompress(archive)
            case .sevenZip, .rar, .iso, .cpio, .xar, .lha, .cab:
                data = try LibArchive.extractEntry(path: entry.path, in: archive, passphrase: password)
            }
            try data.write(to: destination, options: .atomic)
            onFile()
        }
    }
}

/// Estado de una operación larga (comprimir/extraer) para la barra de progreso.
struct ProgressState {
    var label: String
    var fraction: Double?   // nil = indeterminado
}

