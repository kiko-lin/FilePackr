# Cifrador

App de macOS para **cifrar y descifrar** ficheros con una interfaz limpia, y para
**explorar archivos comprimidos como un navegador, sin descomprimirlos**, con
previsualización del contenido.

Este repositorio contiene el **armazón**: el núcleo lógico ya funciona y está
cubierto por tests; la interfaz SwiftUI es un esqueleto que se monta en Xcode.

## Estado actual

| Pieza | Estado | Qué hace |
|---|---|---|
| `CryptoCore` | ✅ con tests | Cifra/descifra (AES-256-GCM + PBKDF2-SHA256). Detecta contraseña incorrecta y manipulación. |
| `ArchiveBrowser` | ✅ con tests | Lista el contenido de un ZIP **leyendo sólo el índice**, sin descomprimir. Construye el árbol de carpetas. |
| `App/` (SwiftUI) | 🟡 esqueleto | Panel Cifrar/Descifrar + explorador de archivos. Se compila en Xcode. |
| Previsualización Quick Look | ⬜ pendiente | Extracción perezosa de una entrada + `QLPreviewView`. |

## Arquitectura

```
Cifrador/
├── Package.swift              ← paquete con la lógica (testeable por CLI)
├── Sources/
│   ├── CryptoCore/            ← cifrado/descifrado (CryptoKit + CommonCrypto)
│   └── ArchiveBrowser/        ← lectura de ZIP sin descomprimir + árbol
├── Tests/                     ← 12 tests (swift test)
└── App/                       ← UI SwiftUI (se añade a un proyecto Xcode)
```

La lógica vive en paquetes Swift independientes de la UI: así la parte sensible
(criptografía, parseo de archivos) se prueba sin levantar la interfaz.

## Probar el núcleo (sin Xcode)

```bash
swift test
```

Demuestra: ida y vuelta de cifrado, fallo con contraseña incorrecta, detección de
manipulación, y listado de un ZIP sin extraerlo.

## Montar la app en Xcode

1. `Xcode → File → New → Project → macOS → App` (SwiftUI), guárdalo dentro de este repo.
2. Borra el `ContentView.swift` que genera Xcode y **arrastra los ficheros de `App/`** al proyecto.
3. `File → Add Package Dependencies → Add Local…` y elige esta misma carpeta para
   enlazar `CryptoCore` y `ArchiveBrowser`.
4. En **Signing & Capabilities** añade **App Sandbox** y marca *User Selected File · Read/Write*.
5. `⌘R`.

## Decisiones de diseño

- **Cifrado:** AES-256-GCM (cifra + autentica en un paso). Clave derivada de la
  contraseña con PBKDF2-HMAC-SHA256, 600.000 iteraciones (OWASP), con *salt*
  aleatorio de 16 bytes por fichero. Formato de contenedor: `CIFR | versión | salt | caja-GCM`.
- **Explorar sin descomprimir:** se lee el *central directory* del ZIP (unos pocos
  cientos de bytes al final) para obtener nombres, tamaños y offsets. No se toca
  ningún dato de fichero hasta que el usuario abre una entrada concreta.

## Siguientes pasos

- Previsualización: extracción perezosa de la entrada seleccionada + Quick Look.
- Sustituir el lector ZIP propio por **libarchive** para soportar 7z/tar/rar y ZIP64.
- Considerar **Argon2id** (libsodium) en lugar de PBKDF2 para la derivación de clave.
- Cifrar/descifrar **archivos completos manteniéndolos navegables** (cifrado a nivel de contenedor).
