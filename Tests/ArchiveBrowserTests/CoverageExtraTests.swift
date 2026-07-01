import XCTest
@testable import ArchiveBrowser

/// Coberturas extra de la evaluación: `streamEntries` con entradas **grandes** (que cruzan varios
/// trozos de descompresión), **cota agregada** anti-bomba en ZIP, y **edge cases de multivolumen**.
final class CoverageExtraTests: XCTestCase {

    // MARK: - streamEntries: entradas grandes (multi-trozo) en un solo pase

    private func bigTar() -> (Data, [String: Data]) {
        // Entradas de cientos de KB → cruzan varios trozos de 64 KB al descomprimir. Contenido
        // distinto por entrada para detectar desincronización o mezcla.
        let bodies: [String: Data] = [
            "1.bin": Data(repeating: 0x11, count: 200_000),
            "2.bin": Data(repeating: 0x22, count: 180_000),
            "3.bin": Data(repeating: 0x33, count: 220_000),
        ]
        let tar = Tar.write(["1.bin", "2.bin", "3.bin"].map {
            Tar.WriteItem(path: $0, data: bodies[$0]!, modifiedAt: nil, isDirectory: false)
        })
        return (tar, bodies)
    }

    func testStreamEntriesLargeEntriesInOnePass() throws {
        let (tar, bodies) = bigTar()
        let gz = Gzip.compress(tar)
        var got: [String: Data] = [:]
        try Tar.streamEntries(decompressing: gz, with: { try Gzip.decompress($0, sink: $1) }) { entry in
            { chunk in got[entry.path, default: Data()].append(chunk) }
        }
        XCTAssertEqual(got, bodies, "cada entrada grande debe leerse íntegra y sin mezclarse")
    }

    func testStreamEntriesSkipsLargeEntryWithoutDesync() throws {
        let (tar, bodies) = bigTar()
        let gz = Gzip.compress(tar)
        var got: [String: Data] = [:]
        var visited: [String] = []
        try Tar.streamEntries(decompressing: gz, with: { try Gzip.decompress($0, sink: $1) }) { entry in
            visited.append(entry.path)
            guard entry.path != "2.bin" else { return nil }   // salta la GRANDE del medio
            return { chunk in got[entry.path, default: Data()].append(chunk) }
        }
        XCTAssertEqual(visited, ["1.bin", "2.bin", "3.bin"], "todas visitadas, en orden")
        XCTAssertEqual(got["1.bin"], bodies["1.bin"])
        XCTAssertNil(got["2.bin"], "la saltada no emite datos")
        XCTAssertEqual(got["3.bin"], bodies["3.bin"], "la entrada tras la saltada se lee sin desincronizar")
    }

    // MARK: - Cota agregada anti-bomba en ZIP

    func testZipAggregateBombRejectedAtOpen() throws {
        let zip = try ZipWriter().build([
            ZipEntryInput(path: "a.bin", modifiedAt: nil, source: .data(Data(repeating: 0x41, count: 400))),
            ZipEntryInput(path: "b.bin", modifiedAt: nil, source: .data(Data(repeating: 0x42, count: 400))),
        ])
        // Cota minúscula: el total declarado (800) supera el techo (100) → bomba agregada.
        let tiny = DecompressionLimit(maxRatio: 0, floor: 100)
        XCTAssertThrowsError(try ZipReader().listEntries(in: zip, limit: tiny)) {
            XCTAssertEqual($0 as? DecompressionLimitError, .bombDetected)
        }
        // Cota estándar: un zip normal se lista sin problema.
        XCTAssertEqual(try ZipReader().listEntries(in: zip).count, 2)
    }

    // MARK: - Multivolumen: edge cases

    func testVolumePartNamingBeyond999RoundTrips() {
        // Índice de 4 dígitos: `_%03d` se ensancha y `continuationVolume` lo parsea de vuelta.
        let name = Volumes.partName(base: "backup.zip", index: 1001)
        XCTAssertEqual(name, "backup_1000.zip")
        let parsed = Volumes.continuationVolume(name)
        XCTAssertEqual(parsed?.base, "backup.zip")
        XCTAssertEqual(parsed?.index, 1001)
    }

    func testVolumeContinuationRejectsNonContinuationNames() {
        XCTAssertNil(Volumes.continuationVolume("backup.zip"))   // la 1ª parte no es continuación
        XCTAssertNil(Volumes.continuationVolume("noindex.tar"))
    }

    func testVolumeSplitJoinRoundTripAndUniqueNamesManyParts() {
        let data = Data((0..<5000).map { UInt8($0 & 0xFF) })
        let parts = Volumes.split(data, volumeSize: 3)         // 1667 partes → ejercita >999
        XCTAssertGreaterThan(parts.count, 999)
        XCTAssertEqual(Volumes.join(parts), data, "reensamblado exacto")
        let names = (1...parts.count).map { Volumes.partName(base: "v.zip", index: $0) }
        XCTAssertEqual(Set(names).count, names.count, "nombres de parte únicos, sin colisión a 4 dígitos")
    }
}
