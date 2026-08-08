import Foundation

/// Detección de los esquemas de nombres **nativos** de RAR multivolumen (los que crean
/// WinRAR/`rar`, no el propio de FilePackr — ver `Volumes`/`VolumeStore`). A diferencia del
/// esquema propio, estos volúmenes no se pueden unir concatenando bytes: cada uno lleva su
/// propia cabecera intercalada, así que se abren con la API de libarchive para volúmenes
/// (`LibArchive.listEntries(volumes:)`/`extractEntries(volumes:)`).
public enum RarVolumes {

    /// Volúmenes del conjunto al que pertenece `url`, en orden, si `url` es un nombre de
    /// volumen RAR nativo reconocible (moderno `nombre.part1.rar`… o legado `nombre.rar` +
    /// `nombre.r00`…) **y** hay más de una parte presente en disco. `nil` en cualquier otro
    /// caso (incluido: el nombre encaja pero está solo, o no es RAR nativo en absoluto).
    public static func parts(for url: URL) -> [URL]? {
        modernParts(for: url) ?? legacyParts(for: url)
    }

    // MARK: - Moderno: nombre.part1.rar, nombre.part2.rar…

    private static let modernRegex = try! NSRegularExpression(
        pattern: #"^(.*)\.part(\d+)\.rar$"#, options: [.caseInsensitive])

    private static func modernMatch(_ name: String) -> (prefix: String, digits: String)? {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = modernRegex.firstMatch(in: name, options: [], range: range),
              let prefixRange = Range(match.range(at: 1), in: name),
              let digitsRange = Range(match.range(at: 2), in: name) else { return nil }
        return (String(name[prefixRange]), String(name[digitsRange]))
    }

    private static func modernParts(for url: URL) -> [URL]? {
        guard let (prefix, digits) = modernMatch(url.lastPathComponent), let number = Int(digits) else { return nil }
        let directory = url.deletingLastPathComponent()
        let width = digits.count
        let firstURL: URL
        if number == 1 {
            firstURL = url
        } else {
            let candidate = directory.appendingPathComponent(modernName(prefix: prefix, index: 1, width: width))
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            firstURL = candidate
        }
        var result = [firstURL]
        var index = 2
        while true {
            let next = directory.appendingPathComponent(modernName(prefix: prefix, index: index, width: width))
            guard FileManager.default.fileExists(atPath: next.path) else { break }
            result.append(next)
            index += 1
        }
        return result.count > 1 ? result : nil
    }

    private static func modernName(prefix: String, index: Int, width: Int) -> String {
        let number = String(index)
        let padded = number.count < width ? String(repeating: "0", count: width - number.count) + number : number
        return "\(prefix).part\(padded).rar"
    }

    // MARK: - Legado: nombre.rar, nombre.r00, nombre.r01…

    private static let legacyContinuationRegex = try! NSRegularExpression(
        pattern: #"^(.*)\.r(\d{2})$"#, options: [.caseInsensitive])

    private static func legacyParts(for url: URL) -> [URL]? {
        let name = url.lastPathComponent
        let directory = url.deletingLastPathComponent()
        let baseURL: URL
        if name.lowercased().hasSuffix(".rar") {
            baseURL = url
        } else {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = legacyContinuationRegex.firstMatch(in: name, options: [], range: range),
                  let prefixRange = Range(match.range(at: 1), in: name) else { return nil }
            baseURL = directory.appendingPathComponent(String(name[prefixRange]) + ".rar")
            guard FileManager.default.fileExists(atPath: baseURL.path) else { return nil }
        }
        var result = [baseURL]
        var index = 0
        let stem = baseURL.deletingPathExtension().lastPathComponent
        while true {
            let next = directory.appendingPathComponent(stem + String(format: ".r%02d", index))
            guard FileManager.default.fileExists(atPath: next.path) else { break }
            result.append(next)
            index += 1
        }
        return result.count > 1 ? result : nil
    }
}
