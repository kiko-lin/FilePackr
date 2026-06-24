import Foundation
import Cz

enum ZlibError: Error { case initFailed, failed }

/// Compresión **DEFLATE en crudo** (RFC 1951, sin envoltura zlib/gzip) con la zlib del
/// sistema y un **nivel** 0–9. A diferencia del framework `Compression` de Apple, zlib sí
/// expone el nivel; por eso ZIP y el cuerpo de gzip pasan por aquí al escribir. La *lectura*
/// sigue usando el framework de Apple (no necesita nivel), así que no cambia.
///
/// Forma `next`/`sink` (memoria constante): lee la entrada por trozos y emite la salida por
/// trozos, igual que `CompressionStream`/`Bzip2`, para no cargar fichero ni resultado en RAM.
enum Zlib {

    /// Comprime el flujo de `next` a DEFLATE en crudo con `level` (0–9), emitiendo por `sink`.
    static func encode(level: Int32, next: () throws -> Data?, sink: (Data) throws -> Void) throws {
        var strm = z_stream()
        guard cz_deflate_init_raw(&strm, level) == Z_OK else { throw ZlibError.initFailed }
        defer { deflateEnd(&strm) }

        let cap = 64 * 1024
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { outBuf.deallocate() }

        // Vacía al `sink` lo producido en `outBuf` tras una pasada de `deflate`.
        func drain() throws {
            let produced = cap - Int(strm.avail_out)
            if produced > 0 { try sink(Data(bytes: outBuf, count: produced)) }
        }

        // Procesa un trozo (o el cierre con Z_FINISH) drenando la salida en cada pasada.
        // `next_in` apunta al búfer del trozo y permanece válido durante todo el bucle interno
        // (con Z_NO_FLUSH zlib consume toda la entrada antes de salir).
        func run(_ chunk: Data, flush: Int32) throws {
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                strm.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                strm.avail_in = uInt(chunk.count)
                repeat {
                    strm.next_out = outBuf
                    strm.avail_out = uInt(cap)
                    let rc = deflate(&strm, flush)
                    guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else { throw ZlibError.failed }
                    try drain()
                } while strm.avail_out == 0
            }
        }

        while let chunk = try next() {
            if chunk.isEmpty { continue }
            try run(chunk, flush: Z_NO_FLUSH)
        }
        try run(Data(), flush: Z_FINISH)
    }
}
