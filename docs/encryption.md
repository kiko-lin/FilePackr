# Cifrado ZIP en FilePackr

Referencia del cifrado **estándar de ZIP** (interoperable con Finder, Keka,
WinZip, 7-Zip). Dos modos, ambos por entrada:

| UI | Tipo | Módulo | Seguridad |
|---|---|---|---|
| **Débil (PKZip2)** | ZipCrypto / PKWARE tradicional | `ZipCrypto.swift` | Inseguro, universal |
| **Fuerte (AES-256)** | AES de WinZip (AE-2) | `ZipAES.swift` | Seguro, moderno |

> Solo se cifra al escribir en **ZIP**. El 7z se puede **descifrar al leer** (libarchive
> con passphrase), pero su escritor no cifra → el 7z se escribe en claro.

## ZipCrypto ("Débil")

- Claves PKWARE de 32 bits (`0x12345678/0x23456789/0x34567890`) inicializadas con
  la contraseña; `updateKeys` usa la tabla CRC-32 estándar (compartida con `CRC32`).
- Cada entrada cifrada lleva una **cabecera de 12 bytes** (también cifrada) delante
  de los datos. El byte 11 = byte alto del CRC, para verificación rápida.
- **Bandera bit 0** del *general purpose flag* marca la entrada como cifrada.
- **Verificación de contraseña** (`ZipExtractor.decryptZipCrypto`): el byte 11 debe
  ser el byte alto del **CRC**, o el de la **hora MS-DOS** si la entrada usa
  *descriptor de datos* (bit 3) — Info-ZIP `zip` hace esto. Por eso `entry.zip`
  (`ZipEntryInfo`) guarda `dosTime`. ⚠️ No verificar solo contra el CRC: rompe la detección de
  contraseña incorrecta con zips del sistema.
- **Interop verificada** en los tests (`ZipCryptoTests`) contra `/usr/bin/zip` y
  `/usr/bin/unzip` en ambos sentidos.

## AES de WinZip ("Fuerte", AE-2)

- Cabecera: método de compresión **99**, bit 0 (cifrado), **CRC = 0** (AE-2), y un
  **campo extra `0x9901`** (7 bytes): versión 2 (AE-2), vendor `"AE"`, fuerza
  (1/2/3 = 128/192/256), método real (0/8). `entry.zip` (`ZipEntryInfo`) expone
  `aesStrength` y `aesRealMethod`, leídos de ese campo.
- **Clave**: PBKDF2-HMAC-SHA1, **1000 iteraciones** →
  `claveCifrado(keyLen) | claveMAC(keyLen) | verificación(2)`. Para AES-256:
  salt 16 B, keyLen 32 → 66 bytes derivados.
- **Cifrado**: AES en **CTR**, pero con el contador específico de WinZip — entero de
  128 bits **little-endian que empieza en 1**, por bloque (no es el CTR big-endian
  de CommonCrypto). Se implementa a mano con AES-ECB de bloque (`ctrCrypt`).
- **Autenticación**: HMAC-SHA1 sobre el **texto cifrado**, truncado a **10 bytes**.
- **Formato por entrada**: `salt | verificación(2) | cifrado | auth(10)`. El
  `compressedSize` de la cabecera incluye todo eso.
- **Verificación de contraseña**: los 2 bytes de verificación derivados deben
  coincidir; además se comprueba el HMAC.
- **Interop verificada** (2026-06-20) en ambos sentidos contra **`pyzipper`** (que
  implementa el AES de WinZip): `ZipCryptoTests.testPyzipperReadsOurAES256` y
  `testReadsAES256FromPyzipper`. Se **saltan** si falta la librería (`pip3 install pyzipper`).

## Flujo en la app

- **Guardar / Exportar**: diálogo (`SaveOptionsSheet`) con formato + cifrado +
  contraseña → `doc.save`/`doc.export(to:format:encryption:password:volumeSize:)` →
  `makeSavePayload` → `ArchiveSaver.encode` → `ZipWriter.write(..., encryption:, password:)`.
- **Abrir cifrado**: `openArchive` detecta entradas cifradas → `requiresEntryPassword`.
  La UI pide la clave; `provideEntryPassword` la valida extrayendo la 1ª entrada y la
  recuerda (`entryPassword` + `savePassword`). El `ExportPlan` (`.archiveEntry`) la transporta.
- **Re-guardar**: conserva el cifrado original (`saveEncryption`/`savePassword`
  fijados al abrir). `makeSaveInputs` **descifra** las entradas cifradas a texto
  claro (no copia bytes cifrados a un zip plano → evita corrupción).
- **Bloqueo**: `doc.isLocked` (== `requiresEntryPassword`) → solo lectura; al editar se
  pide la contraseña y, al desbloquear, se ejecuta la acción pendiente.

## Cómo probar interop

```bash
# ZipCrypto: contra el zip/unzip del sistema (siempre).
swift test --filter ZipCryptoTests
# AES-256: instala pyzipper y se activan los tests de interop AES (si no, se saltan).
pip3 install pyzipper && swift test --filter ZipCryptoTests
```
