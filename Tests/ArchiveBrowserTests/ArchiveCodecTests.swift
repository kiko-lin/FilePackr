import XCTest
@testable import ArchiveBrowser

/// El registro `ArchiveFormat.codec` debe leer y extraer cada familia de formato, y
/// refinar gz/xz/bz2 sueltos vs `.tar.<x>`, igual que hacía el switch del documento.
final class ArchiveCodecTests: XCTestCase {

    private let hello = Data("hola códec".utf8)

    func testZipCodecRoundTrip() throws {
        let zip = try ZipWriter().build([
            ZipEntryInput(path: "a.txt", modifiedAt: nil, source: .data(hello)),
        ])
        let result = try ArchiveFormat.zip.codec.open(zip, fallbackName: "a")
        XCTAssertEqual(result.format, .zip)
        XCTAssertEqual(result.entries.map(\.path), ["a.txt"])
        let data = try result.format.codec.entryData(for: result.entries[0], in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    func testGzipCodecKeepsSingleFile() throws {
        let gz = Gzip.compress(hello, filename: "nota.txt")
        let result = try ArchiveFormat.gzip.codec.open(gz, fallbackName: "nota")
        XCTAssertEqual(result.format, .gzip, "un .gz suelto no debe confundirse con tar.gz")
        XCTAssertEqual(result.entries.count, 1)
        // El nombre (FNAME) y el tamaño (ISIZE) se leen de la cabecera/pie sin inflar el .gz.
        XCTAssertEqual(result.entries[0].path, "nota.txt")
        XCTAssertEqual(result.entries[0].uncompressedSize, UInt64(hello.count))
        let data = try result.format.codec.entryData(for: result.entries[0], in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    func testGzipCodecRefinesToTarGzip() throws {
        let tar = Tar.write([
            Tar.WriteItem(path: "dir/uno.txt", data: hello, modifiedAt: nil, isDirectory: false),
        ])
        let targz = Gzip.compress(tar)
        // Se abre como `.gz` (detección por nombre) pero el codec debe refinar a `.tarGzip`.
        let result = try ArchiveFormat.gzip.codec.open(targz, fallbackName: "paquete")
        XCTAssertEqual(result.format, .tarGzip)
        XCTAssertTrue(result.entries.contains { $0.path == "dir/uno.txt" })
        let entry = try XCTUnwrap(result.entries.first { $0.path == "dir/uno.txt" })
        let data = try result.format.codec.entryData(for: entry, in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    /// El item 3: los metadatos de ZIP solo aparecen en entradas de ZIP; los demás
    /// formatos no inventan campos. TAR expone su `dataOffset`; ZIP no (usa el local header).
    func testEntryMetadataIsFormatSpecific() throws {
        let zip = try ZipWriter().build([ZipEntryInput(path: "a.txt", modifiedAt: nil, source: .data(hello))])
        let zipEntry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertNotNil(zipEntry.zip, "una entrada de ZIP debe llevar su ZipEntryInfo")
        XCTAssertNil(zipEntry.dataOffset, "ZIP no usa dataOffset (extrae vía local header)")

        let tar = Tar.write([Tar.WriteItem(path: "b.txt", data: hello, modifiedAt: nil, isDirectory: false)])
        let tarEntry = try XCTUnwrap(try Tar.listEntries(in: tar).first)
        XCTAssertNil(tarEntry.zip, "una entrada de TAR no debe arrastrar metadatos de ZIP")
        XCTAssertNotNil(tarEntry.dataOffset, "TAR sí expone el offset de los datos")

        let gzEntry = try XCTUnwrap(Gzip.entries(in: Gzip.compress(hello), fallbackName: "c").first)
        XCTAssertNil(gzEntry.zip)
        XCTAssertFalse(gzEntry.isAESEncrypted)
    }

    func testTarCodecRoundTrip() throws {
        let tar = Tar.write([
            Tar.WriteItem(path: "x.bin", data: hello, modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tar.codec.open(tar, fallbackName: "x")
        XCTAssertEqual(result.format, .tar)
        let entry = try XCTUnwrap(result.entries.first { $0.path == "x.bin" })
        let data = try result.format.codec.entryData(for: entry, in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }
}
