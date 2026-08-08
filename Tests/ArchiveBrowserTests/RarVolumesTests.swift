import XCTest
@testable import ArchiveBrowser

/// Detección de los esquemas de nombres **nativos** de RAR multivolumen (los de WinRAR/`rar`,
/// no el propio de FilePackr — ese lo cubre `VolumeStoreTests`). Solo comprobación de nombres
/// y existencia en disco: no hace falta contenido RAR válido, basta con ficheros de relleno.
final class RarVolumesTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws { try Data().write(to: url) }

    // MARK: - Moderno: nombre.part1.rar, nombre.part2.rar…

    func testModernSchemeFromFirstPart() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = dir.appendingPathComponent("pelicula.part1.rar")
        let p2 = dir.appendingPathComponent("pelicula.part2.rar")
        let p3 = dir.appendingPathComponent("pelicula.part3.rar")
        try touch(p1); try touch(p2); try touch(p3)

        XCTAssertEqual(RarVolumes.parts(for: p1), [p1, p2, p3])
    }

    func testModernSchemeFromMiddlePart() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = dir.appendingPathComponent("pelicula.part1.rar")
        let p2 = dir.appendingPathComponent("pelicula.part2.rar")
        let p3 = dir.appendingPathComponent("pelicula.part3.rar")
        try touch(p1); try touch(p2); try touch(p3)

        // Abrir desde una parte intermedia reúne el mismo conjunto desde la primera.
        XCTAssertEqual(RarVolumes.parts(for: p2), [p1, p2, p3])
        XCTAssertEqual(RarVolumes.parts(for: p3), [p1, p2, p3])
    }

    func testModernSchemeRespectsZeroPaddedWidth() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = dir.appendingPathComponent("serie.part01.rar")
        let p2 = dir.appendingPathComponent("serie.part02.rar")
        try touch(p1); try touch(p2)

        XCTAssertEqual(RarVolumes.parts(for: p1), [p1, p2])
        XCTAssertEqual(RarVolumes.parts(for: p2), [p1, p2])
    }

    func testModernSchemeSinglePartReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = dir.appendingPathComponent("suelto.part1.rar")
        try touch(p1)

        XCTAssertNil(RarVolumes.parts(for: p1))
    }

    // MARK: - Legado: nombre.rar, nombre.r00, nombre.r01…

    func testLegacySchemeFromBase() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("informe.rar")
        let r00 = dir.appendingPathComponent("informe.r00")
        let r01 = dir.appendingPathComponent("informe.r01")
        try touch(base); try touch(r00); try touch(r01)

        XCTAssertEqual(RarVolumes.parts(for: base), [base, r00, r01])
    }

    func testLegacySchemeFromContinuation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("informe.rar")
        let r00 = dir.appendingPathComponent("informe.r00")
        let r01 = dir.appendingPathComponent("informe.r01")
        try touch(base); try touch(r00); try touch(r01)

        XCTAssertEqual(RarVolumes.parts(for: r00), [base, r00, r01])
        XCTAssertEqual(RarVolumes.parts(for: r01), [base, r00, r01])
    }

    func testLegacyContinuationWithoutBaseReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r00 = dir.appendingPathComponent("huerfano.r00")
        try touch(r00)

        XCTAssertNil(RarVolumes.parts(for: r00))
    }

    func testLegacySingleFileReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("solo.rar")
        try touch(base)

        XCTAssertNil(RarVolumes.parts(for: base))
    }

    // MARK: - No es RAR nativo

    func testFilePackrOwnSchemeIsNotMistakenForRarNative() throws {
        // Esquema propio de FilePackr (_001.rar): no es el esquema nativo de RAR, así que
        // `RarVolumes` no debe reconocerlo (lo cubre `VolumeStore`, no este tipo).
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("propio.rar")
        let cont = dir.appendingPathComponent("propio_001.rar")
        try touch(base); try touch(cont)

        XCTAssertNil(RarVolumes.parts(for: base))
    }

    func testUnrelatedFileReturnsNil() {
        XCTAssertNil(RarVolumes.parts(for: URL(fileURLWithPath: "/tmp/foo.zip")))
    }

    // MARK: - isMultiVolumePart: ¿declara la propia cabecera pertenecer a un conjunto?

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testIsMultiVolumePartRAR4Positive() throws {
        // volumes.part1.rar/.part2.rar (docs/fixtures/make_rar_volumes.py) llevan MHD_VOLUME.
        XCTAssertTrue(RarVolumes.isMultiVolumePart(try fixture("volumes.part1")))
        XCTAssertTrue(RarVolumes.isMultiVolumePart(try fixture("volumes.part2")))
    }

    func testIsMultiVolumePartRAR4Negative() throws {
        // sample.rar (docs/fixtures/make_rar.py) no lleva la bandera: flags 0x0000.
        XCTAssertFalse(RarVolumes.isMultiVolumePart(try fixture("sample")))
    }

    /// Cabecera RAR5 mínima fabricada a mano (no un archivo válido — solo lo justo para ejercitar
    /// el parseo de vints): marcador(8) + CRC32 dummy(4) + vint HeaderSize + vint HeaderType(1) +
    /// vint HeaderFlags(0, sin área extra) + vint ArchiveFlags.
    private func rar5Header(archiveFlags: UInt8, headerType: UInt8 = 1) -> Data {
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]   // marcador
        bytes += [0, 0, 0, 0]        // CRC32 (no se valida)
        bytes += [0x05]              // vint HeaderSize (valor arbitrario, no se valida)
        bytes += [headerType]        // vint HeaderType
        bytes += [0x00]              // vint HeaderFlags (sin área extra)
        bytes += [archiveFlags]      // vint ArchiveFlags
        return Data(bytes)
    }

    func testIsMultiVolumePartRAR5Positive() {
        XCTAssertTrue(RarVolumes.isMultiVolumePart(rar5Header(archiveFlags: 0x01)))   // primer volumen
        XCTAssertTrue(RarVolumes.isMultiVolumePart(rar5Header(archiveFlags: 0x03)))   // continuación
    }

    func testIsMultiVolumePartRAR5Negative() {
        XCTAssertFalse(RarVolumes.isMultiVolumePart(rar5Header(archiveFlags: 0x00)))
        // Bloque tipo distinto de "cabecera principal" (1): no es donde vive MHD_VOLUME.
        XCTAssertFalse(RarVolumes.isMultiVolumePart(rar5Header(archiveFlags: 0x01, headerType: 2)))
    }

    func testIsMultiVolumePartNeverThrowsOnBadInput() {
        XCTAssertFalse(RarVolumes.isMultiVolumePart(Data()))
        XCTAssertFalse(RarVolumes.isMultiVolumePart(Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])))   // solo marcador RAR5
        XCTAssertFalse(RarVolumes.isMultiVolumePart(Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])))          // solo marcador RAR4
        XCTAssertFalse(RarVolumes.isMultiVolumePart(Data(repeating: 0xFF, count: 40)))   // basura, no-RAR
    }
}
