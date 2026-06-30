import XCTest
@testable import ArchiveBrowser

/// El registro `ArchiveFormat.codec` debe leer y extraer cada familia de formato, y
/// refinar gz/xz/bz2 sueltos vs `.tar.<x>`, igual que hacía el switch del documento.
final class ArchiveCodecTests: XCTestCase {

    private let hello = Data("hola códec".utf8)

    func testZipCodecRoundTrip() throws {
        let zip = try ZipWriter().build([
            ZipEntryInput(path: "a.txt", modifiedAt: nil, source: .data(hello)),
        ])
        let result = try ArchiveFormat.zip.codec.open(zip, fallbackName: "a")
        XCTAssertEqual(result.format, .zip)
        XCTAssertEqual(result.entries.map(\.path), ["a.txt"])
        let data = try result.format.codec.entryData(for: result.entries[0], in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    func testGzipCodecKeepsSingleFile() throws {
        let gz = Gzip.compress(hello, filename: "nota.txt")
        let result = try ArchiveFormat.gzip.codec.open(gz, fallbackName: "nota")
        XCTAssertEqual(result.format, .gzip, "un .gz suelto no debe confundirse con tar.gz")
        XCTAssertEqual(result.entries.count, 1)
        // El nombre (FNAME) y el tamaño (ISIZE) se leen de la cabecera/pie sin inflar el .gz.
        XCTAssertEqual(result.entries[0].path, "nota.txt")
        XCTAssertEqual(result.entries[0].uncompressedSize, UInt64(hello.count))
        let data = try result.format.codec.entryData(for: result.entries[0], in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    func testGzipCodecRefinesToTarGzip() throws {
        let tar = Tar.write([
            Tar.WriteItem(path: "dir/uno.txt", data: hello, modifiedAt: nil, isDirectory: false),
        ])
        let targz = Gzip.compress(tar)
        // Se abre como `.gz` (detección por nombre) pero el codec debe refinar a `.tarGzip`.
        let result = try ArchiveFormat.gzip.codec.open(targz, fallbackName: "paquete")
        XCTAssertEqual(result.format, .tarGzip)
        XCTAssertTrue(result.entries.contains { $0.path == "dir/uno.txt" })
        let entry = try XCTUnwrap(result.entries.first { $0.path == "dir/uno.txt" })
        let data = try result.format.codec.entryData(for: entry, in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    /// El item 3: los metadatos de ZIP solo aparecen en entradas de ZIP; los demás
    /// formatos no inventan campos. TAR expone su `dataOffset`; ZIP no (usa el local header).
    func testEntryMetadataIsFormatSpecific() throws {
        let zip = try ZipWriter().build([ZipEntryInput(path: "a.txt", modifiedAt: nil, source: .data(hello))])
        let zipEntry = try XCTUnwrap(try ZipReader().listEntries(in: zip).first)
        XCTAssertNotNil(zipEntry.zip, "una entrada de ZIP debe llevar su ZipEntryInfo")
        XCTAssertNil(zipEntry.dataOffset, "ZIP no usa dataOffset (extrae vía local header)")

        let tar = Tar.write([Tar.WriteItem(path: "b.txt", data: hello, modifiedAt: nil, isDirectory: false)])
        let tarEntry = try XCTUnwrap(try Tar.listEntries(in: tar).first)
        XCTAssertNil(tarEntry.zip, "una entrada de TAR no debe arrastrar metadatos de ZIP")
        XCTAssertNotNil(tarEntry.dataOffset, "TAR sí expone el offset de los datos")

        let gzEntry = try XCTUnwrap(Gzip.entries(in: Gzip.compress(hello), fallbackName: "c").first)
        XCTAssertNil(gzEntry.zip)
        XCTAssertFalse(gzEntry.isAESEncrypted)
    }

    func testTarCodecRoundTrip() throws {
        let tar = Tar.write([
            Tar.WriteItem(path: "x.bin", data: hello, modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tar.codec.open(tar, fallbackName: "x")
        XCTAssertEqual(result.format, .tar)
        let entry = try XCTUnwrap(result.entries.first { $0.path == "x.bin" })
        let data = try result.format.codec.entryData(for: entry, in: result.container, password: nil)
        XCTAssertEqual(data, hello)
    }

    /// Fase 3b / §10 #4–#5 (invariante de memoria): abrir un `.tar.gz` **no** debe inflar el TAR
    /// en RAM. El `container` que se conserva son los bytes **comprimidos** (los mismos que
    /// entraron, para mantenerlos mapeados), no el TAR descomprimido. Test estructural —
    /// determinista, ataca la causa (¿se materializa el tar entero?) y no la RSS.
    func testTarGzipCodecKeepsCompressedContainer() throws {
        let big = Data(repeating: 0x41, count: 256 * 1024)   // muy compresible: tar inflado >> .gz
        let tar = Tar.write([
            Tar.WriteItem(path: "uno.txt", data: hello, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "dir/grande.bin", data: big, modifiedAt: nil, isDirectory: false),
        ])
        let targz = Gzip.compress(tar)
        let result = try ArchiveFormat.tarGzip.codec.open(targz, fallbackName: "paquete")

        XCTAssertEqual(result.format, .tarGzip)
        XCTAssertEqual(result.container, targz, "el container debe ser el .gz comprimido, no el tar inflado")
        XCTAssertLessThan(result.container.count, tar.count / 4,
                          "el container comprimido debe ser mucho menor que el tar descomprimido")
    }

    /// El round-trip por entrada sobre el container **comprimido**: `entryData` re-descomprime
    /// hasta el offset y `extract` emite por trozos (streaming). Ambos deben reproducir el original.
    func testTarGzipCodecRoundTripOverCompressedContainer() throws {
        let big = Data((0..<200_000).map { UInt8($0 & 0xFF) })
        let tar = Tar.write([
            Tar.WriteItem(path: "uno.txt", data: hello, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "dir/grande.bin", data: big, modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tarGzip.codec.open(Gzip.compress(tar), fallbackName: "p")
        let codec = result.format.codec

        for (path, expected) in [("uno.txt", hello), ("dir/grande.bin", big)] {
            let entry = try XCTUnwrap(result.entries.first { $0.path == path })
            // entryData (re-descompresión por offset)
            XCTAssertEqual(try codec.entryData(for: entry, in: result.container, password: nil), expected)
            // extract (streaming por trozos al sink)
            var streamed = Data()
            try codec.extract(entry, in: result.container, password: nil) { streamed.append($0) }
            XCTAssertEqual(streamed, expected, "el streaming de \(path) debe reproducir el original")
        }
    }

    /// Fase 4 / §10 #1 (el corazón de la feature): extraer **varias** entradas de un tar comprimido
    /// debe hacerse en **una sola descompresión** (`streamEntries`), no una por entrada. Lo medimos
    /// con un `streamDecompress` espía que cuenta los pases; es un test estructural y determinista.
    func testTarGzipExtractAllUsesSinglePass() throws {
        final class PassCounter: @unchecked Sendable { var count = 0 }
        let counter = PassCounter()
        let big = Data((0..<100_000).map { UInt8($0 & 0xFF) })
        let tar = Tar.write([
            Tar.WriteItem(path: "uno.txt", data: hello, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "dir/dos.txt", data: Data("dos".utf8), modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "dir/grande.bin", data: big, modifiedAt: nil, isDirectory: false),
        ])
        let codec = TarCodec(format: .tarGzip, streamDecompress: { data, sink in
            counter.count += 1
            try Gzip.decompress(data, sink: sink)
        })
        let result = try codec.open(Gzip.compress(tar), fallbackName: "p")

        counter.count = 0   // ignorar el pase del indexado al abrir; medir solo la extracción
        var got: [String: Data] = [:]
        try codec.extractAll(result.entries, in: result.container, password: nil) { entry in
            let path = entry.path
            got[path] = Data()
            return { got[path, default: Data()].append($0) }
        }

        XCTAssertEqual(counter.count, 1, "varias entradas = un solo pase de descompresión")
        XCTAssertEqual(got["uno.txt"], hello)
        XCTAssertEqual(got["dir/dos.txt"], Data("dos".utf8))
        XCTAssertEqual(got["dir/grande.bin"], big)
    }

    /// Paridad de la ruta nueva del codec (container comprimido + streaming por offset) para los
    /// **otros dos envoltorios**: xz y bzip2, no solo gzip. Misma lógica parametrizada, pero así se
    /// ejercita el cableado real de `streamDecompress` de cada formato.
    func testTarXzAndBzip2KeepCompressedContainerAndRoundTrip() throws {
        let big = Data(repeating: 0x42, count: 200 * 1024)   // muy compresible
        let tar = Tar.write([
            Tar.WriteItem(path: "uno.txt", data: hello, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "dir/grande.bin", data: big, modifiedAt: nil, isDirectory: false),
        ])
        let cases: [(ArchiveFormat, Data)] = [(.tarXz, Xz.compress(tar)), (.tarBzip2, Bzip2.compress(tar))]
        for (format, compressed) in cases {
            let result = try format.codec.open(compressed, fallbackName: "p")
            XCTAssertEqual(result.format, format)
            XCTAssertEqual(result.container, compressed, "\(format): el container debe ser el comprimido")
            XCTAssertLessThan(result.container.count, tar.count / 4, "\(format): container ≪ tar inflado")
            let codec = result.format.codec
            for (path, expected) in [("uno.txt", hello), ("dir/grande.bin", big)] {
                let entry = try XCTUnwrap(result.entries.first { $0.path == path })
                XCTAssertEqual(try codec.entryData(for: entry, in: result.container, password: nil), expected, "\(format) \(path)")
                var streamed = Data()
                try codec.extract(entry, in: result.container, password: nil) { streamed.append($0) }
                XCTAssertEqual(streamed, expected, "\(format) streaming \(path)")
            }
        }
    }

    /// El otro lado de la decisión §10 #1: extraer **una sola** entrada no recorre todo el tar,
    /// usa `streamExtract` (corta tras la entrada). El espía debe ver un solo pase igualmente, pero
    /// la garantía importante (no inflar el resto) la cubre `TarStreamTests`; aquí basta el round-trip.
    func testTarGzipExtractAllSingleEntry() throws {
        let tar = Tar.write([
            Tar.WriteItem(path: "a.txt", data: hello, modifiedAt: nil, isDirectory: false),
            Tar.WriteItem(path: "b.txt", data: Data("bbb".utf8), modifiedAt: nil, isDirectory: false),
        ])
        let result = try ArchiveFormat.tarGzip.codec.open(Gzip.compress(tar), fallbackName: "p")
        let entry = try XCTUnwrap(result.entries.first { $0.path == "a.txt" })
        var got = Data()
        try result.format.codec.extractAll([entry], in: result.container, password: nil) { _ in
            { got.append($0) }
        }
        XCTAssertEqual(got, hello)
    }
}
