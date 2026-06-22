import Foundation
import ArchiveBrowser

/// Origen del contenido de un nodo del árbol.
enum NodeSource {
    case folder                // carpeta (puede contener hijos)
    case diskFile(URL)         // fichero nuevo que vive en disco, aún sin comprimir
    case entry(ArchiveEntry)   // entrada que proviene de un archivo abierto (cualquier formato)
}

/// Nodo del árbol editable que se muestra en el cuerpo central.
final class FileNode: Identifiable {
    let id = UUID()
    var name: String
    let isDirectory: Bool
    var source: NodeSource
    var children: [FileNode]
    weak var parent: FileNode?
    /// Fecha que trae la entrada del archivo abierto (ficheros y carpetas). `nil` si no
    /// procede de un archivo abierto.
    var entryDate: Date?

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
        case .entry(let e): return e.uncompressedSize
        case .diskFile(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size.map(UInt64.init)
        case .folder: return nil
        }
    }

    /// Tamaño comprimido dentro del archivo (solo se conoce para entradas de un archivo abierto).
    var compressedSize: UInt64? {
        if case .entry(let e) = source, !isDirectory { return e.compressedSize }
        return nil
    }

    /// Fecha de modificación: del ZIP, del disco (ficheros nuevos) o, para carpetas
    /// sin fecha propia (zips sin entrada de carpeta), la del contenido más reciente.
    var modificationDate: Date? {
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
