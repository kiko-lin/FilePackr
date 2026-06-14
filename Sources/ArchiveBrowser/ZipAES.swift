import Foundation
import CommonCrypto
import CryptoKit

public enum ZipAESError: Error, Equatable {
    case wrongPassword
    case corrupt
    case unsupportedStrength
}

/// Cifrado AES de WinZip (AE-2), la opción "Fuerte (AES-256)". Es el cifrado ZIP
/// estándar moderno: interoperable con Keka, 7-Zip, WinZip…
///
/// Por entrada, los datos (ya comprimidos) se cifran con AES en modo CTR (contador
/// little-endian que empieza en 1, como define WinZip) y se autentican con
/// HMAC-SHA1 truncado a 10 bytes. La clave sale de PBKDF2-HMAC-SHA1 (1000 vueltas).
///
/// Formato almacenado por entrada: `salt | verificación(2) | cifrado | auth(10)`.
enum ZipAES {

    /// Fuerza por defecto: 3 = AES-256.
    static let strength256: UInt8 = 3

    static func saltLength(_ strength: UInt8) -> Int {
        switch strength { case 1: return 8; case 2: return 12; default: return 16 }
    }
    static func keyLength(_ strength: UInt8) -> Int {
        switch strength { case 1: return 16; case 2: return 24; default: return 32 }
    }

    // MARK: - Cifrar / descifrar una entrada

    static func encrypt(_ compressed: [UInt8], password: String, strength: UInt8) -> [UInt8] {
        let keyLen = keyLength(strength)
        let salt = (0..<saltLength(strength)).map { _ in UInt8.random(in: 0...255) }
        let keys = deriveKeys(password: password, salt: salt, keyLength: keyLen)
        let ciphertext = ctrCrypt(compressed, key: keys.enc)
        let mac = authCode(ciphertext, authKey: keys.auth)
        return salt + keys.pv + ciphertext + mac
    }

    static func decrypt(_ stored: [UInt8], password: String, strength: UInt8) throws -> [UInt8] {
        let saltLen = saltLength(strength)
        let keyLen = keyLength(strength)
        guard stored.count >= saltLen + 2 + 10 else { throw ZipAESError.corrupt }

        let salt = Array(stored[0..<saltLen])
        let pv = Array(stored[saltLen..<(saltLen + 2)])
        let ciphertext = Array(stored[(saltLen + 2)..<(stored.count - 10)])
        let mac = Array(stored.suffix(10))

        let keys = deriveKeys(password: password, salt: salt, keyLength: keyLen)
        guard keys.pv == pv else { throw ZipAESError.wrongPassword }
        guard authCode(ciphertext, authKey: keys.auth) == mac else { throw ZipAESError.wrongPassword }
        return ctrCrypt(ciphertext, key: keys.enc)
    }

    // MARK: - Primitivas

    /// PBKDF2-HMAC-SHA1, 1000 iteraciones → claveCifrado | claveMAC | verificación(2).
    private static func deriveKeys(password: String, salt: [UInt8], keyLength: Int)
        -> (enc: [UInt8], auth: [UInt8], pv: [UInt8]) {
        let total = keyLength * 2 + 2
        var derived = [UInt8](repeating: 0, count: total)
        let pwData = Data(password.utf8)

        _ = pwData.withUnsafeBytes { pwRaw in
            salt.withUnsafeBufferPointer { saltPtr in
                derived.withUnsafeMutableBufferPointer { out in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwRaw.bindMemory(to: CChar.self).baseAddress, pwData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                        out.baseAddress, total)
                }
            }
        }
        return (Array(derived[0..<keyLength]),
                Array(derived[keyLength..<(2 * keyLength)]),
                Array(derived[(2 * keyLength)..<total]))
    }

    /// CTR de WinZip: contador 128-bit little-endian que empieza en 1, por bloque.
    /// (Cifrar y descifrar son la misma operación.)
    private static func ctrCrypt(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var counter = [UInt8](repeating: 0, count: 16)
        var block: UInt64 = 1
        var i = 0
        while i < data.count {
            withUnsafeBytes(of: block.littleEndian) { raw in
                for j in 0..<8 { counter[j] = raw[j] }
            }
            for j in 8..<16 { counter[j] = 0 }
            let keystream = aesEncryptBlock(counter, key: key)
            let n = min(16, data.count - i)
            for j in 0..<n { out[i + j] = data[i + j] ^ keystream[j] }
            i += 16
            block += 1
        }
        return out
    }

    private static func aesEncryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        _ = key.withUnsafeBytes { k in
            block.withUnsafeBytes { b in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        k.baseAddress, key.count, nil, b.baseAddress, 16, &out, 16, &moved)
            }
        }
        return out
    }

    private static func authCode(_ ciphertext: [UInt8], authKey: [UInt8]) -> [UInt8] {
        var hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: Data(authKey)))
        hmac.update(data: Data(ciphertext))
        return Array(Data(hmac.finalize()).prefix(10))
    }
}
