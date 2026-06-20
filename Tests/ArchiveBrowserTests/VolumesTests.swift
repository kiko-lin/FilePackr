import XCTest
@testable import ArchiveBrowser

final class VolumesTests: XCTestCase {

    func testPartName() {
        XCTAssertEqual(Volumes.partName(base: "nombre.zip", index: 1), "nombre.zip")
        XCTAssertEqual(Volumes.partName(base: "nombre.zip", index: 2), "nombre_001.zip")
        XCTAssertEqual(Volumes.partName(base: "nombre.zip", index: 3), "nombre_002.zip")
        XCTAssertEqual(Volumes.partName(base: "datos.tar.gz", index: 2), "datos_001.tar.gz")
        XCTAssertEqual(Volumes.partName(base: "sinext", index: 2), "sinext_001")
    }

    func testContinuationVolume() {
        XCTAssertNil(Volumes.continuationVolume("nombre.zip"))
        XCTAssertNil(Volumes.continuationVolume("nombre.tar.gz"))
        let z = Volumes.continuationVolume("nombre_001.zip")
        XCTAssertEqual(z?.base, "nombre.zip")
        XCTAssertEqual(z?.index, 2)
        let g = Volumes.continuationVolume("datos_002.tar.gz")
        XCTAssertEqual(g?.base, "datos.tar.gz")
        XCTAssertEqual(g?.index, 3)
        XCTAssertNil(Volumes.continuationVolume("_001.zip"))   // sin raíz
    }

    func testSplitAndJoinRoundTrip() {
        let data = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let parts = Volumes.split(data, volumeSize: 256)
        XCTAssertEqual(parts.count, 4)                 // 256+256+256+232
        XCTAssertEqual(parts[0].count, 256)
        XCTAssertEqual(parts.last?.count, 232)
        XCTAssertEqual(Volumes.join(parts), data)
    }

    func testSplitExactMultiple() {
        let data = Data(repeating: 0xAB, count: 512)
        let parts = Volumes.split(data, volumeSize: 256)
        XCTAssertEqual(parts.count, 2)                 // sin volumen vacío sobrante
        XCTAssertEqual(Volumes.join(parts), data)
    }

    func testSplitSmallerThanVolume() {
        let data = Data([1, 2, 3])
        XCTAssertEqual(Volumes.split(data, volumeSize: 1024), [data])
    }
}

/// Operaciones de volúmenes sobre disco (movidas del documento al motor): trocear un
/// fichero ya escrito, descubrir las partes de un juego y limpiar restos.
final class VolumeStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSplitDiscoverAndJoin() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("backup.zip")
        let payload = Data((0..<1000).map { UInt8($0 & 0xFF) })
        try payload.write(to: base)

        try await VolumeStore.split(file: base, base: base, volumeSize: 256)

        // base + 3 continuaciones; la primera parte conserva el nombre base.
        let parts = VolumeStore.parts(for: base)
        XCTAssertEqual(parts.map(\.lastPathComponent),
                       ["backup.zip", "backup_001.zip", "backup_002.zip", "backup_003.zip"])
        // Descubrir desde una continuación da el mismo juego.
        XCTAssertEqual(VolumeStore.parts(for: parts[2]), parts)

        let joined = Volumes.join(try parts.map { try Data(contentsOf: $0) })
        XCTAssertEqual(joined, payload)
    }

    func testJoinToTemporaryFileConcatenatesInOrder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("p0"); try Data([1, 2, 3]).write(to: a)
        let b = dir.appendingPathComponent("p1"); try Data([4, 5]).write(to: b)
        let c = dir.appendingPathComponent("p2"); try Data([6]).write(to: c)

        let joined = try VolumeStore.joinToTemporaryFile([a, b, c])
        defer { try? FileManager.default.removeItem(at: joined) }
        XCTAssertEqual(try Data(contentsOf: joined), Data([1, 2, 3, 4, 5, 6]))
    }

    func testRemoveContinuations() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("x.zip")
        try Data([0]).write(to: base)
        try Data([1]).write(to: dir.appendingPathComponent("x_001.zip"))
        try Data([2]).write(to: dir.appendingPathComponent("x_002.zip"))

        VolumeStore.removeContinuations(of: base)

        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
        XCTAssertEqual(VolumeStore.parts(for: base), [base])   // ya no hay juego
    }
}
