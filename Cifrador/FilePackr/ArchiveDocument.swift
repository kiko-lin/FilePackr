import Foundation
import Combine
import UniformTypeIdentifiers
import ArchiveBrowser

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

    static let untitledName = "Sin título"

    private(set) var sourceArchiveData: Data?

    private let reader = ZipReader()
    private let extractor = ZipExtractor()
    private let writer = ZipWriter()

    var isEmpty: Bool { roots.isEmpty }

    // MARK: - Entrada de elementos (arrastre o botón Añadir)

    /// Decide qué hacer con lo que llega: abrir un ZIP como base o añadir ficheros.
    func handleIncoming(_ urls: [URL]) throws {
        let cleaned = urls.filter { $0.isFileURL }
        guard !cleaned.isEmpty else { return }

        if isEmpty, cleaned.count == 1, isZip(cleaned[0]), !isDirectory(cleaned[0]) {
            try openArchive(cleaned[0])
        } else {
            if isEmpty { beginNewDocument() }
            addFiles(cleaned)
        }
    }

    /// Abre un ZIP existente y muestra su contenido (sin descomprimirlo).
    func openArchive(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try reader.listEntries(in: data)
        sourceArchiveData = data
        roots = buildTree(from: entries)
        selection = nil
        sourceURL = url
        documentName = url.lastPathComponent
        hasUnsavedChanges = false
        changed()
    }

    /// Empieza un documento nuevo, aún sin guardar.
    func beginNewDocument() {
        sourceURL = nil
        documentName = Self.untitledName
        hasUnsavedChanges = false
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
        changed()
    }

    /// Marca el documento como guardado en `url` (actualiza nombre y origen).
    func markSaved(as url: URL) {
        sourceURL = url
        documentName = url.lastPathComponent
        hasUnsavedChanges = false
        changed()
    }

    /// Escribe un plan en una ruta destino concreta, opcionalmente sobrescribiendo.
    func performExtraction(of plan: ExportPlan, to destination: URL, overwrite: Bool) throws {
        if overwrite, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try plan.writeContents(to: destination)
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

    /// Construye y guarda el ZIP final en `url`.
    func save(to url: URL) throws {
        var items: [ZipWriteItem] = []
        try collect(roots, prefix: "", into: &items)
        let data = writer.build(items)
        try data.write(to: url, options: .atomic)
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

    private func collect(_ nodes: [FileNode], prefix: String, into items: inout [ZipWriteItem]) throws {
        for node in nodes {
            let path = prefix + node.name
            if node.isDirectory {
                items.append(.directory(path: path + "/", modifiedAt: node.modificationDate))
                try collect(node.children, prefix: path + "/", into: &items)
            } else {
                switch node.source {
                case .diskFile(let url):
                    items.append(.file(path: path, data: try Data(contentsOf: url),
                                       modifiedAt: node.modificationDate))
                case .zipEntry(let entry):
                    if let archive = sourceArchiveData {
                        let raw = try extractor.rawCompressedData(for: entry, in: archive)
                        items.append(.rawEntry(path: path, method: entry.compressionMethod,
                                               crc32: entry.crc32, compressed: raw,
                                               uncompressedSize: entry.uncompressedSize,
                                               modifiedAt: entry.modificationDate))
                    }
                case .folder:
                    break
                }
            }
        }
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

    /// Escribe el contenido en la ruta `destination` (nombre final incluido).
    func writeContents(to destination: URL) throws {
        switch payload {
        case .folder(let children):
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in children {
                try child.writeContents(to: destination.appendingPathComponent(child.name))
            }
        case .diskFile(let url):
            try FileManager.default.copyItem(at: url, to: destination)
        case .zipEntry(let entry, let archive):
            let data = try ZipExtractor().extractedData(for: entry, in: archive)
            try data.write(to: destination, options: .atomic)
        }
    }
}
