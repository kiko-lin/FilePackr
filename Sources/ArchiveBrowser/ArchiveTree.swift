import Foundation

/// Nodo de árbol para mostrar el contenido de un archivo en una sidebar tipo Finder.
public final class ArchiveTreeNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    public let fullPath: String
    public let isDirectory: Bool
    /// Entrada real del ZIP, sólo presente en ficheros (las carpetas intermedias
    /// pueden no existir como entrada propia dentro del ZIP).
    public internal(set) var entry: ArchiveEntry?
    public internal(set) var children: [ArchiveTreeNode]

    init(name: String, fullPath: String, isDirectory: Bool,
         entry: ArchiveEntry? = nil, children: [ArchiveTreeNode] = []) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.entry = entry
        self.children = children
    }
}

public extension ArchiveTreeNode {
    /// Construye el árbol de carpetas/ficheros a partir de la lista plana de entradas.
    /// Crea carpetas intermedias aunque el ZIP no las declare como entrada propia.
    static func build(from entries: [ArchiveEntry]) -> [ArchiveTreeNode] {
        let root = ArchiveTreeNode(name: "", fullPath: "", isDirectory: true)
        var index: [String: ArchiveTreeNode] = ["": root]

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }

            var parent = root
            var accumulated = ""
            for (i, component) in components.enumerated() {
                let isLast = i == components.count - 1
                accumulated = accumulated.isEmpty ? component : "\(accumulated)/\(component)"
                let isDir = !isLast || entry.isDirectory

                if let existing = index[accumulated] {
                    // Una carpeta intermedia creada antes ahora aparece como entrada real.
                    if isLast, !entry.isDirectory { existing.entry = entry }
                    parent = existing
                    continue
                }

                let node = ArchiveTreeNode(
                    name: component,
                    fullPath: accumulated,
                    isDirectory: isDir,
                    entry: (isLast && !entry.isDirectory) ? entry : nil
                )
                parent.children.append(node)
                index[accumulated] = node
                parent = node
            }
        }
        return root.children
    }
}
