import Foundation

/// Localiza el bloque `HEAD_SERVICE` (0x03) que WinRAR añade al final de un volumen RAR5 —
/// normalmente el índice "QuickOpen", pensado para listar el archivo rápido sin recorrerlo
/// entero. La libarchive del sistema documenta que no usa ese índice para nada (su lector no
/// lo implementa, solo lo salta), pero si el bloque contiene datos obsoletos de una edición
/// anterior del archivo — algo que WinRAR no siempre limpia al reescribirlo — su lectura
/// desincroniza el recorrido de cabeceras: acaba interpretando la caché vieja como si fueran
/// entradas reales, y esas entradas fantasma sustituyen (o se mezclan con) el listado
/// correcto. Como el bloque no aporta nada, se recorta antes de dárselo a libarchive en vez
/// de confiar en que lo salte bien.
///
/// Camina bloque a bloque desde el principio del volumen usando solo los tamaños declarados
/// en cada cabecera — nunca descomprime ni lee contenido — así que es barato incluso en
/// volúmenes de varios GB.
enum RAR5TrailingServiceBlock {

    private static let signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    /// Offset, dentro de este único volumen, a partir del cual se puede cortar la lectura sin
    /// perder contenido real: el inicio de un bloque `HEAD_SERVICE` que precede directamente a
    /// `HEAD_ENDARC` (o al final del fichero). `nil` si no es RAR5, está corrupto, o la
    /// estructura no encaja exactamente con ese patrón — en cuyo caso no se toca nada y se deja
    /// que libarchive lea el volumen tal cual, como hasta ahora.
    ///
    /// `read(offset, length)` debe devolver exactamente `length` bytes empezando en `offset`,
    /// o `nil` si no puede (fin de fichero, error de lectura...).
    static func offset(length: Int64, read: @escaping (Int64, Int) -> Data?) -> Int64? {
        guard length >= 8, let sig = read(0, 8), [UInt8](sig) == signature else { return nil }

        var cursor = Cursor(length: length, read: read, offset: 8)
        while cursor.offset < length {
            guard let block = cursor.readBlock() else { return nil }

            if block.headerType == 3 { // HEAD_SERVICE
                // Solo se recorta si encaja exactamente con "SERVICE justo antes del final":
                // si después hay más contenido que no sea HEAD_ENDARC, no se toca nada.
                if block.nextOffset == length { return block.start }
                var probe = cursor
                probe.offset = block.nextOffset
                guard let next = probe.readBlock() else { return nil }
                return next.headerType == 5 ? block.start : nil // HEAD_ENDARC
            }
            if block.headerType == 5 { return nil } // ENDARC sin SERVICE: nada que recortar

            cursor.offset = block.nextOffset
        }
        return nil
    }

    private struct Block {
        let start: Int64
        let headerType: UInt64
        let nextOffset: Int64
    }

    /// Lector con ventana deslizante sobre `read`, para no hacer una llamada por byte.
    private struct Cursor {
        let length: Int64
        let read: (Int64, Int) -> Data?
        var offset: Int64
        private var window: [UInt8] = []
        private var windowBase: Int64 = 0

        init(length: Int64, read: @escaping (Int64, Int) -> Data?, offset: Int64) {
            self.length = length
            self.read = read
            self.offset = offset
        }

        private mutating func ensure(_ count: Int) -> Bool {
            if offset >= windowBase, offset + Int64(count) <= windowBase + Int64(window.count) { return true }
            windowBase = offset
            let want = Int(min(length - offset, Int64(max(count, 65_536))))
            guard want > 0, let chunk = read(offset, want) else { return false }
            window = [UInt8](chunk)
            return window.count >= count
        }

        private mutating func byte() -> UInt8? {
            guard ensure(1) else { return nil }
            defer { offset += 1 }
            return window[Int(offset - windowBase)]
        }

        /// Vint de RAR5: 7 bits por byte, bit alto = continúa (mismo formato que
        /// `RarVolumes.readVint`, aquí reimplementado sobre la ventana deslizante).
        private mutating func vint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0, count = 0
            while true {
                guard count < 10, let b = byte() else { return nil }
                result |= UInt64(b & 0x7F) << shift
                count += 1
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }

        /// Lee un bloque base RAR5 (CRC32 + cabecera) y calcula dónde empieza el siguiente, sin
        /// interpretar los campos específicos de cada tipo de cabecera: solo hace falta su
        /// tamaño (`rawHeaderSize`) y, si declara datos (`HFL_DATA`), su tamaño (`dataSize`)
        /// para saltar por encima sin descomprimir nada.
        mutating func readBlock() -> Block? {
            let start = offset
            guard ensure(4) else { return nil }
            offset += 4 // CRC32 del bloque; no hace falta verificarlo para este propósito.

            guard let rawHeaderSize = vint(), rawHeaderSize > 0, rawHeaderSize < 2_000_000 else { return nil }
            let headerBodyStart = offset
            guard let headerType = vint(), let headerFlags = vint() else { return nil }

            if headerFlags & 0x0001 != 0 { // HFL_EXTRA_DATA
                guard vint() != nil else { return nil }
            }
            var dataSize: UInt64 = 0
            if headerFlags & 0x0002 != 0 { // HFL_DATA
                guard let d = vint() else { return nil }
                dataSize = d
            }

            let next = headerBodyStart + Int64(rawHeaderSize) + Int64(dataSize)
            guard next > start, next <= length else { return nil }
            return Block(start: start, headerType: headerType, nextOffset: next)
        }
    }
}
