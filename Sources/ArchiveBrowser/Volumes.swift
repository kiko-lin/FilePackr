import Foundation

/// División de un archivo en **volúmenes** por bytes, con la convención de sufijo
/// numérico (`.001`, `.002`, …) que usan 7-Zip y Keka. Es independiente del formato:
/// los volúmenes se concatenan en orden para reconstruir el archivo original.
public enum Volumes {

    /// Sufijo de 3 dígitos del volumen `index` (1-based): 1 → "001", 12 → "012".
    public static func partExtension(_ index: Int) -> String {
        String(format: "%03d", index)
    }

    /// `true` si `ext` es un sufijo de volumen (solo dígitos, no vacío): "001", "2"…
    public static func isPartExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.allSatisfy { $0.isNumber }
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
}
