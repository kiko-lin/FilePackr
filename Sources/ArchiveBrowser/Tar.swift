import Foundation

public enum TarError: Error, Equatable { case corrupt }

/// Lectura/escritura de archivos **TAR** (ustar), el contenedor Unix. Sin compresión
/// (se combina con gzip para `.tar.gz`). Lee ustar, cabeceras extendidas PAX (`x`) y
/// nombres largos GNU (`L`); escribe ustar y emite PAX para rutas que no caben.
public enum Tar {

    private static let blockSize = 512

    // MARK: - Lectura

    /// Lista las entradas del TAR. `dataOffset` apunta a los datos (para extraer). Lee las
    /// cabeceras (512 B dispersas) directamente sobre `data` con índices, sin copiar el
    /// contenedor entero a un `[UInt8]` (importa para un tar.gz de varios GB ya en RAM).
    public static func listEntries(in data: Data) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let base = data.startIndex
        var p = base                       // índice absoluto del bloque de cabecera actual
        var pendingPath: String?
        var pendingSize: UInt64?
        var pendingDate: Date?

        while p + blockSize <= data.endIndex {
            if isZeroBlock(data, at: p) { break }   // dos bloques cero = fin

            let rawName = string(data, p, 100)
            let prefix = string(data, p + 345, 155)
            let size = pendingSize ?? octal(data, p + 124, 12)
            let mtime = pendingDate ?? dateFrom(octal(data, p + 136, 12))
            let type = data[p + 156]
            let dataStart = p + blockSize
            let dataBlocks = (Int(size) + blockSize - 1) / blockSize

            switch type {
            case 0x78, 0x67:   // 'x' / 'g' — cabecera extendida PAX
                let header = parsePax(data, start: dataStart, size: Int(size))
                pendingPath = header.path
                pendingSize = header.size
                pendingDate = header.mtime
                p = dataStart + dataBlocks * blockSize
                continue
            case 0x4C:         // 'L' — nombre largo GNU
                pendingPath = string(data, dataStart, Int(size)).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                p = dataStart + dataBlocks * blockSize
                continue
            default:
                break
            }

            let name = pendingPath ?? (prefix.isEmpty ? rawName : prefix + "/" + rawName)
            pendingPath = nil; pendingSize = nil; pendingDate = nil

            let isDir = type == 0x35 || name.hasSuffix("/")   // '5'
            if type == 0x30 || type == 0x00 || type == 0x35 || isDir {   // ficheros y carpetas
                guard dataStart + Int(size) <= data.endIndex else { throw TarError.corrupt }
                entries.append(ArchiveEntry(
                    path: name, compressedSize: size, uncompressedSize: size,
                    isDirectory: isDir, modificationDate: mtime,
                    isEncrypted: false, dataOffset: UInt64(dataStart - base)))   // offset 0-based para entryData
            }
            p = dataStart + dataBlocks * blockSize
        }
        return entries
    }

    /// Indexador **incremental** del TAR (Fase 1 del streaming de tar comprimido). Se alimenta
    /// con los trozos del flujo descomprimido (`consume`, *push* — encaja con `decompress(_:sink:)`)
    /// y, **sin guardar el contenido de los ficheros** (lo descarta a medida que llega, memoria
    /// acotada), registra las entradas con su `dataOffset` = posición lógica de sus datos en el
    /// flujo descomprimido (mismo valor que `listEntries`, que lo calcula sobre el tar ya en RAM).
    /// Replica la lógica de `listEntries` para producir entradas idénticas.
    public final class StreamIndexer {
        private var buffer = Data()
        private var consumed = 0            // bytes del flujo ya procesados (offset lógico actual)
        private var entries: [ArchiveEntry] = []
        private var pendingPath: String?
        private var pendingSize: UInt64?
        private var pendingDate: Date?
        private var skip = 0               // bytes de contenido de fichero por descartar
        private var finished = false

        public init() {}

        /// Alimenta el siguiente trozo del flujo descomprimido.
        public func consume(_ chunk: Data) { buffer.append(chunk); drain() }

        /// Cierra el flujo y devuelve las entradas indexadas.
        public func finish() -> [ArchiveEntry] { drain(); return entries }

        private func drain() {
            while true {
                if finished { buffer.removeAll(keepingCapacity: false); return }
                if skip > 0 {                                   // descartar contenido de fichero
                    let n = Swift.min(skip, buffer.count)
                    if n > 0 { buffer.removeFirst(n); buffer = Data(buffer); skip -= n; consumed += n }
                    if skip > 0 { return }
                    continue
                }
                guard buffer.count >= blockSize else { return } // necesita una cabecera completa
                let b = buffer.startIndex
                if isZeroBlock(buffer, at: b) { finished = true; continue }

                let size = pendingSize ?? octal(buffer, b + 124, 12)
                let type = buffer[b + 156]
                let dataBlocks = (Int(size) + blockSize - 1) / blockSize

                if type == 0x78 || type == 0x67 || type == 0x4C {   // PAX 'x'/'g' o GNU 'L'
                    let total = blockSize + dataBlocks * blockSize
                    guard buffer.count >= total else { return }     // espera los bloques de metadatos
                    if type == 0x4C {
                        pendingPath = string(buffer, b + blockSize, Int(size))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    } else {
                        let h = parsePax(buffer, start: b + blockSize, size: Int(size))
                        pendingPath = h.path; pendingSize = h.size; pendingDate = h.mtime
                    }
                    buffer.removeFirst(total); buffer = Data(buffer); consumed += total
                    continue
                }

                let rawName = string(buffer, b, 100)
                let prefix = string(buffer, b + 345, 155)
                let mtime = pendingDate ?? dateFrom(octal(buffer, b + 136, 12))
                let name = pendingPath ?? (prefix.isEmpty ? rawName : prefix + "/" + rawName)
                pendingPath = nil; pendingSize = nil; pendingDate = nil

                let isDir = type == 0x35 || name.hasSuffix("/")
                if type == 0x30 || type == 0x00 || type == 0x35 || isDir {
                    entries.append(ArchiveEntry(
                        path: name, compressedSize: size, uncompressedSize: size,
                        isDirectory: isDir, modificationDate: mtime,
                        isEncrypted: false, dataOffset: UInt64(consumed + blockSize)))
                }
                buffer.removeFirst(blockSize); buffer = Data(buffer); consumed += blockSize
                skip = dataBlocks * blockSize
            }
        }
    }

    /// Extracción por offset (Fase 2): emite por `sink` el rango `[offset, offset+length)` del
    /// flujo **descomprimido**, re-descomprimiendo `compressed` con `streamDecompress` (p. ej.
    /// `Gzip.decompress(_:sink:)`) sin materializar el flujo. Descarta hasta `offset` y **para de
    /// descomprimir** en cuanto ha emitido los `length` bytes de la entrada (no infla el resto).
    public static func streamExtract(offset: Int, length: Int,
                                     decompressing compressed: Data,
                                     with streamDecompress: (Data, (Data) throws -> Void) throws -> Void,
                                     sink: @escaping (Data) throws -> Void) throws {
        guard length > 0 else { return }   // carpetas / ficheros vacíos: nada que emitir
        var toSkip = offset
        var toEmit = length
        struct Done: Error {}
        do {
            try streamDecompress(compressed) { chunk in
                var piece = chunk[...]                       // Data.SubSequence == Data
                if toSkip > 0 {
                    let s = Swift.min(toSkip, piece.count)
                    piece = piece.dropFirst(s)
                    toSkip -= s
                }
                if toEmit > 0, !piece.isEmpty {
                    let e = Swift.min(toEmit, piece.count)
                    try sink(Data(piece.prefix(e)))
                    toEmit -= e
                }
                if toEmit == 0 { throw Done() }              // ya tenemos la entrada: cortar
            }
        } catch is Done {}
    }

    /// `true` si `data` empieza con la firma ustar (es un TAR). Sirve para distinguir
    /// un `.gz`/`.xz`/`.bz2` suelto de un `.tar.<x>` tras descomprimir.
    public static func hasUstarMagic(_ data: Data) -> Bool {
        guard data.count >= 263 else { return false }
        let base = data.startIndex
        return data[(base + 257)..<(base + 262)].elementsEqual("ustar".utf8)
    }

    /// Datos (sin comprimir) de una entrada del TAR.
    public static func entryData(for entry: ArchiveEntry, in data: Data) throws -> Data {
        guard let start = entry.dataOffset.map(Int.init) else { throw TarError.corrupt }
        let end = start + Int(entry.uncompressedSize)
        guard end <= data.count else { throw TarError.corrupt }
        return data.subdata(in: start..<end)
    }

    // MARK: - Escritura

    public struct WriteItem: Sendable {
        /// Origen del contenido: bytes ya en memoria, o un fichero de disco (streaming).
        public enum Source: Sendable { case data(Data); case file(URL) }
        public let path: String
        public let source: Source
        public let modifiedAt: Date?
        public let isDirectory: Bool

        public init(path: String, data: Data, modifiedAt: Date?, isDirectory: Bool) {
            self.path = path; self.source = .data(data); self.modifiedAt = modifiedAt; self.isDirectory = isDirectory
        }
        /// Entrada cuyo contenido se leerá del fichero al vuelo (sin cargarlo en RAM).
        public init(path: String, fileURL: URL, modifiedAt: Date?) {
            self.path = path; self.source = .file(fileURL); self.modifiedAt = modifiedAt; self.isDirectory = false
        }
    }

    /// Escribe el TAR completo en memoria. Adaptador del generador `reader` (los ítems en
    /// memoria no cargan nada extra; los de fichero se leerían al vuelo).
    public static func write(_ items: [WriteItem]) -> Data {
        var out = Data()
        let next = reader(items)
        do { while let chunk = try next() { out.append(chunk) } } catch { return out }
        return out
    }

    /// Generador **pull** del flujo TAR: cada llamada devuelve el siguiente trozo (o `nil`
    /// al acabar), leyendo los ficheros de disco por trozos (memoria constante). Encadenable
    /// con el `next` de un compresor para producir `.tar.gz`/`.tar.xz`/`.tar.bz2` sin
    /// montar el TAR entero en RAM.
    public static func reader(_ items: [WriteItem],
                              onProgress: WriteProgress = .none) -> () throws -> Data? {
        var index = 0
        var pending: [Data] = []          // bloques pequeños en cola (cabeceras, padding, ceros finales)
        var handle: FileHandle?
        var currentPath = ""              // fichero cuyo cuerpo se está emitiendo (para el progreso)
        var bodyRemaining = 0             // bytes de cuerpo de fichero por emitir
        var bodyPadding = 0              // padding a 512 tras el cuerpo del fichero actual
        var emittedEnd = false

        func enqueue(_ item: WriteItem) throws {
            let path = item.isDirectory && !item.path.hasSuffix("/") ? item.path + "/" : item.path
            if Array(path.utf8).count > 100 { pending.append(paxHeader(path: path)) }   // nombre largo → PAX
            let size = item.isDirectory ? 0 : itemSize(item)
            pending.append(header(path: path, size: size, mtime: item.modifiedAt, isDirectory: item.isDirectory))
            guard !item.isDirectory else { return }
            switch item.source {
            case .data(let d):
                if !d.isEmpty { pending.append(d); onProgress(item.path, d.count) }
                let pad = padding(d.count); if !pad.isEmpty { pending.append(pad) }
            case .file(let url):
                if size > 0 {
                    handle = try FileHandle(forReadingFrom: url)
                    currentPath = item.path
                    bodyRemaining = size
                    bodyPadding = (blockSize - size % blockSize) % blockSize
                }
            }
        }

        return {
            while true {
                if !pending.isEmpty { return pending.removeFirst() }
                if let h = handle {
                    if bodyRemaining > 0, let chunk = try h.read(upToCount: min(64 * 1024, bodyRemaining)),
                       !chunk.isEmpty {
                        bodyRemaining -= chunk.count
                        onProgress(currentPath, chunk.count)   // bytes de entrada de este fichero
                        return chunk
                    }
                    try? h.close(); handle = nil
                    if bodyPadding > 0 { let p = Data(count: bodyPadding); bodyPadding = 0; return p }
                    continue
                }
                if index < items.count { try enqueue(items[index]); index += 1; continue }
                if !emittedEnd { emittedEnd = true; return Data(count: blockSize * 2) }   // dos bloques cero
                return nil
            }
        }
    }

    /// Tamaño del contenido de un ítem (para la cabecera): bytes en memoria o tamaño en disco.
    private static func itemSize(_ item: WriteItem) -> Int {
        switch item.source {
        case .data(let d): return d.count
        case .file(let url): return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        }
    }

    // MARK: - Helpers de escritura

    private static func header(path: String, size: Int, mtime: Date?, isDirectory: Bool) -> Data {
        var h = [UInt8](repeating: 0, count: blockSize)
        let nameBytes = Array(path.utf8.prefix(100))
        for (i, b) in nameBytes.enumerated() { h[i] = b }
        writeOctal(&h, 100, 8, 0o755)                 // mode
        writeOctal(&h, 108, 8, 0)                     // uid
        writeOctal(&h, 116, 8, 0)                     // gid
        writeOctal(&h, 124, 12, size)                 // size
        writeOctal(&h, 136, 12, Int(mtime?.timeIntervalSince1970 ?? 0))
        h[156] = isDirectory ? 0x35 : 0x30            // typeflag '5'/'0'
        let magic = Array("ustar\0".utf8); for (i, b) in magic.enumerated() { h[257 + i] = b }
        h[263] = 0x30; h[264] = 0x30                  // version "00"
        // checksum: con el campo a espacios
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        writeOctal(&h, 148, 7, sum)                   // 6 dígitos + NUL
        h[154] = 0x00; h[155] = 0x20
        return Data(h)
    }

    private static func paxHeader(path: String) -> Data {
        // Registro PAX: "<len> path=<ruta>\n", donde len es la longitud total del registro.
        let value = "path=" + path + "\n"
        var len = value.utf8.count + 1
        while String(len).utf8.count + 1 + value.utf8.count != len { len = String(len).utf8.count + 1 + value.utf8.count }
        let record = Data("\(len) \(value)".utf8)
        var data = header(path: "PaxHeader", size: record.count, mtime: nil, isDirectory: false)
        data[156] = 0x78   // 'x'
        // recalcular checksum tras cambiar typeflag
        var h = [UInt8](data)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        writeOctal(&h, 148, 7, sum); h[154] = 0; h[155] = 0x20
        var out = Data(h)
        out.append(record)
        out.append(padding(record.count))
        return out
    }

    private static func writeOctal(_ h: inout [UInt8], _ off: Int, _ len: Int, _ value: Int) {
        let digits = String(value, radix: 8)
        let field = String(repeating: "0", count: max(0, len - 1 - digits.count)) + digits
        for (i, c) in field.utf8.prefix(len - 1).enumerated() { h[off + i] = c }
        h[off + len - 1] = 0x00
    }

    private static func padding(_ size: Int) -> Data {
        let rem = size % blockSize
        return rem == 0 ? Data() : Data(count: blockSize - rem)
    }

    // MARK: - Helpers de lectura

    // Estos helpers indexan `Data` con índices **absolutos** (no rebasados a 0): el llamador
    // pasa offsets ya sumados a `data.startIndex`, así no hace falta copiar el contenedor.
    private static func isZeroBlock(_ d: Data, at p: Int) -> Bool {
        for i in p..<min(p + blockSize, d.endIndex) where d[i] != 0 { return false }
        return true
    }
    private static func string(_ d: Data, _ off: Int, _ len: Int) -> String {
        let end = min(off + len, d.endIndex)
        guard off < end else { return "" }
        var slice = d[off..<end]
        if let nul = slice.firstIndex(of: 0) { slice = slice[slice.startIndex..<nul] }
        return String(decoding: slice, as: UTF8.self)
    }
    private static func octal(_ d: Data, _ off: Int, _ len: Int) -> UInt64 {
        let s = string(d, off, len).trimmingCharacters(in: .whitespaces)
        return UInt64(s, radix: 8) ?? 0
    }
    private static func dateFrom(_ epoch: UInt64) -> Date? {
        epoch == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(epoch))
    }
    private static func parsePax(_ d: Data, start: Int, size: Int) -> (path: String?, size: UInt64?, mtime: Date?) {
        let end = min(start + size, d.endIndex)
        guard start < end else { return (nil, nil, nil) }
        let text = String(decoding: d[start..<end], as: UTF8.self)
        var path: String?; var sz: UInt64?; var mtime: Date?
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let kv = line[line.index(after: space)...]
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = String(kv[..<eq]); let value = String(kv[kv.index(after: eq)...])
            switch key {
            case "path": path = value
            case "size": sz = UInt64(value)
            case "mtime": mtime = Double(value).map { Date(timeIntervalSince1970: $0) }
            default: break
            }
        }
        return (path, sz, mtime)
    }
}
