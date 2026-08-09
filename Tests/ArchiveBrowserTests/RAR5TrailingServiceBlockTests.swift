import XCTest
@testable import ArchiveBrowser

/// `RAR5TrailingServiceBlock` camina bloques RAR5 fabricados a mano (no archivos válidos, solo
/// lo justo para ejercitar el parseo de vints y el cálculo de offsets — mismo estilo que
/// `RarVolumesTests.rar5Header`) para comprobar que localiza (o no) el bloque SERVICE/QuickOpen
/// sobrante sin necesitar el fixture real de 2,5 GB que reveló el bug.
final class RAR5TrailingServiceBlockTests: XCTestCase {

    private static let signature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])

    private static let headMain: UInt64 = 1
    private static let headFile: UInt64 = 2
    private static let headService: UInt64 = 3
    private static let headEndarc: UInt64 = 5

    private func vint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            bytes.append(b)
        } while v != 0
        return bytes
    }

    /// Bloque base RAR5 (CRC32 dummy + cabecera [+ datos de relleno]): lo mínimo que
    /// `RAR5TrailingServiceBlock` necesita para calcular dónde empieza el siguiente bloque —
    /// tipo, y si declara datos (`HFL_DATA`), su tamaño.
    private func rar5Block(headerType: UInt64, dataSize: UInt64? = nil) -> Data {
        var body: [UInt8] = vint(headerType)
        body += vint(dataSize != nil ? 0x0002 : 0x0000)   // HeaderFlags (HFL_DATA si hay datos)
        if let dataSize { body += vint(dataSize) }

        var block: [UInt8] = [0, 0, 0, 0]           // CRC32 dummy, no se valida
        block += vint(UInt64(body.count))            // HeaderSize
        block += body
        if let dataSize { block += [UInt8](repeating: 0xAB, count: Int(dataSize)) }
        return Data(block)
    }

    private func reader(for data: Data) -> (Int64, Int) -> Data? {
        { off, len in
            guard off >= 0, off + Int64(len) <= Int64(data.count) else { return nil }
            return data.subdata(in: Int(off)..<Int(off) + len)
        }
    }

    func testFindsServiceBlockBeforeEndArc() {
        let main = rar5Block(headerType: Self.headMain)
        let file = rar5Block(headerType: Self.headFile, dataSize: 100)
        let service = rar5Block(headerType: Self.headService, dataSize: 50)
        let endarc = rar5Block(headerType: Self.headEndarc)
        let data = Self.signature + main + file + service + endarc

        let expectedOffset = Int64(Self.signature.count + main.count + file.count)
        XCTAssertEqual(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)),
                        expectedOffset)
    }

    func testSkipsMultipleFileEntriesBeforeService() {
        let main = rar5Block(headerType: Self.headMain)
        let file1 = rar5Block(headerType: Self.headFile, dataSize: 200)
        let file2 = rar5Block(headerType: Self.headFile, dataSize: 300)
        let service = rar5Block(headerType: Self.headService, dataSize: 40)
        let endarc = rar5Block(headerType: Self.headEndarc)
        let data = Self.signature + main + file1 + file2 + service + endarc

        let expectedOffset = Int64(Self.signature.count + main.count + file1.count + file2.count)
        XCTAssertEqual(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)),
                        expectedOffset)
    }

    func testServiceBlockAtExactEndOfFileWithoutEndArc() {
        // Caso límite: los datos del SERVICE llegan justo al final del fichero, sin ENDARC
        // detrás (no debería pasar en un RAR5 real, pero el walker no debe fallar por ello).
        let main = rar5Block(headerType: Self.headMain)
        let file = rar5Block(headerType: Self.headFile, dataSize: 10)
        let service = rar5Block(headerType: Self.headService, dataSize: 20)
        let data = Self.signature + main + file + service

        let expectedOffset = Int64(Self.signature.count + main.count + file.count)
        XCTAssertEqual(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)),
                        expectedOffset)
    }

    func testReturnsNilWhenNoServiceBlock() {
        let main = rar5Block(headerType: Self.headMain)
        let file = rar5Block(headerType: Self.headFile, dataSize: 10)
        let endarc = rar5Block(headerType: Self.headEndarc)
        let data = Self.signature + main + file + endarc

        XCTAssertNil(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)))
    }

    /// Si al SERVICE le sigue algo que no es ENDARC, la estructura no encaja con el patrón
    /// "QuickOpen al final" — por seguridad no se recorta nada, se deja el volumen tal cual.
    func testReturnsNilWhenServiceNotImmediatelyBeforeEndArc() {
        let main = rar5Block(headerType: Self.headMain)
        let file = rar5Block(headerType: Self.headFile, dataSize: 10)
        let service = rar5Block(headerType: Self.headService, dataSize: 20)
        let file2 = rar5Block(headerType: Self.headFile, dataSize: 5)
        let endarc = rar5Block(headerType: Self.headEndarc)
        let data = Self.signature + main + file + service + file2 + endarc

        XCTAssertNil(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)))
    }

    func testReturnsNilForNonRAR5Data() {
        XCTAssertNil(RAR5TrailingServiceBlock.offset(length: 40, read: reader(for: Data(repeating: 0xFF, count: 40))))
        // Marcador RAR4, no RAR5.
        let rar4 = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        XCTAssertNil(RAR5TrailingServiceBlock.offset(length: Int64(rar4.count), read: reader(for: rar4)))
    }

    func testReturnsNilWhenNoBlocksFollowSignature() {
        // Firma válida pero nada más: no hay ni para leer el primer bloque.
        let data = Self.signature
        XCTAssertNil(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)))
    }

    func testReturnsNilOnBlockTruncatedMidHeader() {
        // Firma + un CRC32 y parte del vint de HeaderSize, cortado a mitad de bloque.
        let data = Self.signature + Data([0, 0, 0, 0, 0x05])
        XCTAssertNil(RAR5TrailingServiceBlock.offset(length: Int64(data.count), read: reader(for: data)))
    }
}
