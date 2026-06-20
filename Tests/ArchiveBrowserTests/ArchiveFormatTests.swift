import XCTest
@testable import ArchiveBrowser

final class ArchiveFormatTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testDetectByExtension() {
        XCTAssertEqual(ArchiveFormat.detectByExtension(url("a.zip")), .zip)
        XCTAssertEqual(ArchiveFormat.detectByExtension(url("a.tar.gz")), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detectByExtension(url("a.7z")), .sevenZip)
        XCTAssertNil(ArchiveFormat.detectByExtension(url("a.bin")), "extensión desconocida → nil")
        XCTAssertNil(ArchiveFormat.detectByExtension(url("sinextension")))
    }

    func testDetectByMagic() {
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data([0x50, 0x4B, 0x03, 0x04, 0, 0])), .zip)
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])), .sevenZip)
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])), .xz)
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data([0x1F, 0x8B, 0x08])), .gzip)
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data([0x42, 0x5A, 0x68, 0x39])), .bzip2)
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])), .rar)
        XCTAssertNil(ArchiveFormat.detectByMagic(Data([0, 1, 2, 3])))
    }

    func testDetectByMagicTarAtOffset257() {
        var bytes = [UInt8](repeating: 0, count: 263)
        for (i, b) in "ustar".utf8.enumerated() { bytes[257 + i] = b }
        XCTAssertEqual(ArchiveFormat.detectByMagic(Data(bytes)), .tar)
    }

    func testDetectCombinedPrefersExtensionThenMagic() {
        // Extensión conocida manda aunque el contenido no cuadre.
        XCTAssertEqual(ArchiveFormat.detect(from: url("a.7z"), contents: Data([0x1F, 0x8B])), .sevenZip)
        // Extensión desconocida → cae a la firma.
        XCTAssertEqual(ArchiveFormat.detect(from: url("a.bin"), contents: Data([0x50, 0x4B, 0x03, 0x04])), .zip)
        // Ni extensión ni firma → último recurso .zip.
        XCTAssertEqual(ArchiveFormat.detect(from: url("a.bin"), contents: Data([0, 1, 2])), .zip)
    }
}
