import XCTest
@testable import ArchiveBrowser

/// El reporte de progreso de la compresión: los escritores informan de los **bytes de entrada**
/// procesados y del **fichero** en curso. La app los acumula contra el total para la barra.
final class WriteProgressTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ZIP de un fichero en streaming: la suma de bytes reportados = tamaño del fichero, con su nombre.
    func testZipReportsInputBytesAndName() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.bin")
        let size = 300_000
        try Data(count: size).write(to: src)

        var reported = 0
        var names: Set<String> = []
        let progress = WriteProgress { file, bytes in names.insert(file); reported += bytes }
        _ = try ZipWriter().build([ZipEntryInput(path: "a.bin", modifiedAt: nil, source: .file(src))],
                                  progress: progress)
        XCTAssertEqual(reported, size)
        XCTAssertEqual(names, ["a.bin"])
    }

    /// El generador TAR reporta los bytes de cuerpo (= tamaño del fichero) y su ruta.
    func testTarReaderReportsInputBytes() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("f.bin")
        let size = 200_000
        try Data(count: size).write(to: src)

        var reported = 0
        var names: Set<String> = []
        let next = Tar.reader([Tar.WriteItem(path: "dir/f.bin", fileURL: src, modifiedAt: nil)],
                              onProgress: WriteProgress { file, bytes in names.insert(file); reported += bytes })
        while try next() != nil {}
        XCTAssertEqual(reported, size)
        XCTAssertEqual(names, ["dir/f.bin"])
    }
}
