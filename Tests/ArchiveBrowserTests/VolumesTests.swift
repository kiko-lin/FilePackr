import XCTest
@testable import ArchiveBrowser

final class VolumesTests: XCTestCase {

    func testPartExtension() {
        XCTAssertEqual(Volumes.partExtension(1), "001")
        XCTAssertEqual(Volumes.partExtension(12), "012")
        XCTAssertEqual(Volumes.partExtension(7), "007")
    }

    func testIsPartExtension() {
        XCTAssertTrue(Volumes.isPartExtension("001"))
        XCTAssertTrue(Volumes.isPartExtension("2"))
        XCTAssertFalse(Volumes.isPartExtension("zip"))
        XCTAssertFalse(Volumes.isPartExtension("7z"))
        XCTAssertFalse(Volumes.isPartExtension(""))
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
