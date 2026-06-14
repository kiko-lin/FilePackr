import XCTest
@testable import ArchiveBrowser

/// Tests de gzip y TAR, con interoperabilidad contra `gzip`/`gunzip`/`tar` del sistema.
final class FormatsTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func run(_ path: String, _ args: [String], cwd: URL? = nil, stdin: Data? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        if let stdin { let inPipe = Pipe(); p.standardInput = inPipe; try p.run(); inPipe.fileHandleForWriting.write(stdin); inPipe.fileHandleForWriting.closeFile() }
        else { try p.run() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    // MARK: gzip

    func testGzipRoundTrip() throws {
        let payload = Data(String(repeating: "contenido gzip ñ áé ", count: 200).utf8)
        let gz = Gzip.compress(payload, filename: "doc.txt")
        XCTAssertEqual(try Gzip.decompress(gz), payload)
        XCTAssertEqual(Gzip.storedFilename(gz), "doc.txt")
        XCTAssertLessThan(gz.count, payload.count, "el texto repetido debe comprimir")
    }

    func testGzipEmpty() throws {
        XCTAssertEqual(try Gzip.decompress(Gzip.compress(Data())), Data())
    }

    func testSystemGunzipReadsOurGzip() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/gunzip"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("datos para gunzip del sistema".utf8)
        let url = dir.appendingPathComponent("f.gz")
        try Gzip.compress(payload).write(to: url)
        let out = try run("/usr/bin/gunzip", ["-c", url.path])
        XCTAssertEqual(out, payload)
    }

    func testReadsSystemGzip() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/gzip"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = "creado por el gzip del sistema"
        try payload.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/gzip", ["f.txt"], cwd: dir)
        let gz = try Data(contentsOf: dir.appendingPathComponent("f.txt.gz"))
        XCTAssertEqual(String(decoding: try Gzip.decompress(gz), as: UTF8.self), payload)
    }

    // MARK: TAR

    func testTarRoundTrip() throws {
        let items = [
            Tar.WriteItem(path: "a.txt", data: Data("primero".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "dir", data: Data(), modifiedAt: nil, isDirectory: true),
            Tar.WriteItem(path: "dir/b.bin", data: Data((0..<300).map { UInt8($0 & 0xFF) }), modifiedAt: nil, isDirectory: false),
        ]
        let tar = Tar.write(items)
        let entries = try Tar.listEntries(in: tar)
        XCTAssertEqual(Set(entries.map(\.path)), ["a.txt", "dir/", "dir/b.bin"])
        let b = try XCTUnwrap(entries.first { $0.path == "dir/b.bin" })
        XCTAssertEqual(try Tar.entryData(for: b, in: tar).count, 300)
    }

    func testReadsSystemTar() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hola".write(to: dir.appendingPathComponent("hola.txt"), atomically: true, encoding: .utf8)
        try "anidado".write(to: dir.appendingPathComponent("sub/x.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-cf", "out.tar", "hola.txt", "sub"], cwd: dir)

        let tar = try Data(contentsOf: dir.appendingPathComponent("out.tar"))
        let entries = try Tar.listEntries(in: tar)
        let hola = try XCTUnwrap(entries.first { $0.path == "hola.txt" })
        XCTAssertEqual(String(decoding: try Tar.entryData(for: hola, in: tar), as: UTF8.self), "hola")
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("x.txt") })
    }

    func testSystemTarReadsOurTar() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tar = Tar.write([
            Tar.WriteItem(path: "leeme.txt", data: Data("escrito por FilePackr".utf8), modifiedAt: nil, isDirectory: false),
        ])
        let url = dir.appendingPathComponent("ours.tar")
        try tar.write(to: url)
        let listing = String(decoding: try run("/usr/bin/tar", ["-tf", url.path]), as: UTF8.self)
        XCTAssertTrue(listing.contains("leeme.txt"))
        let content = String(decoding: try run("/usr/bin/tar", ["-xOf", url.path, "leeme.txt"]), as: UTF8.self)
        XCTAssertEqual(content, "escrito por FilePackr")
    }

    func testTarGzipRoundTrip() throws {
        // .tar.gz = TAR + gzip
        let tar = Tar.write([
            Tar.WriteItem(path: "uno.txt", data: Data(String(repeating: "x", count: 500).utf8), modifiedAt: nil, isDirectory: false),
        ])
        let targz = Gzip.compress(tar)
        let recoveredTar = try Gzip.decompress(targz)
        XCTAssertEqual(recoveredTar, tar)
        let entries = try Tar.listEntries(in: recoveredTar)
        XCTAssertEqual(entries.first?.path, "uno.txt")
    }

    // MARK: xz

    func testXzRoundTrip() throws {
        let payload = Data(String(repeating: "contenido xz ñ áé ", count: 300).utf8)
        let xz = Xz.compress(payload)
        XCTAssertEqual(Array(xz.prefix(6)), [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])  // firma .xz
        XCTAssertEqual(try Xz.decompress(xz), payload)
        XCTAssertEqual(Xz.uncompressedSize(of: xz), UInt64(payload.count))
        XCTAssertLessThan(xz.count, payload.count)
    }

    func testXzEmpty() throws {
        XCTAssertEqual(try Xz.decompress(Xz.compress(Data())), Data())
    }

    func testPythonReadsOurXz() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("datos para liblzma del sistema".utf8)
        let url = dir.appendingPathComponent("f.xz")
        try Xz.compress(payload).write(to: url)
        let out = try run(python, ["-c", "import lzma,sys; sys.stdout.buffer.write(lzma.open(sys.argv[1]).read())", url.path])
        XCTAssertEqual(out, payload)
    }

    func testReadsPythonXz() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.xz")
        _ = try run(python, ["-c", "import lzma; open('\(url.path)','wb').write(lzma.compress(b'creado por liblzma'))"])
        let xz = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: try Xz.decompress(xz), as: UTF8.self), "creado por liblzma")
    }

    func testReadsBsdtarTarXz() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try "hola xz".write(to: dir.appendingPathComponent("hola.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-cJf", "out.tar.xz", "hola.txt"], cwd: dir)

        let xz = try Data(contentsOf: dir.appendingPathComponent("out.tar.xz"))
        let tar = try Xz.decompress(xz)
        let entry = try XCTUnwrap(try Tar.listEntries(in: tar).first { $0.path == "hola.txt" })
        XCTAssertEqual(String(decoding: try Tar.entryData(for: entry, in: tar), as: UTF8.self), "hola xz")
    }

    func testBsdtarReadsOurTarXz() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tarxz = Xz.compress(Tar.write([
            Tar.WriteItem(path: "leeme.txt", data: Data("escrito por FilePackr".utf8), modifiedAt: nil, isDirectory: false),
        ]))
        let url = dir.appendingPathComponent("ours.tar.xz")
        try tarxz.write(to: url)
        let listing = String(decoding: try run("/usr/bin/tar", ["-tJf", url.path]), as: UTF8.self)
        XCTAssertTrue(listing.contains("leeme.txt"))
        let content = String(decoding: try run("/usr/bin/tar", ["-xOJf", url.path, "leeme.txt"]), as: UTF8.self)
        XCTAssertEqual(content, "escrito por FilePackr")
    }

    // MARK: bzip2

    func testBzip2RoundTrip() throws {
        let payload = Data(String(repeating: "contenido bzip2 ñ áé ", count: 300).utf8)
        let bz = Bzip2.compress(payload)
        XCTAssertEqual(Array(bz.prefix(3)), [0x42, 0x5A, 0x68])  // "BZh"
        XCTAssertEqual(try Bzip2.decompress(bz), payload)
        XCTAssertLessThan(bz.count, payload.count)
    }

    func testBzip2Empty() throws {
        XCTAssertEqual(try Bzip2.decompress(Bzip2.compress(Data())), Data())
    }

    func testSystemBunzip2ReadsOurBz2() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/bunzip2"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("datos para bunzip2 del sistema".utf8)
        try Bzip2.compress(payload).write(to: dir.appendingPathComponent("f.bz2"))
        let out = try run("/usr/bin/bunzip2", ["-c", dir.appendingPathComponent("f.bz2").path])
        XCTAssertEqual(out, payload)
    }

    func testReadsSystemBz2() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/bzip2"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let payload = "creado por el bzip2 del sistema"
        try payload.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/bzip2", ["f.txt"], cwd: dir)
        let bz = try Data(contentsOf: dir.appendingPathComponent("f.txt.bz2"))
        XCTAssertEqual(String(decoding: try Bzip2.decompress(bz), as: UTF8.self), payload)
    }

    func testBsdtarReadsOurTarBz2() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tarbz = Bzip2.compress(Tar.write([
            Tar.WriteItem(path: "leeme.txt", data: Data("escrito por FilePackr".utf8), modifiedAt: nil, isDirectory: false),
        ]))
        let url = dir.appendingPathComponent("ours.tar.bz2")
        try tarbz.write(to: url)
        let listing = String(decoding: try run("/usr/bin/tar", ["-tjf", url.path]), as: UTF8.self)
        XCTAssertTrue(listing.contains("leeme.txt"))
        let content = String(decoding: try run("/usr/bin/tar", ["-xOjf", url.path, "leeme.txt"]), as: UTF8.self)
        XCTAssertEqual(content, "escrito por FilePackr")
    }

    func testReadsBsdtarTarBz2() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try "hola bz2".write(to: dir.appendingPathComponent("hola.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-cjf", "out.tar.bz2", "hola.txt"], cwd: dir)
        let tar = try Bzip2.decompress(try Data(contentsOf: dir.appendingPathComponent("out.tar.bz2")))
        let entry = try XCTUnwrap(try Tar.listEntries(in: tar).first { $0.path == "hola.txt" })
        XCTAssertEqual(String(decoding: try Tar.entryData(for: entry, in: tar), as: UTF8.self), "hola bz2")
    }

    // MARK: 7z (libarchive)

    func testSevenZipRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.7z")
        try LibArchive.write([
            .init(path: "a.txt", data: Data("primero 7z".utf8), modifiedAt: nil, isDirectory: false),
            .init(path: "dir", data: Data(), modifiedAt: nil, isDirectory: true),
            .init(path: "dir/b.bin", data: Data((0..<400).map { UInt8($0 & 0xFF) }), modifiedAt: nil, isDirectory: false),
        ], to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), [0x37, 0x7A])   // "7z" magic (37 7A BC AF 27 1C)
        let (entries, encrypted) = try LibArchive.listEntries(in: data)
        XCTAssertFalse(encrypted)
        XCTAssertTrue(Set(entries.map(\.path)).isSuperset(of: ["a.txt", "dir/b.bin"]))
        XCTAssertEqual(String(decoding: try LibArchive.extractEntry(path: "a.txt", in: data), as: UTF8.self), "primero 7z")
        XCTAssertEqual(try LibArchive.extractEntry(path: "dir/b.bin", in: data).count, 400)
    }

    func testBsdtarReadsOur7z() throws {
        // Cross-check con el front-end bsdtar (misma libarchive del sistema).
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"))
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ours.7z")
        try LibArchive.write([
            .init(path: "leeme.txt", data: Data("escrito por FilePackr".utf8), modifiedAt: nil, isDirectory: false),
        ], to: url)
        let content = String(decoding: try run("/usr/bin/tar", ["-xOf", url.path, "leeme.txt"]), as: UTF8.self)
        XCTAssertEqual(content, "escrito por FilePackr")
    }

    func testXarRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.xar")
        try LibArchive.write([
            .init(path: "leeme.txt", data: Data("contenido xar".utf8), modifiedAt: nil, isDirectory: false),
        ], to: url, format: .xar)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x78, 0x61, 0x72, 0x21])   // "xar!"
        XCTAssertEqual(String(decoding: try LibArchive.extractEntry(path: "leeme.txt", in: data), as: UTF8.self), "contenido xar")
    }

    func testIsoRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.iso")
        try LibArchive.write([
            .init(path: "leeme.txt", data: Data("contenido iso".utf8), modifiedAt: nil, isDirectory: false),
        ], to: url, format: .iso)
        let data = try Data(contentsOf: url)
        let entry = try XCTUnwrap(try LibArchive.listEntries(in: data).entries.first { $0.path.contains("leeme") })
        XCTAssertEqual(String(decoding: try LibArchive.extractEntry(path: entry.path, in: data), as: UTF8.self), "contenido iso")
    }
}
