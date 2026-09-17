import Foundation

/// Operaciones de **volúmenes sobre disco**: descubrir las partes de un juego, trocear
/// un fichero ya escrito y limpiar restos. Se apoya en el esquema de nombres de
/// `Volumes` (`nombre.zip`, `nombre_001.zip`…). Aparte del troceo por bytes en memoria
/// (`Volumes.split`/`join`), aquí está la fontanería que toca el sistema de ficheros.
public enum VolumeStore {

    /// Volúmenes que forman el archivo en `url`, en orden (`nombre.zip`, `nombre_001.zip`…).
    /// Si `url` no forma parte de un juego, devuelve `[url]`.
    public static func parts(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        // ¿Es un volumen de continuación cuyo nombre base existe?
        if let cont = Volumes.continuationVolume(url.lastPathComponent) {
            let baseURL = directory.appendingPathComponent(cont.base)
            if FileManager.default.fileExists(atPath: baseURL.path) {
                return gather(base: baseURL)
            }
            return [url]   // sin fichero base: tratar como fichero suelto
        }
        // ¿Es la primera parte (existe nombre_001.<ext>)?
        let secondPart = directory.appendingPathComponent(
            Volumes.partName(base: url.lastPathComponent, index: 2))
        if FileManager.default.fileExists(atPath: secondPart.path) {
            return gather(base: url)
        }
        return [url]
    }

    /// Reúne las partes contiguas a partir del volumen base.
    public static func gather(base: URL) -> [URL] {
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

    /// Concatena las `parts` en un fichero temporal y devuelve su URL, sin mantener
    /// todas las partes en memoria a la vez (al contrario que `Volumes.join`, que
    /// construye un `Data` con el archivo entero). Cada parte se mapea y se escribe en
    /// streaming. El llamante es responsable de borrar el temporal al cerrar.
    public static func joinToTemporaryFile(_ parts: [URL]) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePackrJoin-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            for part in parts {
                try handle.write(contentsOf: try Data(contentsOf: part, options: .alwaysMapped))   // .mappedIfSafe copia a RAM en discos externos
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return temp
    }

    /// Borra los volúmenes de continuación (`nombre_001.zip`…) junto al fichero base.
    public static func removeContinuations(of base: URL) {
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

    /// Divide `source` en volúmenes `nombre.zip`, `nombre_001.zip`… de `volumeSize`
    /// bytes, leyendo por trozos (sin cargar todo en memoria). Borra volúmenes de
    /// continuación sobrantes de un guardado anterior con más partes.
    public static func split(file source: URL, base: URL, volumeSize: Int) async throws {
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
}
