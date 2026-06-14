# AGENTS.md — Contexto de trabajo de FilePackr

Fichero de contexto para agentes (Claude Code) que retomen el proyecto. Mantén
este archivo al día tras cada bloque de trabajo.

## Qué es

App de macOS (SwiftUI + AppKit) para gestionar archivos comprimidos **ZIP**:
abrir/navegar sin descomprimir, editar, extraer, previsualizar y **cifrar con
contraseña** (estándar ZIP). Ver `README.md` para la visión general.

- **Repo local**: `~/Desktop/Repos/Cifrador` (la carpeta se llama `Cifrador` por
  historia; la app y el producto son **FilePackr**).
- **Remoto git**: `git@github.com:kiko-lin/packr.git` (SSH). El entorno del agente
  **no tiene red** → los `git push` los hace el usuario.
- **Plataforma**: macOS 26 (Tahoe), Swift 6.3, Xcode 26. App target `FilePackr`,
  bundle `com.kiko.FilePackr`, lenguaje Swift 5 mode con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

## Cómo trabajar (importante)

- **Tests del motor**: `swift test` (rápido, sin Xcode). Hay tests de interop que
  llaman a `/usr/bin/zip` y `/usr/bin/unzip` (ZipCrypto).
- **Compilar la app**: `xcodebuild -project Cifrador/FilePackr.xcodeproj -scheme FilePackr -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`.
  - El agente **no puede ejecutar la GUI** ni verificar comportamiento visual:
    solo compilar. El usuario prueba en Xcode (⌘R) y reporta.
- **Caché de Xcode**: tras renombrar o cambiar el icono, suele hacer falta
  **Clean Build Folder (⇧⌘K)** y a veces `killall Dock`. La resolución de paquetes
  se atasca a veces → File → Packages → Reset Package Caches.
- **Idioma**: comunicación e interfaz en **español de España**.
- **Estilo**: simplicidad, sin código muerto, causas raíz. Verificar con tests
  antes de dar por hecho.

## Arquitectura (dónde está cada cosa)

- Motor (paquete `CifradorCore`, `Sources/`):
  - `ArchiveBrowser`: `ZipReader` (índice + ZIP64; **solo lee la cola + central
    directory**, no copia el fichero), `ZipExtractor` (extrae/descifra),
    `ZipWriter` (escribe; `build` en memoria y `write` en streaming a `FileHandle`;
    ZIP64; `ZipEncryption .none/.zipCrypto/.aes256`), `ZipCrypto`, `ZipAES`,
    `Deflate` (framework Compression), `CRC32`.
  - `CryptoCore`: AES-256-GCM + PBKDF2 (formato propio `.fpkz`, **legacy**).
- App (`Cifrador/FilePackr/`):
  - `ArchiveDocument` (`@MainActor ObservableObject`): árbol `FileNode`, abrir
    (`openArchive` async), guardar (`save(to:encryption:password:)` en streaming),
    extraer, mover/renombrar, plan de exportación (`ExportPlan`), progreso.
  - `ArchiveOutlineView` (`NSViewRepresentable` + `Coordinator`): el navegador
    `NSOutlineView` — selección, columnas ordenables, arrastre (mover/extraer/
    añadir), Quick Look (barra espaciadora), renombrado en línea, menú contextual.
  - `ContentView`: barra superior (Añadir/Eliminar/Crear carpeta/Extraer), barra
    de documento (icono+nombre, Cerrar/Guardar), zona de arrastre, overlay de
    progreso, diálogos (conflicto, cerrar, contraseña, **opciones de guardar**).

## Hecho

- Navegar ZIP sin descomprimir; apertura rápida (no copia el fichero).
- ZIP64 lectura y escritura (+test de 70.000 entradas).
- Editar: añadir/borrar/renombrar/mover (drag a carpetas)/crear carpeta.
- Extraer (botón / menú / arrastre al Finder) + diálogo de conflictos.
- Quick Look (espacio), columnas Finder ordenables, iconos por tipo.
- Operaciones en segundo plano con barra de progreso; guardado en streaming.
- Cifrado ZIP estándar: **ZipCrypto (Débil)** — interop verificada contra
  `zip`/`unzip`; **AES-256 WinZip (Fuerte)** — round-trip propio verificado.
- Diálogo de guardar: formato (ZIP) + cifrado (none/débil/fuerte) + contraseña.
- Icono de app (full-bleed macOS 26). Lectura `.fpkz` legacy.

## TODO (objetivos pendientes, en orden lógico)

- [ ] **Verificar interop AES-256 en Keka/7-Zip** (lo prueba el usuario; el agente
      no tiene esas herramientas). Si falla, revisar `ZipAES` (PBKDF2/CTR/HMAC,
      campo extra 0x9901, AE-2 CRC=0).
- [ ] **Pedir contraseña al abrir** un zip cifrado de otra app: hoy lista los
      ficheros pero al extraer/previsualizar lanza `ExtractError.needsPassword`.
      Hay que: detectar entradas cifradas tras abrir, pedir la clave una vez,
      guardarla (`entryPassword`) y pasarla a `ExportPlan`/extracción/Quick Look.
- [ ] **Más formatos**: tar/gz/tar.gz en Swift puro (asequible); luego 7z/rar/dmg
      con **libarchive** (vendorizar C — esfuerzo grande). El diálogo de guardar
      ya tiene el hueco del selector de formato.
- [ ] **Limpieza legacy**: decidir si se retira `.fpkz` (CryptoCore, `openEncrypted`,
      `isEncryptedFile`, `encryptionPassword`), `CipherView.swift` (pantalla vieja
      sin usar) y `ArchiveTree.swift` (solo lo usa un test).
- [ ] **Re-cifrar al guardar** un zip ya cifrado abierto: hoy `makeSaveInputs` usa
      `.rawEntry` (bytes comprimidos en crudo); si el origen estaba cifrado se
      re-cifraría doble. Documentado, sin resolver.
- [ ] **Opciones de fuerza AES** (128/192) además de 256; ZipCrypto ya está.
- [ ] **Distribución**: reactivar App Sandbox correctamente (paneles de guardado +
      security-scoped bookmarks), notarización, `.dmg`.
- [ ] **Streaming de compresión** de un único fichero enorme (hoy cada fichero se
      carga entero en memoria para comprimir).
- [ ] **Localización** (textos de UI fijos en español).

## Notas de formato/cifrado (para no re-investigar)

- ZipCrypto: verificación de contraseña por byte alto del CRC, o de la **hora DOS**
  si la entrada usa descriptor de datos (bit 3) — Info-ZIP `zip` lo hace así.
- AES WinZip: método cabecera 99, campo extra **0x9901** (versión 2 = AE-2, vendor
  "AE", fuerza 1/2/3, método real). AE-2 pone CRC = 0. Datos por entrada:
  `salt | verificación(2) | cifrado | auth(10)`. CTR con contador 128-bit
  little-endian que empieza en 1. PBKDF2-HMAC-SHA1, 1000 vueltas.
- ZIP64: el lector sigue EOCD64 + locator si el EOCD de 32 bits está saturado, y
  el campo extra 0x0001 por entrada. El escritor lo emite cuando hace falta.
