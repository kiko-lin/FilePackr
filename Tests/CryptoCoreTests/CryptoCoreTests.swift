import XCTest
@testable import CryptoCore

final class CryptoCoreTests: XCTestCase {

    private let core = CryptoCore()
    private let password = "correcta-caballo-bateria-grapa"

    func testRoundTrip() throws {
        let secret = Data("Mensaje muy secreto ñ áéí 🔐".utf8)
        let container = try core.encrypt(secret, password: password)

        XCTAssertNotEqual(container, secret, "el contenedor no debe contener el claro")
        XCTAssertEqual(Array(container.prefix(4)), Array("CIFR".utf8), "cabecera mágica")

        let recovered = try core.decrypt(container, password: password)
        XCTAssertEqual(recovered, secret)
    }

    func testWrongPasswordFails() throws {
        let container = try core.encrypt(Data("hola".utf8), password: password)
        XCTAssertThrowsError(try core.decrypt(container, password: "incorrecta")) { error in
            XCTAssertEqual(error as? CryptoError, .decryptionFailed)
        }
    }

    func testTamperingDetected() throws {
        var container = try core.encrypt(Data("integridad".utf8), password: password)
        container[container.count - 1] ^= 0xFF // corrompemos la etiqueta GCM
        XCTAssertThrowsError(try core.decrypt(container, password: password)) { error in
            XCTAssertEqual(error as? CryptoError, .decryptionFailed)
        }
    }

    func testInvalidFormat() {
        XCTAssertThrowsError(try core.decrypt(Data([0, 1, 2, 3]), password: password)) { error in
            XCTAssertEqual(error as? CryptoError, .invalidFormat)
        }
    }

    func testEmptyPasswordRejected() {
        XCTAssertThrowsError(try core.encrypt(Data("x".utf8), password: "")) { error in
            XCTAssertEqual(error as? CryptoError, .emptyPassword)
        }
    }

    func testTwoEncryptionsDifferThanksToRandomSalt() throws {
        let plain = Data("mismo contenido".utf8)
        let a = try core.encrypt(plain, password: password)
        let b = try core.encrypt(plain, password: password)
        XCTAssertNotEqual(a, b, "salt+nonce aleatorios deben producir contenedores distintos")
    }

    func testFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("original.txt")
        let enc = dir.appendingPathComponent("original.cifr")
        let dec = dir.appendingPathComponent("descifrado.txt")
        let payload = Data("contenido de fichero a cifrar".utf8)
        try payload.write(to: src)

        try core.encryptFile(at: src, to: enc, password: password)
        try core.decryptFile(at: enc, to: dec, password: password)

        XCTAssertEqual(try Data(contentsOf: dec), payload)
    }
}
