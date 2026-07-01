import XCTest
@testable import ArchiveBrowser

/// Cobertura de **robustez**: input malformado (truncado, CRC/magic inválidos) debe fallar
/// **limpio** (lanzar un error, sin crash ni datos a medias) y no cuelga; y **AES en sus tres
/// fuerzas** (128/192/256), que el motor escribe pero antes solo se probaba en 256.
final class RobustnessTests: XCTestCase {

    // Datos con estructura, comprimibles pero no triviales.
    private let payload = Data(repeating: 0, count: 100) + Data("The quick brown fox. ".utf8) + Data(repeating: 0x7F, count: 500)

    // MARK: - Corrupción: compresores de un flujo (gz/xz/bz2)

    func testGzipTruncatedThrows() {
        let gz = Gzip.compress(payload)
        XCTAssertThrowsError(try Gzip.decompress(Data(gz.prefix(gz.count / 2))))
    }

    func testGzipBadMagicThrows() {
        XCTAssertThrowsError(try Gzip.decompress(Data(repeating: 0xAB, count: 64))) {
            XCTAssertEqual($0 as? GzipError, .notGzip)
        }
    }

    func testGzipCorruptBodyThrows() {
        var gz = Gzip.compress(payload)
        gz[gz.count / 2] ^= 0xFF   // altera un byte del cuerpo DEFLATE → o rompe el stream o falla el CRC
        XCTAssertThrowsError(try Gzip.decompress(gz))
    }

    func testXzTruncatedThrows() {
        let xz = Xz.compress(payload)
        XCTAssertThrowsError(try Xz.decompress(Data(xz.prefix(xz.count / 2)))) {
            XCTAssertEqual($0 as? XzError, .corrupt)
        }
    }

    func testXzBadMagicThrows() {
        XCTAssertThrowsError(try Xz.decompress(Data(repeating: 0xAB, count: 64))) {
            XCTAssertEqual($0 as? XzError, .notXz)
        }
    }

    func testBzip2TruncatedThrows() {
        let bz = Bzip2.compress(payload)
        XCTAssertThrowsError(try Bzip2.decompress(Data(bz.prefix(bz.count / 2)))) {
            XCTAssertEqual($0 as? Bzip2Error, .corrupt)
        }
    }

    func testBzip2BadMagicThrows() {
        XCTAssertThrowsError(try Bzip2.decompress(Data(repeating: 0xAB, count: 64))) {
            XCTAssertEqual($0 as? Bzip2Error, .notBzip2)
        }
    }

    // MARK: - Corrupción: ZIP

    func testZipNotArchiveThrows() {
        XCTAssertThrowsError(try ZipReader().listEntries(in: Data(repeating: 0x00, count: 200))) {
            XCTAssertTrue($0 is ArchiveError, "esperaba ArchiveError, llegó \($0)")
        }
    }

    func testZipTruncatedThrows() throws {
        let zip = try ZipWriter().build([ZipEntryInput(path: "a.txt", modifiedAt: nil, source: .data(payload))])
        // Recortar el final elimina el End Of Central Directory → no se puede indexar.
        XCTAssertThrowsError(try ZipReader().listEntries(in: Data(zip.prefix(zip.count - 8)))) {
            XCTAssertTrue($0 is ArchiveError, "esperaba ArchiveError, llegó \($0)")
        }
    }

    // MARK: - Corrupción: tar

    func testTarTruncatedThrows() {
        let tar = Tar.write([Tar.WriteItem(path: "big.bin",
                                           data: Data(repeating: 0x41, count: 2048),
                                           modifiedAt: nil, isDirectory: false)])
        // Cortar a mitad del contenido declarado → el guard de tamaño debe detectarlo.
        XCTAssertThrowsError(try Tar.listEntries(in: Data(tar.prefix(600)))) {
            XCTAssertEqual($0 as? TarError, .corrupt)
        }
    }

    func testTarCorruptSizeFieldThrows() {
        var tar = Tar.write([Tar.WriteItem(path: "x.txt", data: Data("hola".utf8),
                                           modifiedAt: nil, isDirectory: false)])
        // El campo `size` del header ustar está en offset 124 (12 bytes octales). Lo llenamos de
        // dígitos altos → tamaño enorme que se sale del contenedor → corrupt (no lectura de basura).
        for i in 124..<136 { tar[i] = 0x37 }   // '7'
        XCTAssertThrowsError(try Tar.listEntries(in: tar)) {
            XCTAssertEqual($0 as? TarError, .corrupt)
        }
    }

    // MARK: - AES: las tres fuerzas (128/192/256)

    func testAESRoundTripAllStrengths() throws {
        let clear = Array("Contenido a cifrar con AES de WinZip — áéíóú".utf8)
        for strength: UInt8 in [1, 2, 3] {   // 1 = AES-128, 2 = AES-192, 3 = AES-256
            let enc = ZipAES.encrypt(clear, password: "clave-secreta", strength: strength)
            let dec = try ZipAES.decrypt(enc, password: "clave-secreta", strength: strength)
            XCTAssertEqual(dec, clear, "round-trip AES falló en fuerza \(strength)")
        }
    }

    func testAESWrongPasswordThrows() {
        let clear = Array("secreto".utf8)
        let enc = ZipAES.encrypt(clear, password: "correcta", strength: 3)
        XCTAssertThrowsError(try ZipAES.decrypt(enc, password: "incorrecta", strength: 3)) {
            XCTAssertEqual($0 as? ZipAESError, .wrongPassword)
        }
    }
}
