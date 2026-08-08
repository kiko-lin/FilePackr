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

    // MARK: - Moderno: nombre.part1.rar, nombre.part2.rar… (WinRAR separa con un punto, pero
    // no es el único: hay "scene releases" que usan guion bajo — `nombre_part1.rar` — y otros
    // extractores (WinRAR incluido) los abren igual, porque lo que de verdad marca el volumen
    // es la cabecera interna (`isMultiVolumePart`), no el separador. No exigimos el punto: lo
    // que haya antes de "part" (incluido nada) se captura entero como prefijo y se reutiliza tal
    // cual al reconstruir los nombres de las siguientes partes, así el separador real (el que
    // sea) se conserva.
    private static let modernRegex = try! NSRegularExpression(
        pattern: #"^(.*)part(\d+)\.rar$"#, options: [.caseInsensitive])

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
        return "\(prefix)part\(padded).rar"
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

    // MARK: - ¿Es este archivo parte de un conjunto multivolumen?

    private static let rar4Marker: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    private static let rar5Marker: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    /// `true` si la cabecera del propio archivo (`MAIN_HEAD`, bit `MHD_VOLUME`) declara que es
    /// parte de un conjunto multivolumen — independiente del nombre del fichero. Sirve para
    /// distinguir "esto es un RAR suelto y roto" de "esto es un RAR suelto al que le faltan sus
    /// hermanos" cuando `parts(for:)` no reconoció ningún esquema de nombres (p. ej. el sufijo
    /// " (1)" que añade macOS al duplicar, que no dice nada sobre volúmenes de RAR). Nunca lanza:
    /// ante cualquier dato truncado o inesperado, devuelve `false` — no arriesgarse a un falso aviso.
    public static func isMultiVolumePart(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64))
        if bytes.starts(with: rar5Marker) { return isMultiVolumePartRAR5(bytes) }
        if bytes.starts(with: rar4Marker) { return isMultiVolumePartRAR4(bytes) }
        return false
    }

    /// RAR4: marcador(7) + `HEAD_CRC`(2) + `HEAD_TYPE`(1) + `HEAD_FLAGS`(2, LE) — offsets fijos,
    /// sin vint. `HEAD_TYPE` 0x73 = `MAIN_HEAD`; bit 0x0001 de `HEAD_FLAGS` = `MHD_VOLUME`.
    private static func isMultiVolumePartRAR4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, bytes[9] == 0x73 else { return false }
        let flags = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
        return flags & 0x0001 != 0
    }

    /// RAR5: marcador(8) + CRC32(4) + vint `HeaderSize` + vint `HeaderType`(1=principal) + vint
    /// `HeaderFlags` + [vint `ExtraAreaSize` si `HeaderFlags`&1] + vint `ArchiveFlags` — bit
    /// 0x0001 de `ArchiveFlags` es el equivalente de `MHD_VOLUME`.
    private static func isMultiVolumePartRAR5(_ bytes: [UInt8]) -> Bool {
        var off = 8 + 4
        guard readVint(bytes, &off) != nil else { return false }               // HeaderSize
        guard let headerType = readVint(bytes, &off), headerType == 1 else { return false }
        guard let headerFlags = readVint(bytes, &off) else { return false }
        if headerFlags & 0x0001 != 0 {
            guard readVint(bytes, &off) != nil else { return false }           // ExtraAreaSize
        }
        guard let archiveFlags = readVint(bytes, &off) else { return false }
        return archiveFlags & 0x0001 != 0
    }

    /// Vint de RAR5 (7 bits por byte, bit alto = continúa). `nil` si se sale del buffer o el vint
    /// es sospechosamente largo (datos corruptos/adversariales) — nunca bucle infinito.
    private static func readVint(_ bytes: [UInt8], _ off: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var count = 0
        while true {
            guard off < bytes.count, count < 10 else { return nil }
            let b = bytes[off]; off += 1; count += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }
}
