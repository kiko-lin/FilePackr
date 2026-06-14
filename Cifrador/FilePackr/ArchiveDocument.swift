import Foundation
import Combine
import UniformTypeIdentifiers
import ArchiveBrowser
import CryptoCore

/// Origen del contenido de un nodo del árbol.
enum NodeSource {
    case folder                   // carpeta (puede contener hijos)
    case diskFile(URL)            // fichero nuevo que vive en disco, aún sin comprimir
    case zipEntry(ArchiveEntry)   // entrada que proviene de un ZIP abierto
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
        if isDirectory { return "Carpeta" }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
            return desc.prefix(1).uppercased() + desc.dropFirst()
        }
        return ext.isEmpty ? "Documento" : "Documento \(ext.uppercased())"
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
    /// El documento está protegido con contraseña (se abrió o se guardó cifrado).
    @Published private(set) var isEncrypted = false

    static let untitledName = "Sin título"
    static let encryptedExtension = "fpkz"

    private(set) var sourceArchiveData: Data?
    /// Contraseña en memoria para volver a cifrar al guardar sin volver a pedirla.
    private var encryptionPassword: String?

    private let writer = ZipWriter()
    private let crypto = CryptoCore()

    var isEmpty: Bool { roots.isEmpty }

    // MARK: - Entrada de elementos (arrastre o botón Añadir)

    /// Decide qué hacer con lo que llega: abrir un ZIP como base o añadir ficheros.
    func handleIncoming(_ urls: [URL]) async throws {
        let cleaned = urls.filter { $0.isFileURL }
        guard !cleaned.isEmpty else { return }

        if isEmpty, cleaned.count == 1, isZip(cleaned[0]), !isDirectory(cleaned[0]) {
            try await openArchive(cleaned[0])
        } else {
            if isEmpty { beginNewDocument() }
            addFiles(cleaned)
        }
    }

    /// Abre un ZIP existente y muestra su contenido (sin descomprimirlo). La lectura
    /// y el parseo del índice van en segundo plano para no bloquear la interfaz.
    func openArchive(_ url: URL) async throws {
        progress = ProgressState(label: "Abriendo \(url.lastPathComponent)…", fraction: 0)
        defer { progress = nil }

        let result = try await Task.detached(priority: .userInitiated) { [weak self] () -> (Data, [ArchiveEntry]) in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            var lastReported = 0.0
            let entries = try ZipReader().listEntries(in: data) { fraction in
                // Limitamos los saltos a la UI (cada ~1%) para no inundar el hilo principal.
                if fraction - lastReported >= 0.01 || fraction >= 1 {
                    lastReported = fraction
                    Task { @MainActor in self?.progress?.fraction = fraction }
                }
            }
            return (data, entries)
        }.value

        sourceArchiveData = result.0
        roots = buildTree(from: result.1)
        selection = nil
        sourceURL = url
        documentName = url.lastPathComponent
        isEncrypted = false
        encryptionPassword = nil
        hasUnsavedChanges = false
        changed()
    }

    /// `true` si el fichero está cifrado por FilePackr (extensión `.fpkz` o cabecera CIFR).
    func isEncryptedFile(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == Self.encryptedExtension { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        return magic.map { Array($0) == Array("CIFR".utf8) } ?? false
    }

    /// Abre un archivo cifrado: descifra (en segundo plano) y muestra su contenido.
    func openEncrypted(_ url: URL, password: String) async throws {
        let container = try Data(contentsOf: url)
        progress = ProgressState(label: "Descifrando…", fraction: nil)
        defer { progress = nil }

        let crypto = self.crypto
        let result = try await Task.detached(priority: .userInitiated) { () -> (Data, [ArchiveEntry]) in
            let zipData = try crypto.decrypt(container, password: password)
            return (zipData, try ZipReader().listEntries(in: zipData))
        }.value

        sourceArchiveData = result.0
        roots = buildTree(from: result.1)
        selection = nil
        sourceURL = url
        documentName = url.lastPathComponent
        isEncrypted = true
        encryptionPassword = password
        hasUnsavedChanges = false
        changed()
    }

    /// Empieza un documento nuevo, aún sin guardar.
    func beginNewDocument() {
        sourceURL = nil
        documentName = Self.untitledName
        hasUnsavedChanges = false
        isEncrypted = false
        encryptionPassword = nil
    }

    /// Añade ficheros/carpetas del disco dentro de la carpeta destino actual.
    func addFiles(_ urls: [URL]) {
        addFiles(urls, into: destinationFolderForAdding())
    }

    /// Añade ficheros/carpetas del disco dentro de `target` (o la raíz si es `nil`).
    func addFiles(_ urls: [URL], into target: FileNode?) {
        if documentName.isEmpty { beginNewDocument() }
        for url in urls {
            let node = importFromDisk(url)
            insert(node, into: target)
        }
        markChanged()
    }

    // MARK: - Acciones de la barra superior

    func createFolder() {
        if documentName.isEmpty { beginNewDocument() }
        let parent = folderForNewFolder()
        let siblings = parent?.children ?? roots
        let name = uniqueName("Nueva carpeta", among: siblings)
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
        remove(node)
        if selection == node.id { selection = nil }
        markChanged()
    }

    /// Renombra un nodo. Ignora si el nombre está vacío o ya existe entre hermanos.
    func rename(_ node: FileNode, to newName: String) {
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
        guard !isSelfOrDescendant(target, of: node) else { return }
        let destination = target?.children ?? roots
        guard !destination.contains(where: { $0.name == node.name }) else { return }
        remove(node)
        insert(node, into: target)
        markChanged()
    }

    /// `true` si `node` puede moverse a `target` (no a sí mismo ni a un descendiente).
    func canMove(_ node: FileNode, into target: FileNode?) -> Bool {
        !isSelfOrDescendant(target, of: node)
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
        isEncrypted = false
        encryptionPassword = nil
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
        progress = ProgressState(label: "Extrayendo…", fraction: 0)
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
            return ExportPlan(name: node.name, payload: .zipEntry(entry: entry, archive: sourceArchiveData ?? Data()))
        case .folder:
            return ExportPlan(name: node.name, payload: .folder([]))
        }
    }

    /// Guarda el ZIP en `url`, en **streaming a disco** (sin cargarlo entero en
    /// memoria) y en segundo plano con progreso. Si es cifrado, re-cifra.
    func save(to url: URL) async throws {
        if isEncrypted, let password = encryptionPassword {
            try await saveEncrypted(to: url, password: password)
            return
        }
        let inputs = makeSaveInputs()
        progress = ProgressState(label: "Comprimiendo \(documentName)…", fraction: 0)
        defer { progress = nil }
        try await streamZip(inputs, to: url, writer: writer)
        markSaved(as: url)
    }

    /// Comprime y cifra el archivo en `url`. El cifrado necesita los bytes en
    /// memoria, así que aquí no hay streaming (construye y luego cifra).
    func saveEncrypted(to url: URL, password: String) async throws {
        let inputs = makeSaveInputs()
        progress = ProgressState(label: "Cifrando \(documentName)…", fraction: 0)
        defer { progress = nil }

        let zipData = try await buildZipData(inputs, writer: writer)
        await MainActor.run { progress?.fraction = nil } // cifrado: indeterminado

        let crypto = self.crypto
        let container = try await Task.detached(priority: .userInitiated) {
            try crypto.encrypt(zipData, password: password)
        }.value

        try container.write(to: url, options: .atomic)
        isEncrypted = true
        encryptionPassword = password
        markSaved(as: url)
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
                } else if case .zipEntry(let entry) = node.source, let archive = sourceArchiveData,
                          let raw = try? extractor.rawCompressedData(for: entry, in: archive) {
                    items.append(ZipEntryInput(path: path, modifiedAt: entry.modificationDate,
                        source: .rawEntry(method: entry.compressionMethod, crc32: entry.crc32,
                                          compressed: raw, uncompressedSize: entry.uncompressedSize)))
                }
            }
        }
        walk(roots, prefix: "")
        return items
    }

    nonisolated private func streamZip(_ inputs: [ZipEntryInput], to url: URL, writer: ZipWriter) async throws {
        try await Task.detached(priority: .userInitiated) {
            // Escribe a un temporal y luego reemplaza, para no dejar a medias el destino.
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).filepackr.tmp")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try writer.write(inputs, to: handle) { fraction in
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

    nonisolated private func buildZipData(_ inputs: [ZipEntryInput], writer: ZipWriter) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try writer.build(inputs) { fraction in
                Task { @MainActor in self.progress?.fraction = fraction }
            }
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
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
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

    private func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
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
        case zipEntry(entry: ArchiveEntry, archive: Data)
    }

    var isDirectory: Bool {
        if case .folder = payload { return true }
        return false
    }

    /// Extrae el contenido a una carpeta temporal y devuelve la URL resultante.
    func materialize() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CifradorExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(name)
        try writeContents(to: destination)
        return destination
    }

    /// Número de ficheros (hojas) que contiene, para calcular el progreso.
    func fileCount() -> Int {
        switch payload {
        case .folder(let children): return children.reduce(0) { $0 + $1.fileCount() }
        case .diskFile, .zipEntry: return 1
        }
    }

    /// Escribe el contenido en la ruta `destination` (nombre final incluido).
    /// Llama a `onFile` tras escribir cada fichero (para reportar progreso).
    func writeContents(to destination: URL, onFile: () -> Void = {}) throws {
        switch payload {
        case .folder(let children):
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in children {
                try child.writeContents(to: destination.appendingPathComponent(child.name), onFile: onFile)
            }
        case .diskFile(let url):
            try FileManager.default.copyItem(at: url, to: destination)
            onFile()
        case .zipEntry(let entry, let archive):
            let data = try ZipExtractor().extractedData(for: entry, in: archive)
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

