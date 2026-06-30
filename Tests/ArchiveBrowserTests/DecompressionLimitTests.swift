import XCTest
@testable import ArchiveBrowser

/// Cota anti «bomba de descompresión» en las rutas gzip/xz/bzip2 (las que, a diferencia de
/// DEFLATE en ZIP, no traen tamaño declarado y pueden expandir sin límite). Verifica que una
/// salida desproporcionada aborta con `DecompressionLimitError.bombDetected` y que la cota por
/// defecto no molesta a datos legítimos muy comprimibles.
final class DecompressionLimitTests: XCTestCase {

    /// Cota minúscula: cualquier salida > 10 bytes la supera (ratio 0 + floor 10). Permite
    /// disparar el corte con datos pequeños, sin generar gigabytes en el test.
    private let tiny = DecompressionLimit(maxRatio: 0, floor: 10)

    /// Datos legítimos que comprimen muy bien y descomprimen a 5000 B (> 10 → disparan `tiny`).
    private let payload = Data(repeating: 0x41, count: 5000)

    func testLimitArithmetic() {
        let l = DecompressionLimit(maxRatio: 10, floor: 100)
        XCTAssertFalse(l.isExceeded(output: 100, input: 0))     // = floor: justo dentro
        XCTAssertTrue(l.isExceeded(output: 101, input: 0))      // > floor
        XCTAssertFalse(l.isExceeded(output: 1100, input: 100))  // input*10 + 100 = 1100
        XCTAssertTrue(l.isExceeded(output: 1101, input: 100))
    }

    func testGzipBombAbortsAndNormalRoundTrips() throws {
        let gz = Gzip.compress(payload)
        XCTAssertThrowsError(try Gzip.decompress(gz, limit: tiny)) {
            XCTAssertEqual($0 as? DecompressionLimitError, .bombDetected)
        }
        XCTAssertEqual(try Gzip.decompress(gz), payload)   // cota estándar: normal
    }

    func testXzBombAbortsAndNormalRoundTrips() throws {
        let xz = Xz.compress(payload)
        XCTAssertThrowsError(try Xz.decompress(xz, limit: tiny)) {
            XCTAssertEqual($0 as? DecompressionLimitError, .bombDetected)
        }
        XCTAssertEqual(try Xz.decompress(xz), payload)
    }

    func testBzip2BombAbortsAndNormalRoundTrips() throws {
        let bz = Bzip2.compress(payload)
        XCTAssertThrowsError(try Bzip2.decompress(bz, limit: tiny)) {
            XCTAssertEqual($0 as? DecompressionLimitError, .bombDetected)
        }
        XCTAssertEqual(try Bzip2.decompress(bz), payload)
    }

    /// La cota por defecto NO debe rechazar datos legítimos muy comprimibles: 1 MB de ceros
    /// (ratio enorme) cabe bajo el `floor` de 64 MiB → descomprime sin error en los tres códecs.
    func testStandardLimitAllowsHighlyCompressibleData() throws {
        let zeros = Data(count: 1_000_000)
        XCTAssertEqual(try Gzip.decompress(Gzip.compress(zeros)).count, zeros.count)
        XCTAssertEqual(try Xz.decompress(Xz.compress(zeros)).count, zeros.count)
        XCTAssertEqual(try Bzip2.decompress(Bzip2.compress(zeros)).count, zeros.count)
    }
}
