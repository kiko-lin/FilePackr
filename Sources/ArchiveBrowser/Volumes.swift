import Foundation

/// División de un archivo en **volúmenes** por bytes. La primera parte conserva el
/// nombre base ("nombre.zip") y las siguientes llevan un sufijo numérico antes de la
/// extensión ("nombre_001.zip", "nombre_002.zip"…). Los volúmenes se concatenan en
/// orden para reconstruir el archivo original.
public enum Volumes {

    /// Nombre del volumen `index` (1-based) para un nombre base "nombre.zip":
    /// índice 1 → "nombre.zip"; 2 → "nombre_001.zip"; 3 → "nombre_002.zip"…
    public static func partName(base: String, index: Int) -> String {
        guard index > 1 else { return base }
        let (stem, ext) = splitExtension(base)
        let suffix = String(format: "_%03d", index - 1)
        return ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
    }

    /// Si `name` es un volumen de continuación ("nombre_001.zip"), devuelve el nombre
    /// base ("nombre.zip") y su índice (≥2). Si no lo es, `nil`.
    public static func continuationVolume(_ name: String) -> (base: String, index: Int)? {
        let (stem, ext) = splitExtension(name)
        guard let range = stem.range(of: "_[0-9]+$", options: .regularExpression),
              let number = Int(stem[range].dropFirst()) else { return nil }
        let baseStem = String(stem[..<range.lowerBound])
        guard !baseStem.isEmpty else { return nil }
        let base = ext.isEmpty ? baseStem : baseStem + "." + ext
        return (base, number + 1)   // "_001" → índice 2
    }

    /// Divide `data` en trozos de como mucho `volumeSize` bytes (el último, menor o
    /// igual). Si no hace falta dividir, devuelve `[data]`.
    public static func split(_ data: Data, volumeSize: Int) -> [Data] {
        guard volumeSize > 0, data.count > volumeSize else { return [data] }
        var parts: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + volumeSize, data.count)
            parts.append(data.subdata(in: offset..<end))
            offset = end
        }
        return parts
    }

    /// Une los volúmenes (en orden) en un único bloque.
    public static func join(_ parts: [Data]) -> Data {
        var out = Data()
        for part in parts { out.append(part) }
        return out
    }

    /// Separa nombre en (raíz, extensión), tratando ".tar.gz" como extensión compuesta.
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        for compound in ["tar.gz"] where lower.hasSuffix("." + compound) {
            return (String(name.dropLast(compound.count + 1)), String(name.suffix(compound.count)))
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return (String(name[..<dot]), String(name[name.index(after: dot)...]))
        }
        return (name, "")
    }
}
