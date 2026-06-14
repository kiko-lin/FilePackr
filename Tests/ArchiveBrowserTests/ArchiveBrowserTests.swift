import XCTest
@testable import ArchiveBrowser

final class ArchiveBrowserTests: XCTestCase {

    private let reader = ZipReader()

    private func sampleURL() throws -> URL {
        let url = Bundle.module.url(forResource: "sample", withExtension: "zip", subdirectory: "Fixtures")
        return try XCTUnwrap(url, "falta el fixture sample.zip")
    }

    func testListsEntriesWithoutExtracting() throws {
        let entries = try reader.listEntries(at: sampleURL())
        let paths = Set(entries.map(\.path))

        XCTAssertTrue(paths.contains("hola.txt"))
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertTrue(paths.contains("docs/anidado.txt"))
    }

    func testReadsRealSizesFromCentralDirectory() throws {
        let entries = try reader.listEntries(at: sampleURL())
        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })

        // El tamaño real se conoce SIN descomprimir: "Hola mundo cifrado" = 18 bytes.
        XCTAssertEqual(hola.uncompressedSize, 18)
        XCTAssertFalse(hola.isDirectory)
    }

    func testDetectsDirectories() throws {
        let entries = try reader.listEntries(at: sampleURL())
        XCTAssertTrue(entries.contains { $0.path == "docs/" && $0.isDirectory })
    }

    func testBuildsTree() throws {
        let entries = try reader.listEntries(at: sampleURL())
        let tree = ArchiveTreeNode.build(from: entries)

        let names = Set(tree.map(\.name))
        XCTAssertTrue(names.contains("hola.txt"))
        XCTAssertTrue(names.contains("config.json"))

        let docs = try XCTUnwrap(tree.first { $0.name == "docs" })
        XCTAssertTrue(docs.isDirectory)
        XCTAssertTrue(docs.children.contains { $0.name == "anidado.txt" })
    }

    func testRejectsNonZipData() {
        XCTAssertThrowsError(try reader.listEntries(in: Data("esto no es un zip".utf8))) { error in
            XCTAssertEqual(error as? ArchiveError, .notZipArchive)
        }
    }
}
