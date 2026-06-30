import Foundation
import Compression

enum CompressionStreamError: Error { case failed }

/// Driver del *Compression framework* de Apple en **streaming**: lee la entrada por
/// trozos (closure `next`) y escribe la salida por trozos (closure `sink`), con
/// memoria constante (no acumula ni la entrada ni la salida completas).
///
/// Centraliza el bucle de `compression_stream_process` que necesitan tanto gzip
/// (DEFLATE, `COMPRESSION_ZLIB`) como xz (`COMPRESSION_LZMA`), en cualquiera de las
/// dos operaciones (comprimir/descomprimir).
enum CompressionStream {

    /// Procesa un flujo completo. `next` devuelve el siguiente trozo de entrada o
    /// `nil` cuando se acaba; `sink` recibe cada trozo de salida producido.
    /// Lanza `CompressionStreamError.failed` si el framework reporta un error.
    static func run(operation: compression_stream_operation,
                    algorithm: compression_algorithm,
                    next: () throws -> Data?,
                    sink: (Data) throws -> Void,
                    limit: DecompressionLimit = .standard) throws {
        // Cota anti-bomba: solo al DESCOMPRIMIR (al comprimir, la salida es menor que la entrada).
        // Llevamos el total consumido/producido inline (next/sink son no-escaping) y abortamos
        // al superarse `input × maxRatio + floor`.
        let enforce = (operation == COMPRESSION_STREAM_DECODE)
        var totalIn = 0, totalOut = 0

        let dstCapacity = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }

        var stream = compression_stream(dst_ptr: dst, dst_size: dstCapacity,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, operation, algorithm) == COMPRESSION_STATUS_OK else {
            throw CompressionStreamError.failed
        }
        defer { compression_stream_destroy(&stream) }
        stream.dst_ptr = dst
        stream.dst_size = dstCapacity

        // Procesa un trozo (o el cierre, con `finalize`) drenando la salida en cada
        // pasada. Devuelve `true` cuando el flujo ha terminado (status END).
        func process(_ chunk: Data, finalize: Bool) throws -> Bool {
            let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            return try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress
                    ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = chunk.count
                while true {
                    let status = compression_stream_process(&stream, flags)
                    if stream.dst_size < dstCapacity {
                        let produced = dstCapacity - stream.dst_size
                        if enforce {
                            totalOut += produced
                            if limit.isExceeded(output: totalOut, input: totalIn) {
                                throw DecompressionLimitError.bombDetected
                            }
                        }
                        try sink(Data(bytes: dst, count: produced))
                        stream.dst_ptr = dst
                        stream.dst_size = dstCapacity
                    }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        // Entrada consumida y no estamos cerrando: a buscar más.
                        if stream.src_size == 0 && !finalize { return false }
                    case COMPRESSION_STATUS_END:
                        return true
                    default:
                        throw CompressionStreamError.failed
                    }
                }
            }
        }

        while let chunk = try next() {
            if chunk.isEmpty { continue }
            if enforce { totalIn += chunk.count }
            _ = try process(chunk, finalize: false)
        }
        _ = try process(Data(), finalize: true)
    }

    /// `next` que entrega `data` una sola vez y luego `nil` (ruta en memoria).
    static func once(_ data: Data) -> () -> Data? {
        var sent = false
        return { if sent { return nil }; sent = true; return data }
    }

    /// `next` que lee de `handle` por trozos de `chunk` bytes hasta EOF (ruta en disco).
    static func reader(_ handle: FileHandle, chunk: Int = 64 * 1024) -> () throws -> Data? {
        { let d = try handle.read(upToCount: chunk); return (d?.isEmpty ?? true) ? nil : d }
    }
}
