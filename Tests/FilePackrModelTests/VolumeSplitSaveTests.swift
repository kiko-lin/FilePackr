import XCTest
import ArchiveBrowser
@testable import FilePackrModel

/// Guardar **dividido en volúmenes**, de extremo a extremo y **por formato**: de la hoja de
/// guardar (`SaveCoordinator`) al disco. `VolumesTests`/`VolumeStore` ya cubren el troceo por
/// bytes, pero no que cada formato de salida llegue hasta él con su tamaño de volumen: el
/// troceo ocurre *después* de escribir el temporal, y cada formato lo produce por una vía
/// distinta (ZIP en streaming, `Data` para tar/gz, **libarchive a fichero para 7z/iso/xar**).
@MainActor
final class VolumeSplitSaveTests: XCTestCase {

    private var temps: [URL] = []
    override func tearDown() async throws {
        for url in temps { try? FileManager.default.removeItem(at: url) }
        temps = []
    }

    private func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temps.append(dir)
        return dir
    }

    /// Fichero de contenido **poco comprimible**, para que el archivo resultante siga siendo
    /// mayor que el volumen pedido en cualquier formato (si comprimiera hasta caber en una
    /// parte, no habría nada que dividir y el test no probaría nada).
    private func noisyFile(_ bytes: Int, seed: UInt64) throws -> URL {
        var s = seed | 1
        var data = Data(capacity: bytes)
        for _ in 0..<bytes {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: s >> 40))
        }
        let url = try tempFolder().appendingPathComponent("dato.bin")
        try data.write(to: url)
        return url
    }

    /// Cada formato de salida escribible debe acabar troceado en `nombre.ext`, `nombre_001.ext`…
    /// 7z incluido (su escritor es el de libarchive, que produce el temporal a fichero).
    func testSaveSplitsIntoVolumesForEveryWritableFormat() async throws {
        let source = try noisyFile(600_000, seed: 3)
        let volume = 100 * 1024   // 100 KB

        for format in [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip, .xar] {
            let doc = ArchiveDocument()
            doc.addFiles([source])
            let dir = try tempFolder()
            let out = dir.appendingPathComponent("salida.\(format.fileExtension)")

            try await doc.save(to: out, format: format, encryption: .none, password: nil,
                               volumeSize: volume)

            let parts = VolumeStore.parts(for: out)
            XCTAssertGreaterThan(parts.count, 1,
                                 "\(format.fileExtension): 600 KB poco comprimibles con volúmenes de 100 KB deben partirse")
            XCTAssertEqual(parts.first?.lastPathComponent, "salida.\(format.fileExtension)",
                           "\(format.fileExtension): la primera parte conserva el nombre base")
            XCTAssertEqual(parts.dropFirst().first?.lastPathComponent, "salida_001.\(format.fileExtension)",
                           "\(format.fileExtension): las siguientes llevan sufijo _001, _002…")
            XCTAssertEqual(doc.saveVolumeSize, volume, "\(format.fileExtension): el documento recuerda el tamaño")
            // Todas las partes menos la última miden justo el volumen pedido.
            for part in parts.dropLast() {
                let size = try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int
                XCTAssertEqual(size, volume, "\(format.fileExtension): \(part.lastPathComponent)")
            }
        }
    }

    /// Un 7z partido en volúmenes se vuelve a abrir: `VolumeStore` reúne las partes, las
    /// concatena y el contenido sale intacto (el troceo es por bytes, así que el archivo
    /// reconstruido es idéntico al que se escribió).
    func testSevenZipVolumesReopenAsOneArchive() async throws {
        let source = try noisyFile(400_000, seed: 5)
        let original = try Data(contentsOf: source)
        let doc = ArchiveDocument()
        doc.addFiles([source])
        let out = try tempFolder().appendingPathComponent("partido.7z")

        try await doc.save(to: out, format: .sevenZip, encryption: .none, password: nil,
                           volumeSize: 100 * 1024)
        XCTAssertGreaterThan(VolumeStore.parts(for: out).count, 1)

        let reopened = ArchiveDocument()
        try await reopened.openArchive(out)
        XCTAssertEqual(reopened.roots.map(\.name), ["dato.bin"])
        XCTAssertEqual(reopened.saveVolumeSize, 100 * 1024, "reabrir un multivolumen recuerda el tamaño de parte")
        let entry = try XCTUnwrap(reopened.roots.first)
        let plan = reopened.exportPlan(for: entry)
        let materialized = try plan.materialize()
        defer { try? FileManager.default.removeItem(at: materialized.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: materialized), original, "el contenido sobrevive al troceo")
    }

    /// La vía real de la interfaz: la hoja de guardar convierte «100 KB» a bytes y se los
    /// entrega al documento, con 7z seleccionado en el Picker de formato.
    func testSaveSheetHandsVolumeSizeToDocumentForSevenZip() async throws {
        let doc = ArchiveDocument()
        doc.addFiles([try noisyFile(600_000, seed: 13)])
        let dir = try tempFolder()

        let coord = SaveCoordinator()
        coord.prefill(doc: doc, settings: AppSettings.shared, baseName: "salida")
        coord.destination = dir
        coord.format = .sevenZip
        coord.splitEnabled = true
        coord.volumeSize = 100
        coord.volumeUnit = .kilobytes
        XCTAssertTrue(coord.canConfirm)

        var handed: Int??
        var done = false
        coord.beginSave(then: nil)
        coord.confirm(settings: AppSettings.shared) { _, url, format, encryption, password, volumeSize, level in
            handed = .some(volumeSize)
            try? await doc.save(to: url, format: format, encryption: encryption,
                                password: password, volumeSize: volumeSize, level: level)
            done = true
            return true
        }
        while !done { try await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertEqual(handed, .some(102_400), "100 KB deben llegar al documento como bytes")
        XCTAssertGreaterThan(VolumeStore.parts(for: dir.appendingPathComponent("salida.7z")).count, 1)
    }

    /// El otro lado: si el archivo comprimido **cabe** en un volumen no hay nada que partir y
    /// sale un único fichero. Es lo esperado, y con 7z ocurre mucho antes que con ZIP porque
    /// comprime bastante más: mismo contenido y mismo tamaño de volumen, distinto resultado.
    func testNothingToSplitWhenArchiveFitsInOneVolume() async throws {
        let comprimible = Data(String(repeating: "texto de oficina muy repetitivo. ", count: 40_000).utf8)
        let source = try tempFolder().appendingPathComponent("documento.txt")
        try comprimible.write(to: source)

        var sizes: [ArchiveFormat: Int] = [:]
        for format in [ArchiveFormat.zip, .sevenZip] {
            let doc = ArchiveDocument()
            doc.addFiles([source])
            let out = try tempFolder().appendingPathComponent("uno.\(format.fileExtension)")
            try await doc.save(to: out, format: format, encryption: .none, password: nil,
                               volumeSize: 100 * 1024)   // 100 KB
            sizes[format] = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? -1
            XCTAssertEqual(VolumeStore.parts(for: out).count, 1,
                           "\(format.fileExtension): si cabe en un volumen, un solo fichero")
        }
        XCTAssertLessThan(sizes[.sevenZip] ?? .max, sizes[.zip] ?? 0,
                          "7z comprime más que zip: alcanza el umbral de división más tarde")
    }
}
