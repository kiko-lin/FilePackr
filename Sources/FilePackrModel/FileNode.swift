import Foundation
import ArchiveBrowser

/// Origen del contenido de un nodo del árbol.
public enum NodeSource {
    case folder                // carpeta (puede contener hijos)
    case diskFile(URL)         // fichero nuevo que vive en disco, aún sin comprimir
    case entry(ArchiveEntry)   // entrada que proviene de un archivo abierto (cualquier formato)
}

/// Nodo del árbol editable que se muestra en el cuerpo central.
public final class FileNode: Identifiable {
    public let id = UUID()
    public var name: String
    public let isDirectory: Bool
    public var source: NodeSource
    public var children: [FileNode]
    weak public var parent: FileNode?
    /// Fecha que trae la entrada del archivo abierto (ficheros y carpetas). `nil` si no
    /// procede de un archivo abierto.
    public var entryDate: Date?

    public init(name: String, isDirectory: Bool, source: NodeSource, children: [FileNode] = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.source = source
        self.children = children
    }

    /// `nil` en ficheros (para que la lista no muestre flecha de despliegue),
    /// la lista de hijos en carpetas.
    public var childrenOrNil: [FileNode]? { isDirectory ? children : nil }

    /// Tamaño real (descomprimido). Carpetas: nil.
    public var fileSize: UInt64? {
        guard !isDirectory else { return nil }
        switch source {
        case .entry(let e): return e.uncompressedSize
        case .diskFile(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size.map(UInt64.init)
        case .folder: return nil
        }
    }

    /// Tamaño comprimido dentro del archivo (solo se conoce para entradas de un archivo abierto).
    public var compressedSize: UInt64? {
        if case .entry(let e) = source, !isDirectory { return e.compressedSize }
        return nil
    }

    /// Fecha de modificación: del ZIP, del disco (ficheros nuevos) o, para carpetas
    /// sin fecha propia (zips sin entrada de carpeta), la del contenido más reciente.
    public var modificationDate: Date? {
        if let entryDate { return entryDate }
        if case .diskFile(let url) = source {
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        if isDirectory {
            return children.compactMap(\.modificationDate).max()
        }
        return nil
    }

    /// Ruta completa "carpeta/subcarpeta/nombre" para mostrar en menús.
    public var pathLabel: String {
        var parts = [name]
        var ancestor = parent
        while let current = ancestor {
            parts.insert(current.name, at: 0)
            ancestor = current.parent
        }
        return parts.joined(separator: "/")
    }
}
