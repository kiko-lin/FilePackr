import XCTest
@testable import ArchiveBrowser

/// Cancelación **real** de la compresión: el escritor debe parar en el siguiente punto de
/// comprobación (por entrada o por trozo) y lanzar `CancellationError`, no terminar el trabajo.
final class CompressionCancellationTests: XCTestCase {

    // MARK: - Helpers

    /// Devuelve `true` a partir de la `at`-ésima comprobación (simula que el usuario cancela
    /// tras un rato). Es una clase para poder mutar el contador desde un cierre `@Sendable`.
    private final class Flip: @unchecked Sendable {
        private let at: Int
        private var n = 0
        init(at: Int) { self.at = at }
        func hit() -> Bool { n += 1; return n >= at }
        var check: CancellationCheck { CancellationCheck { [self] in hit() } }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Datos de tamaño dado, mezcla compresible/incompresible, para cruzar varios trozos.
    private func sampleData(_ size: Int) -> Data {
        var d = Data(capacity: size)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let line = Data("FilePackr cancelación — línea repetible y compresible.\n".utf8)
        while d.count < size {
            if d.count % 3 == 0 { d.append(line) }
            else {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                withUnsafeBytes(of: seed.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d.prefix(size)
    }

    // MARK: - ZIP

    /// Cancelación entre entradas: varias entradas en memoria, cancela en la 3ª comprobación.
    func testZipCancelsBetweenEntries() throws {
        let inputs = (0..<10).map {
            ZipEntryInput(path: "f\($0).txt", modifiedAt: nil, source: .data(Data("hola \($0)".utf8)))
        }
        XCTAssertThrowsError(try ZipWriter().build(inputs, cancellation: Flip(at: 3).check)) {
            XCTAssertTrue($0 is CancellationError, "esperaba CancellationError, fue \($0)")
        }
    }

    /// Cancelación **a mitad** de un fichero grande comprimido en streaming.
    func testZipCancelsMidLargeFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("grande.bin")
        try sampleData(4_000_000).write(to: src)

        let input = ZipEntryInput(path: "grande.bin", modifiedAt: nil, source: .file(src))
        XCTAssertThrowsError(try ZipWriter().build([input], cancellation: Flip(at: 3).check)) {
            XCTAssertTrue($0 is CancellationError, "esperaba CancellationError, fue \($0)")
        }
    }

    // MARK: - Compresores (gz/xz/bz2): la cancelación entra por el `next`

    /// `next` que entrega `data` por trozos pero consulta la cancelación antes de cada uno
    /// (igual que hace la app al envolver el generador).
    private func cancellableNext(_ data: Data, _ cancel: CancellationCheck) -> () throws -> Data? {
        var offset = 0
        return {
            try cancel.check()
            guard offset < data.count else { return nil }
            let n = min(64 * 1024, data.count - offset)
            defer { offset += n }
            return data.subdata(in: offset ..< offset + n)
        }
    }

    /// gzip/xz comparten `CompressionStream`: cancelar el `next` corta el flujo.
    func testGzipCancelsViaNext() throws {
        let next = cancellableNext(sampleData(4_000_000), Flip(at: 3).check)
        XCTAssertThrowsError(try Gzip.compress(next: next, sink: { _ in })) {
            XCTAssertTrue($0 is CancellationError, "esperaba CancellationError, fue \($0)")
        }
    }

    /// bzip2 tiene su propio bucle incremental: también corta por el `next`.
    func testBzip2CancelsViaNext() throws {
        let next = cancellableNext(sampleData(4_000_000), Flip(at: 3).check)
        XCTAssertThrowsError(try Bzip2.compress(next: next, sink: { _ in })) {
            XCTAssertTrue($0 is CancellationError, "esperaba CancellationError, fue \($0)")
        }
    }

    // MARK: - libarchive (7z/iso/xar): cancelación por parámetro

    func testLibArchiveCancelsBetweenEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("salida.7z")
        let items = (0..<10).map {
            LibArchive.WriteItem(path: "f\($0).txt", data: Data("hola \($0)".utf8),
                                 modifiedAt: nil, isDirectory: false)
        }
        XCTAssertThrowsError(try LibArchive.write(items, to: out, format: .sevenZip,
                                                  cancellation: Flip(at: 3).check)) {
            XCTAssertTrue($0 is CancellationError, "esperaba CancellationError, fue \($0)")
        }
    }

    /// Sin cancelación, el escritor termina normalmente (regresión del valor por defecto `.none`).
    func testZipNotCancelledCompletes() throws {
        let inputs = (0..<5).map {
            ZipEntryInput(path: "f\($0).txt", modifiedAt: nil, source: .data(sampleData(10_000)))
        }
        let zip = try ZipWriter().build(inputs)            // cancellation por defecto = .none
        XCTAssertGreaterThan(zip.count, 0)
        XCTAssertEqual(try ZipReader().listEntries(in: zip).count, 5)
    }
}
