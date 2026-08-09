import XCTest
@testable import ArchiveBrowser

/// Formatos **solo de lectura** de libarchive (cpio/cab/lha/rar): no los escribimos, así que
/// no hay round-trip posible. Se prueban contra **fixtures reales** generados por herramientas
/// externas (ver `Fixtures/`), comprobando que `listEntries`/`extractEntry` los interpretan.
final class LibArchiveFixtureTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name, ext))
    }

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "falta el fixture \(name).\(ext)")
    }

    // MARK: - CPIO (formato newc / SVR4, generado con /usr/bin/cpio)

    /// El fixture `sample.cpio` contiene: hola.txt (15 B), config.json (17 B),
    /// docs/anidado.txt (17 B) y el directorio docs/.
    func testCpioListsEntries() throws {
        let (entries, encrypted, _) = try LibArchive.listEntries(in: fixture("sample", "cpio"))
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
        let (entries, encrypted, _) = try LibArchive.listEntries(in: fixture("sample", "cab"))
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
        let (entries, encrypted, _) = try LibArchive.listEntries(in: fixture("sample", "lha"))
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
        let (entries, encrypted, _) = try LibArchive.listEntries(in: fixture("sample", "rar"))
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
        let (entries, encrypted, _) = try LibArchive.listEntries(in: data)
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
        let (entries, _, _) = try LibArchive.listEntries(in: data)          // lista sin clave
        XCTAssertTrue(Set(entries.map(\.path)).contains("hola.txt"))
        XCTAssertThrowsError(try LibArchive.extractEntry(path: "hola.txt", in: data, passphrase: "clave123")) {
            XCTAssertTrue($0 is LibArchiveError, "esperado un LibArchiveError, no \($0)")
        }
    }

    // MARK: - RAR multivolumen nativo (fabricado a mano, ver docs/fixtures/make_rar_volumes.py)

    /// `volumes.part1.rar`/`volumes.part2.rar` (mismos bytes que `volumes.rar`/`volumes.r00`,
    /// solo cambia el nombre — la convención de nombres no afecta al formato interno): un
    /// fichero ("partido.txt") partido entre los dos volúmenes y otro ("entero.txt") entero en
    /// el segundo. Se abren con `LibArchive.listEntries(volumes:)`, vía
    /// `archive_read_open_filenames` — no se pueden concatenar a pelo como el esquema propio de
    /// FilePackr, cada volumen lleva su propia cabecera intercalada.
    func testRarVolumesListsEntries() throws {
        let v1 = try fixtureURL("volumes.part1", "rar")
        let v2 = try fixtureURL("volumes.part2", "rar")
        let (entries, encrypted, truncated) = try LibArchive.listEntries(volumes: [v1, v2])
        XCTAssertFalse(encrypted)
        XCTAssertFalse(truncated, "están las dos partes: no debería marcarse incompleto")

        let paths = Set(entries.map(\.path))
        XCTAssertEqual(paths, ["partido.txt", "entero.txt"])
        let partido = try XCTUnwrap(entries.first { $0.path == "partido.txt" })
        XCTAssertEqual(partido.uncompressedSize, 61, "el tamaño declarado es el del fichero completo, no el trozo del volumen 1")
    }

    /// Si solo se pasa el primer volumen (el segundo no aparece, esté o no reconocido su
    /// nombre), `archive_read_open_filenames` debe devolver lo que sí pudo leer (`partido.txt`,
    /// aunque truncado) en vez de lanzar y perderlo todo — con este fixture concreto el corte
    /// cae justo en un borde de bloque (EOF limpio, sin marcar `truncated`), así que no se
    /// comprueba ese flag aquí; lo importante es que la entrada sobrevive. Ver
    /// `testTruncatedRar5RecoversEntriesReadBeforeTheCut` para un caso que sí marca `truncated`.
    func testRarVolumesWithOnlyFirstPartReturnsPartialEntries() throws {
        let v1 = try fixtureURL("volumes.part1", "rar")
        let (entries, _, _) = try LibArchive.listEntries(volumes: [v1])
        XCTAssertEqual(Set(entries.map(\.path)), ["partido.txt"])
    }

    func testRarVolumesExtractsContentAcrossBoundary() throws {
        let v1 = try fixtureURL("volumes.part1", "rar")
        let v2 = try fixtureURL("volumes.part2", "rar")
        var partido = Data()
        try LibArchive.extractEntry(path: "partido.txt", volumes: [v1, v2]) { partido.append($0) }
        XCTAssertEqual(partido, Data("Contenido partido entre dos volumenes RAR nativos, de verdad.".utf8))

        var entero = Data()
        try LibArchive.extractEntry(path: "entero.txt", volumes: [v1, v2]) { entero.append($0) }
        XCTAssertEqual(entero, Data("Este fichero vive entero en el segundo volumen.".utf8))
    }

    /// `extractEntries` (recorrido único, el que usa `LibArchiveCodec.extractAll` — Extraer/
    /// Extraer todo/arrastre al Finder) también funciona a través del límite de volumen.
    func testRarVolumesExtractEntriesSinglePass() throws {
        let v1 = try fixtureURL("volumes.part1", "rar")
        let v2 = try fixtureURL("volumes.part2", "rar")
        var results: [String: Data] = [:]
        try LibArchive.extractEntries(["partido.txt", "entero.txt"], volumes: [v1, v2]) { path in
            { chunk in results[path, default: Data()].append(chunk) }
        }
        XCTAssertEqual(results["partido.txt"], Data("Contenido partido entre dos volumenes RAR nativos, de verdad.".utf8))
        XCTAssertEqual(results["entero.txt"], Data("Este fichero vive entero en el segundo volumen.".utf8))
    }

    /// Mismos bytes, esquema de nombres **legado** (`.rar` + `.r00`): la lectura no depende de
    /// cómo se llamen los ficheros, solo del orden en que se pasan.
    func testRarVolumesLegacyNamingReadsIdentically() throws {
        let v1 = try fixtureURL("volumes", "rar")
        let v2 = try fixtureURL("volumes", "r00")
        let (entries, _, _) = try LibArchive.listEntries(volumes: [v1, v2])
        XCTAssertEqual(Set(entries.map(\.path)), ["partido.txt", "entero.txt"])
    }

    // MARK: - Truncamiento (mejor esfuerzo, ver LibArchive.classifyFailure)

    /// Cortar `comp-rar5.rar` al 90 % cae a mitad de los datos de la última entrada (verificado
    /// a mano): las cabeceras de las 4 entradas ya se han leído para entonces, así que
    /// `listEntries` debe devolverlas todas marcadas `truncated`, no lanzar y perderlas — es
    /// exactamente el caso real de un RAR multivolumen al que le falta la última parte.
    func testTruncatedRar5RecoversEntriesReadBeforeTheCut() throws {
        let full = try fixture("comp-rar5", "rar")
        let truncated = Data(full.prefix(Int(Double(full.count) * 0.9)))
        let (entries, _, wasTruncated) = try LibArchive.listEntries(in: truncated)
        XCTAssertTrue(wasTruncated)
        XCTAssertEqual(Set(entries.map(\.path)),
                       ["hola.txt", "config.json", "anidado.txt", "repetido.txt"])
    }

    /// Si el corte cae tan pronto que ni siquiera la primera cabecera se puede leer del todo,
    /// libarchive no siempre lo trata como error: para RAR5 suele dar un EOF limpio sin haber
    /// podido identificar ninguna entrada — `listEntries` no lanza (fiel a lo que reporta
    /// libarchive), simplemente no hay nada en `entries`. Es la propia `ArchiveDocument` la que,
    /// más arriba, convierte "0 entradas" en el error de conjunto incompleto — ver
    /// `RarVolumesDocumentTests`.
    func testTruncatedRar5TooShortForAnyHeaderReturnsEmptyWithoutThrowing() throws {
        let full = try fixture("comp-rar5", "rar")
        let truncated = Data(full.prefix(20))   // marcador + cabecera principal a medias
        let (entries, _, _) = try LibArchive.listEntries(in: truncated)
        XCTAssertTrue(entries.isEmpty)
    }

    /// Un corte tan agresivo que ni el formato se reconoce sí sigue siendo un error real.
    func testTruncatedRar5UnrecognizableStillThrows() throws {
        let full = try fixture("comp-rar5", "rar")
        let truncated = Data(full.prefix(2))
        XCTAssertThrowsError(try LibArchive.listEntries(in: truncated))
    }
}
