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
