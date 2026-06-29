import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Tests directos de los colaboradores puros extraídos de `ArchiveDocument`: nombre único,
/// throttle de progreso y construcción del árbol. Antes solo tenían cobertura indirecta.
@MainActor
final class HelpersTests: XCTestCase {

    // MARK: - UniqueName

    func testUniqueNameReturnsOriginalWhenFree() {
        XCTAssertEqual(UniqueName.next(for: "foto.jpg") { _ in false }, "foto.jpg")
    }

    func testUniqueNamePicksSuffixPreservingExtension() {
        let taken: Set<String> = ["foto.jpg"]
        XCTAssertEqual(UniqueName.next(for: "foto.jpg") { taken.contains($0) }, "foto 2.jpg")
    }

    func testUniqueNameSkipsConsecutiveCollisions() {
        let taken: Set<String> = ["foto.jpg", "foto 2.jpg", "foto 3.jpg"]
        XCTAssertEqual(UniqueName.next(for: "foto.jpg") { taken.contains($0) }, "foto 4.jpg")
    }

    func testUniqueNameWithoutExtension() {
        let taken: Set<String> = ["Nueva carpeta"]
        XCTAssertEqual(UniqueName.next(for: "Nueva carpeta") { taken.contains($0) }, "Nueva carpeta 2")
    }

    func testUniqueNameCompoundExtensionSplitsOnLastDot() {
        // NSString.pathExtension parte por el último punto: «foo.tar» + « 2» + «.gz».
        let taken: Set<String> = ["foo.tar.gz"]
        XCTAssertEqual(UniqueName.next(for: "foo.tar.gz") { taken.contains($0) }, "foo.tar 2.gz")
    }

    // MARK: - ProgressThrottle

    func testProgressThrottleReportsAboutEveryOnePercent() {
        var t = ProgressThrottle()
        XCTAssertFalse(t.shouldReport(0.005), "menos de 1% acumulado: no se reporta")
        XCTAssertTrue(t.shouldReport(0.01), "1% acumulado: se reporta")
        XCTAssertFalse(t.shouldReport(0.015), "menos de 1% desde el último reporte: no")
        XCTAssertTrue(t.shouldReport(0.02), "otro 1%: sí")
    }

    func testProgressThrottleAlwaysReportsCompletion() {
        var t = ProgressThrottle()
        _ = t.shouldReport(0.995)
        XCTAssertTrue(t.shouldReport(1.0), "el 100% se reporta siempre, aunque el salto sea <1%")
    }

    // MARK: - ArchiveTreeBuilder.build

    func testBuildReconstructsHierarchyFromEntries() {
        let entries = [
            ArchiveEntry(path: "a/b.txt", compressedSize: 1, uncompressedSize: 1,
                         isDirectory: false, modificationDate: nil, isEncrypted: false),
            ArchiveEntry(path: "a/sub/c.txt", compressedSize: 1, uncompressedSize: 1,
                         isDirectory: false, modificationDate: nil, isEncrypted: false),
            ArchiveEntry(path: "d.txt", compressedSize: 1, uncompressedSize: 1,
                         isDirectory: false, modificationDate: nil, isEncrypted: false),
        ]
        let roots = ArchiveTreeBuilder.build(from: entries)

        XCTAssertEqual(Set(roots.map(\.name)), ["a", "d.txt"])
        let a = try! XCTUnwrap(roots.first { $0.name == "a" })
        XCTAssertTrue(a.isDirectory)
        XCTAssertEqual(Set(a.children.map(\.name)), ["b.txt", "sub"])   // crea la carpeta intermedia
        let sub = try! XCTUnwrap(a.children.first { $0.name == "sub" })
        XCTAssertEqual(sub.children.map(\.name), ["c.txt"])
    }

    func testBuildStripsLeadingDotSegmentFromTar() {
        let entries = [
            ArchiveEntry(path: "./x.txt", compressedSize: 1, uncompressedSize: 1,
                         isDirectory: false, modificationDate: nil, isEncrypted: false),
        ]
        XCTAssertEqual(ArchiveTreeBuilder.build(from: entries).map(\.name), ["x.txt"])
    }

    // MARK: - ArchiveTreeBuilder.importFromDisk

    func testImportFromDiskExpandsFolderAndCountsExcluded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = dir.appendingPathComponent("carpeta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("visible.txt"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = ArchiveTreeBuilder.importFromDisk(folder, hiddenPolicy: .excludeSystemFiles)
        XCTAssertTrue(result.node.isDirectory)
        XCTAssertEqual(result.node.children.map(\.name), ["visible.txt"])
        XCTAssertEqual(result.excluded, 1, "el .DS_Store cuenta como omitido")
    }
}
