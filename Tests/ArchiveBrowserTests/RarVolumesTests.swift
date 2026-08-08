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
}
