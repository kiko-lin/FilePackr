import Foundation
import CryptoKit
import CommonCrypto

/// Errores posibles del cifrado/descifrado.
public enum CryptoError: Error, Equatable {
    /// El contenedor no tiene la cabecera esperada o está truncado.
    case invalidFormat
    /// Versión de contenedor no soportada por esta build.
    case unsupportedVersion(UInt8)
    /// Contraseña incorrecta o datos manipulados (AES-GCM no autentica).
    case decryptionFailed
    /// Falló la derivación de clave (PBKDF2).
    case keyDerivationFailed
    /// Contraseña vacía: no se permite.
    case emptyPassword
}

/// Cifrado y descifrado de datos/ficheros con clave derivada de contraseña.
///
/// Formato del contenedor (todo binario, big-endian sólo en el header conceptual):
/// ```
/// MAGIC(4 = "CIFR") | VERSION(1) | SALT(16) | SEALED
/// ```
/// `SEALED` es la caja AES-GCM "combined" de CryptoKit: NONCE(12) + CIPHERTEXT + TAG(16).
///
/// La clave de 256 bits se deriva con PBKDF2-HMAC-SHA256 (600.000 iteraciones,
/// recomendación OWASP). Para producción multiplataforma se puede sustituir la
/// derivación por Argon2id (libsodium) sin cambiar el resto del formato.
public struct CryptoCore: Sendable {

    // MARK: - Constantes de formato
    static let magic: [UInt8] = Array("CIFR".utf8)
    static let version: UInt8 = 1
    static let saltSize = 16
    static let keySize = 32          // AES-256
    static let iterations: UInt32 = 600_000

    public init() {}

    // MARK: - API de datos en memoria

    /// Cifra `plaintext` y devuelve el contenedor autocontenido (header + datos sellados).
    public func encrypt(_ plaintext: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }

        let salt = Self.randomBytes(count: Self.saltSize)
        let key = try Self.deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.decryptionFailed }

        var out = Data()
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(salt)
        out.append(combined)
        return out
    }

    /// Descifra un contenedor producido por `encrypt`. Lanza si la contraseña es
    /// incorrecta o los datos fueron manipulados (la etiqueta GCM no validará).
    public func decrypt(_ container: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }

        var cursor = container.startIndex
        func take(_ n: Int) throws -> Data {
            guard cursor + n <= container.endIndex else { throw CryptoError.invalidFormat }
            let slice = container[cursor..<(cursor + n)]
            cursor += n
            return Data(slice)
        }

        guard Array(try take(4)) == Self.magic else { throw CryptoError.invalidFormat }
        let v = try take(1).first ?? 0
        guard v == Self.version else { throw CryptoError.unsupportedVersion(v) }
        let salt = try take(Self.saltSize)
        let combined = Data(container[cursor..<container.endIndex])

        let key = try Self.deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    // MARK: - API de ficheros

    /// Cifra el fichero en `src` y escribe el contenedor en `dst`.
    public func encryptFile(at src: URL, to dst: URL, password: String) throws {
        let data = try Data(contentsOf: src)
        try encrypt(data, password: password).write(to: dst, options: .atomic)
    }

    /// Descifra el contenedor en `src` y escribe el original en `dst`.
    public func decryptFile(at src: URL, to dst: URL, password: String) throws {
        let data = try Data(contentsOf: src)
        try decrypt(data, password: password).write(to: dst, options: .atomic)
    }

    // MARK: - Helpers

    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes falló")
        return data
    }

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let pwData = Data(password.utf8)   // no vacío: validado antes de llamar
        var derived = [UInt8](repeating: 0, count: keySize)

        let status = pwData.withUnsafeBytes { (pwRaw: UnsafeRawBufferPointer) in
            salt.withUnsafeBytes { (saltRaw: UnsafeRawBufferPointer) in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwRaw.bindMemory(to: CChar.self).baseAddress, pwData.count,
                    saltRaw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived, keySize
                )
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return SymmetricKey(data: Data(derived))
    }
}
