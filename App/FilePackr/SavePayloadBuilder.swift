import Foundation
import ArchiveBrowser

/// Ensambla el `SavePayload` (`Sendable`) que el `ArchiveSaver` escribe a disco, leyendo
/// el árbol de nodos del documento. Separa el *qué* escribir (recorrer el árbol y
/// reconstruir el contenido según el formato de salida) del *cómo* codificarlo
/// (`ArchiveSaver`) y de la orquestación de E/S y estado (`ArchiveDocument`).
///
/// Es código puro de serialización: entra un árbol de `FileNode` más el origen del
/// archivo abierto, sale una estructura `Sendable`. No toca el estado del documento.
struct SavePayloadBuilder {
    /// Raíces del árbol a serializar.
    let roots: [FileNode]
    /// Nombre del documento (lo usa gzip como nombre interno del fichero).
    let documentName: String
    /// Formato del archivo de origen (para leer las entradas de los nodos `.zipEntry`).
    let sourceFormat: ArchiveFormat
    /// Bytes del archivo de origen, si se abrió uno (para reconstruir entradas).
    let sourceArchiveData: Data?
    /// Contraseña de las entradas cifradas del archivo de origen.
    let entryPassword: String?

    /// Ensambla el payload para el formato de salida. Lanza para formatos de solo
    /// lectura o si un formato de un solo fichero no tiene contenido.
    func payload(for outputFormat: ArchiveFormat,
                 encryption: ZipEncryption, password: String?) throws -> SavePayload {
        switch outputFormat {
        case .zip:
            return .zip(inputs: zipInputs(), encryption: encryption, password: password)
        case .tar:
            let items = tarItems()
            return .stream { handle in
                let next = Tar.reader(items)
                while let chunk = try next() { try handle.write(contentsOf: chunk) }
            }
        case .tarGzip:
            let items = tarItems()
            let name = documentName.isEmpty ? nil : documentName
            return .stream { handle in
                try Gzip.compress(next: Tar.reader(items), sink: { try handle.write(contentsOf: $0) }, filename: name)
            }
        case .tarXz:
            let items = tarItems()
            return .stream { handle in
                try Xz.compress(next: Tar.reader(items), sink: { try handle.write(contentsOf: $0) })
            }
        case .tarBzip2:
            let items = tarItems()
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
            return .libArchive(items: libArchiveItems(), format: writeFormat)
        case .rar, .cpio, .lha, .cab:
            throw CocoaError(.fileWriteUnsupportedScheme)   // formatos de solo lectura
        }
    }

    // MARK: - Recorrido del árbol

    /// Recorre el árbol en preorden invocando `visit(node, path)` por cada nodo (la ruta
    /// arrastra el prefijo de carpetas). Centraliza la recursión que antes se repetía
    /// idéntica en cada constructor de items.
    private func walk(_ nodes: [FileNode], prefix: String, _ visit: (FileNode, String) -> Void) {
        for node in nodes {
            let path = prefix + node.name
            visit(node, path)
            if node.isDirectory { walk(node.children, prefix: path + "/", visit) }
        }
    }

    /// Datos sin comprimir de un nodo, leídos según el formato del archivo de origen.
    /// Sirve para reconstruir el contenido al guardar en otro formato.
    private func nodeData(_ node: FileNode) -> Data? {
        switch node.source {
        case .folder: return nil
        case .diskFile(let url): return try? Data(contentsOf: url)
        case .zipEntry(let entry):
            guard let archive = sourceArchiveData else { return nil }
            return try? sourceFormat.codec.entryData(for: entry, in: archive, password: entryPassword)
        }
    }

    // MARK: - Constructores de items por familia de formato

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

    /// Entradas para escribir un TAR. Los ficheros de disco van como **URL** (se leen al
    /// vuelo al escribir, sin cargarlos en RAM); las entradas de un archivo ya abierto van
    /// como bytes (reconstruidos en memoria, que es donde están).
    private func tarItems() -> [Tar.WriteItem] {
        var items: [Tar.WriteItem] = []
        walk(roots, prefix: "") { node, path in
            if node.isDirectory {
                items.append(Tar.WriteItem(path: path + "/", data: Data(),
                                           modifiedAt: node.modificationDate, isDirectory: true))
            } else if case .diskFile(let url) = node.source {
                items.append(Tar.WriteItem(path: path, fileURL: url, modifiedAt: node.modificationDate))
            } else if let data = nodeData(node) {
                items.append(Tar.WriteItem(path: path, data: data,
                                           modifiedAt: node.modificationDate, isDirectory: false))
            }
        }
        return items
    }

    /// Como `tarItems`, pero para el escritor de 7z/iso/xar de libarchive (las carpetas
    /// no llevan la barra final).
    private func libArchiveItems() -> [LibArchive.WriteItem] {
        var items: [LibArchive.WriteItem] = []
        walk(roots, prefix: "") { node, path in
            if node.isDirectory {
                items.append(LibArchive.WriteItem(path: path, data: Data(),
                                                  modifiedAt: node.modificationDate, isDirectory: true))
            } else if case .diskFile(let url) = node.source {
                items.append(LibArchive.WriteItem(path: path, fileURL: url, modifiedAt: node.modificationDate))
            } else if let data = nodeData(node) {
                items.append(LibArchive.WriteItem(path: path, data: data,
                                                  modifiedAt: node.modificationDate, isDirectory: false))
            }
        }
        return items
    }

    /// Entradas para escribir un ZIP. Es ligero: los ficheros nuevos van como `.file(url)`
    /// (se leen al vuelo) y las entradas de un zip abierto como bytes comprimidos en crudo
    /// (rebanada barata del archivo origen ya mapeado); las cifradas o de otro formato se
    /// reconstruyen a texto claro para que el escritor las (re)comprima limpiamente.
    private func zipInputs() -> [ZipEntryInput] {
        let extractor = ZipExtractor()
        var items: [ZipEntryInput] = []
        walk(roots, prefix: "") { node, path in
            if node.isDirectory {
                items.append(ZipEntryInput(path: path + "/", modifiedAt: node.modificationDate, source: .directory))
            } else if case .diskFile(let url) = node.source {
                items.append(ZipEntryInput(path: path, modifiedAt: node.modificationDate, source: .file(url)))
            } else if case .zipEntry(let entry) = node.source, let archive = sourceArchiveData {
                if sourceFormat != .zip {
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
        return items
    }
}
