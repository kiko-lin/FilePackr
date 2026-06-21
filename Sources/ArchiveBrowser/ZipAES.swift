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

    /// Cifra un buffer ya en memoria. Es un adaptador fino sobre `Encryptor` (la única
    /// implementación del cifrado AE-2): cabecera + datos + MAC, todo de una vez.
    static func encrypt(_ compressed: [UInt8], password: String, strength: UInt8) -> [UInt8] {
        var enc = Encryptor(password: password, strength: strength)
        return enc.header + enc.update(compressed) + enc.finalize()
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
        var ks = CTRKeystream(key: key)
        return ks.xor(data)
    }

    /// Estado del keystream CTR de WinZip (bloques de 16 B, contador desde 1). Aplica
    /// `xor` por trozos manteniendo la posición entre llamadas, así sirve tanto a la ruta
    /// en memoria como a los cifrador/descifrador de flujo. Cifrar y descifrar son lo mismo.
    struct CTRKeystream {
        private let key: [UInt8]
        private var block: UInt64 = 1
        private var buffer: [UInt8] = []
        private var used = 0

        init(key: [UInt8]) { self.key = key }

        mutating func xor(_ data: [UInt8]) -> [UInt8] {
            var out = [UInt8](); out.reserveCapacity(data.count)
            for byte in data {
                if used == buffer.count {
                    buffer = ZipAES.keystreamBlock(block, key: key)
                    block += 1
                    used = 0
                }
                out.append(byte ^ buffer[used])
                used += 1
            }
            return out
        }
    }

    /// Keystream de un bloque CTR (contador `block` en los 8 bytes bajos, resto a cero).
    fileprivate static func keystreamBlock(_ block: UInt64, key: [UInt8]) -> [UInt8] {
        var counter = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: block.littleEndian) { raw in for j in 0..<8 { counter[j] = raw[j] } }
        return aesEncryptBlock(counter, key: key)
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

    /// Cifrador de flujo AES (AE-2) para escribir una entrada **sin tenerla entera en
    /// memoria**: emite `header` (salt + verificación) antes de los datos, cifra cada
    /// trozo con CTR (contador continuo entre trozos) autenticándolo con HMAC-SHA1, y
    /// `finalize()` devuelve el MAC de 10 bytes. Equivale a `encrypt(_:)` pero por trozos.
    struct Encryptor {
        /// `salt | verificación(2)`, a emitir antes del primer trozo cifrado.
        let header: [UInt8]
        private var ctr: CTRKeystream
        private var hmac: HMAC<Insecure.SHA1>

        init(password: String, strength: UInt8) {
            let salt = (0..<ZipAES.saltLength(strength)).map { _ in UInt8.random(in: 0...255) }
            let keys = ZipAES.deriveKeys(password: password, salt: salt, keyLength: ZipAES.keyLength(strength))
            header = salt + keys.pv
            ctr = CTRKeystream(key: keys.enc)
            hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: Data(keys.auth)))
        }

        /// Cifra un trozo y lo autentica. Devuelve el texto cifrado del trozo.
        mutating func update(_ data: [UInt8]) -> [UInt8] {
            let cipher = ctr.xor(data)
            hmac.update(data: Data(cipher))
            return cipher
        }

        /// MAC final (10 bytes) a emitir tras el último trozo.
        mutating func finalize() -> [UInt8] {
            Array(Data(hmac.finalize()).prefix(10))
        }
    }

    /// Descifrador de flujo AES (AE-2), espejo de `Encryptor`: descifra el texto cifrado por
    /// trozos (CTR continuo) autenticándolo con HMAC-SHA1; `verify` comprueba el MAC al final.
    /// La verificación de contraseña (pv) se hace en el `init` para fallar pronto.
    struct Decryptor {
        private var ctr: CTRKeystream
        private var hmac: HMAC<Insecure.SHA1>

        /// `salt` y `pv` (verificación de 2 bytes) se leen de la cabecera de la entrada.
        init(password: String, strength: UInt8, salt: [UInt8], pv: [UInt8]) throws {
            let keys = ZipAES.deriveKeys(password: password, salt: salt, keyLength: ZipAES.keyLength(strength))
            guard keys.pv == pv else { throw ZipAESError.wrongPassword }
            ctr = CTRKeystream(key: keys.enc)
            hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: Data(keys.auth)))
        }

        /// Descifra un trozo de texto cifrado (autenticándolo) y devuelve el texto claro.
        mutating func update(_ cipher: [UInt8]) -> [UInt8] {
            hmac.update(data: Data(cipher))
            return ctr.xor(cipher)
        }

        /// Comprueba el MAC de 10 bytes; lanza `wrongPassword` si no cuadra (dato corrupto).
        func verify(_ expected: [UInt8]) throws {
            guard Array(Data(hmac.finalize()).prefix(10)) == expected else { throw ZipAESError.wrongPassword }
        }
    }
}
