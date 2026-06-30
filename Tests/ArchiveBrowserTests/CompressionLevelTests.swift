import XCTest
@testable import ArchiveBrowser

/// Demuestra (y vigila como regresión) que el nivel de compresión **afecta al tamaño**: a mayor
/// nivel, salida no mayor; y que rápida y máxima **difieren de verdad** sobre contenido compresible.
final class CompressionLevelTests: XCTestCase {

    /// Texto compresible con redundancia realista (vocabulario recombinado de forma determinista,
    /// ni trivialmente repetido ni aleatorio), suficiente para que un nivel mayor saque ventaja.
    private func compressibleText(_ count: Int) -> Data {
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
                     "elit", "sed", "eiusmod", "tempor", "incididunt", "labore", "dolore",
                     "magna", "aliqua", "enim", "minim", "veniam", "quis", "nostrud"]
        var text = ""
        var s: UInt64 = 1
        var i = 0
        while text.utf8.count < count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            text += words[Int(s >> 33) % words.count]
            text += (i % 12 == 0) ? ".\n" : " "
            i += 1
        }
        return Data(text.utf8)
    }

    private func levels(_ compress: (CompressionLevel) -> Int) -> (fast: Int, normal: Int, max: Int) {
        (compress(.fast), compress(.normal), compress(.maximum))
    }

    func testHigherLevelNeverGrowsAndActuallyDiffers() {
        let data = compressibleText(600_000)

        let deflate = levels { Deflate.compress(data, level: $0)?.count ?? .max }
        let gzip = levels { Gzip.compress(data, level: $0).count }
        let xz = levels { Xz.compress(data, level: $0).count }
        let bzip2 = levels { Bzip2.compress(data, blockSize: $0.bzip2BlockSize).count }

        // Monotonía: subir el nivel nunca debe agrandar la salida. Vale para los cuatro.
        for s in [deflate, gzip, xz, bzip2] {
            XCTAssertLessThanOrEqual(s.normal, s.fast, "normal>fast en \(s)")
            XCTAssertLessThanOrEqual(s.max, s.normal, "max>normal en \(s)")
            XCTAssertLessThan(s.max, data.count, "no comprimió en \(s)")
        }

        // Y de verdad difieren (rápida vs máxima) en formatos LZMA/bzip2, donde el nivel pesa más.
        XCTAssertLessThan(xz.max, xz.fast, "xz no difirió: \(xz)")
        XCTAssertLessThan(bzip2.max, bzip2.fast, "bzip2 no difirió: \(bzip2)")
    }
}
