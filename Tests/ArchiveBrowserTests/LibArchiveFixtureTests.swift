import XCTest
@testable import ArchiveBrowser

/// Formatos **solo de lectura** de libarchive (cpio/cab/lha/rar): no los escribimos, así que
/// no hay round-trip posible. Se prueban contra **fixtures reales** generados por herramientas
/// externas (ver `Fixtures/`), comprobando que `listEntries`/`extractEntry` los interpretan.
final class LibArchiveFixtureTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "falta el fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    // MARK: - CPIO (formato newc / SVR4, generado con /usr/bin/cpio)

    /// El fixture `sample.cpio` contiene: hola.txt (15 B), config.json (17 B),
    /// docs/anidado.txt (17 B) y el directorio docs/.
    func testCpioListsEntries() throws {
        let (entries, encrypted) = try LibArchive.listEntries(in: fixture("sample", "cpio"))
        XCTAssertFalse(encrypted)

        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("hola.txt"))
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertTrue(paths.contains("docs/anidado.txt"))

        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(hola.uncompressedSize, 15)
        XCTAssertFalse(hola.isDirectory)

        XCTAssertTrue(entries.contains { $0.isDirectory && $0.path.hasPrefix("docs") })
    }

    func testCpioExtractsContent() throws {
        let data = try fixture("sample", "cpio")
        XCTAssertEqual(try LibArchive.extractEntry(path: "hola.txt", in: data),
                       Data("Hola mundo cpio".utf8))
        XCTAssertEqual(try LibArchive.extractEntry(path: "docs/anidado.txt", in: data),
                       Data("contenido anidado".utf8))
    }

    // MARK: - CAB (MSCF almacenado, sin compresión)

    /// El fixture `sample.cab` contiene hola.txt (14 B) y docs/anidado.txt (17 B).
    /// libarchive normaliza el separador `\` de CAB a `/`.
    func testCabListsEntries() throws {
        let (entries, encrypted) = try LibArchive.listEntries(in: fixture("sample", "cab"))
        XCTAssertFalse(encrypted)

        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("hola.txt"))
        XCTAssertTrue(paths.contains("docs/anidado.txt"))

        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(hola.uncompressedSize, 14)
        XCTAssertFalse(hola.isDirectory)
    }

    func testCabExtractsContent() throws {
        let data = try fixture("sample", "cab")
        XCTAssertEqual(try LibArchive.extractEntry(path: "hola.txt", in: data),
                       Data("Hola mundo cab".utf8))
        XCTAssertEqual(try LibArchive.extractEntry(path: "docs/anidado.txt", in: data),
                       Data("contenido anidado".utf8))
    }

    // MARK: - LHA (cabecera nivel 0, método -lh0- almacenado)

    /// El fixture `sample.lha` contiene hola.txt (14 B) y config.json (17 B).
    func testLhaListsEntries() throws {
        let (entries, encrypted) = try LibArchive.listEntries(in: fixture("sample", "lha"))
        XCTAssertFalse(encrypted)

        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("hola.txt"))
        XCTAssertTrue(paths.contains("config.json"))

        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(hola.uncompressedSize, 14)
        XCTAssertFalse(hola.isDirectory)
    }

    func testLhaExtractsContent() throws {
        let data = try fixture("sample", "lha")
        XCTAssertEqual(try LibArchive.extractEntry(path: "hola.txt", in: data),
                       Data("Hola mundo lha".utf8))
        XCTAssertEqual(try LibArchive.extractEntry(path: "config.json", in: data),
                       Data(#"{"clave":"valor"}"#.utf8))
    }

    // MARK: - RAR (formato 4.x, método storing 0x30)

    /// El fixture `sample.rar` contiene hola.txt (14 B) y config.json (17 B).
    func testRarListsEntries() throws {
        let (entries, encrypted) = try LibArchive.listEntries(in: fixture("sample", "rar"))
        XCTAssertFalse(encrypted)

        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("hola.txt"))
        XCTAssertTrue(paths.contains("config.json"))

        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(hola.uncompressedSize, 14)
        XCTAssertFalse(hola.isDirectory)
    }

    func testRarExtractsContent() throws {
        let data = try fixture("sample", "rar")
        XCTAssertEqual(try LibArchive.extractEntry(path: "hola.txt", in: data),
                       Data("Hola mundo rar".utf8))
        XCTAssertEqual(try LibArchive.extractEntry(path: "config.json", in: data),
                       Data(#"{"clave":"valor"}"#.utf8))
    }

    // MARK: - RAR5 real (generado con WinRAR/rar 7.23)

    /// RAR5 **comprimido y sin cifrar**: libarchive reimplementa la descompresión RAR5, así que
    /// listamos y extraemos de verdad (incluida una entrada grande y compresible).
    func testRar5CompressedUnencrypted() throws {
        let data = try fixture("comp-rar5", "rar")
        let (entries, encrypted) = try LibArchive.listEntries(in: data)
        XCTAssertFalse(encrypted)
        XCTAssertEqual(Set(entries.map(\.path)),
                       ["hola.txt", "config.json", "anidado.txt", "repetido.txt"])

        XCTAssertEqual(try LibArchive.extractEntry(path: "hola.txt", in: data),
                       Data("Hola mundo rar".utf8))
        // "ABCD" × 5000 = 20 000 B: comprime muy bien, obliga a la descompresión real.
        XCTAssertEqual(try LibArchive.extractEntry(path: "repetido.txt", in: data),
                       Data(String(repeating: "ABCD", count: 5000).utf8))
    }

    /// **Limitación conocida y verificada**: la libarchive del sistema NO descifra RAR
    /// (ni RAR4 ni RAR5); solo el `unrar` propietario lo hace. Detecta el cifrado de cabeceras
    /// (`passphraseRequired`) pero **con la clave correcta sigue fallando**. Este test fija la
    /// conducta actual: si un macOS futuro añade descifrado RAR, saltará y habrá que revisarlo.
    /// (Fixture `enc-rar5-headers.rar`, clave real "clave123", comprobada con `unrar`.)
    func testRar5EncryptedHeadersNotDecryptable() throws {
        let data = try fixture("enc-rar5-headers", "rar")
        // Sin clave: ni siquiera se listan (cabeceras cifradas).
        XCTAssertThrowsError(try LibArchive.listEntries(in: data)) {
            XCTAssertEqual($0 as? LibArchiveError, .passphraseRequired)
        }
        // Con la clave CORRECTA: libarchive aún no puede descifrar → falla igualmente.
        XCTAssertThrowsError(try LibArchive.listEntries(in: data, passphrase: "clave123")) {
            XCTAssertTrue($0 is LibArchiveError, "esperado un LibArchiveError, no \($0)")
        }
    }

    /// RAR5 con **solo los datos cifrados** (cabeceras en claro): libarchive lista los nombres
    /// —y ni siquiera marca las entradas como cifradas— pero **no puede extraer** con la clave
    /// correcta. Documenta la misma limitación por la vía de extracción.
    func testRar5EncryptedDataNotExtractable() throws {
        let data = try fixture("enc-rar5-data", "rar")
        let (entries, _) = try LibArchive.listEntries(in: data)          // lista sin clave
        XCTAssertTrue(Set(entries.map(\.path)).contains("hola.txt"))
        XCTAssertThrowsError(try LibArchive.extractEntry(path: "hola.txt", in: data, passphrase: "clave123")) {
            XCTAssertTrue($0 is LibArchiveError, "esperado un LibArchiveError, no \($0)")
        }
    }
}
