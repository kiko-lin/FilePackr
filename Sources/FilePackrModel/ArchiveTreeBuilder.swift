import Foundation
import ArchiveBrowser

/// Construcción del árbol de `FileNode`: desde las entradas de un archivo abierto
/// (`build(from:)`) y desde un elemento del disco al añadirlo (`importFromDisk`). Es lógica
/// pura, sin estado del documento, extraída de `ArchiveDocument`.
enum ArchiveTreeBuilder {

    /// Árbol de nodos a partir de las entradas de un archivo abierto. Reconstruye la jerarquía
    /// por las rutas de las entradas (ordenadas), creando las carpetas intermedias que falten.
    static func build(from entries: [ArchiveEntry]) -> [FileNode] {
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
    static func importFromDisk(_ url: URL, hiddenPolicy: AddHiddenPolicy) -> (node: FileNode, excluded: Int) {
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

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
