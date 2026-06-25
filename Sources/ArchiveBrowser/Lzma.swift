import Foundation
import Clzma

enum LzmaError: Error { case initFailed, failed }

/// Compresión **`.xz`** (LZMA2) con la liblzma del sistema y un **preset** 0–9. A diferencia
/// del framework `Compression` de Apple (`COMPRESSION_LZMA`, sin nivel), liblzma sí expone el
/// preset; por eso `xz`/`tar.xz` pasan por aquí **al escribir**. La *lectura* sigue en el
/// framework de Apple (no necesita nivel), así que no cambia.
///
/// Forma `next`/`sink` (memoria constante): lee la entrada por trozos y emite la salida por
/// trozos, igual que `Zlib`/`Bzip2`, sin cargar fichero ni resultado en RAM.
enum Lzma {

    private static let LZMA_OK: Int32 = 0
    private static let LZMA_STREAM_END: Int32 = 1
    private static let LZMA_RUN: Int32 = 0
    private static let LZMA_FINISH: Int32 = 3
    private static let LZMA_CHECK_CRC64: Int32 = 4   // comprobación de integridad por defecto de xz

    /// Comprime el flujo de `next` a `.xz` con `preset` (0–9), emitiendo por `sink`.
    static func encode(preset: UInt32, next: () throws -> Data?, sink: (Data) throws -> Void) throws {
        var strm = lzma_stream()
        guard lzma_easy_encoder(&strm, preset, LZMA_CHECK_CRC64) == LZMA_OK else { throw LzmaError.initFailed }
        defer { lzma_end(&strm) }

        let cap = 64 * 1024
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { outBuf.deallocate() }

        // Vacía al `sink` lo producido en `outBuf` tras una pasada de `lzma_code`.
        func drain() throws {
            let produced = cap - strm.avail_out
            if produced > 0 { try sink(Data(bytes: outBuf, count: produced)) }
        }

        // Procesa un trozo (o el cierre con LZMA_FINISH) drenando la salida en cada pasada.
        // `next_in` apunta al búfer del trozo y permanece válido durante el bucle interno (con
        // LZMA_RUN liblzma consume toda la entrada antes de devolver con avail_out > 0).
        func run(_ chunk: Data, action: Int32) throws {
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                strm.next_in = raw.bindMemory(to: UInt8.self).baseAddress
                strm.avail_in = chunk.count
                repeat {
                    strm.next_out = outBuf
                    strm.avail_out = cap
                    let rc = lzma_code(&strm, action)
                    guard rc == LZMA_OK || rc == LZMA_STREAM_END else { throw LzmaError.failed }
                    try drain()
                } while strm.avail_out == 0
            }
        }

        while let chunk = try next() {
            if chunk.isEmpty { continue }
            try run(chunk, action: LZMA_RUN)
        }
        try run(Data(), action: LZMA_FINISH)
    }
}
