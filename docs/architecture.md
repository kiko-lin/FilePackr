# Arquitectura de FilePackr

Dos capas: un **motor ZIP sin UI** (paquete Swift, testeable por CLI) y una **app**
SwiftUI/AppKit que lo consume.

## Motor — `Sources/` (paquete `FilePackrCore`)

`ArchiveBrowser` (sin dependencias de UI):

- **`ZipReader`** — lee el *central directory* para listar entradas sin
  descomprimir. Optimización clave: **solo lee la cola** (EOCD/ZIP64) **y la región
  del central directory**, nunca copia el fichero entero (mapeado en memoria).
  Soporta **ZIP64** (EOCD64 + locator, campo extra 0x0001) y lee `flags`, `dosTime`,
  y el campo AES `0x9901`.
- **`ZipExtractor`** — extrae una entrada concreta (extracción perezosa): localiza el
  *local header*, descomprime (store/deflate) y **descifra** (ZipCrypto/AES) si toca.
- **`ZipWriter`** — escribe ZIP. `build` (en memoria) y `write` (**streaming** a un
  `FileHandle`, sin cargar todo). Emite **ZIP64** cuando hace falta y **cifra**
  (`ZipEncryption .none/.zipCrypto/.aes256`). API de entrada: `ZipEntryInput` con
  `ZipEntrySource` (`.directory/.data/.file(url)/.rawEntry`).
- **`ZipCrypto`**, **`ZipAES`** — los dos cifrados (ver `encryption.md`).
- **`Deflate`** — DEFLATE vía framework `Compression`. **`CRC32`** — tabla estándar.

`CryptoCore` — AES-256-GCM + PBKDF2 (formato `.fpkz`, **legacy**, solo lectura).

Tests en `Tests/` (`ZipEngineTests`, `ZipCryptoTests`, `CryptoCoreTests`), con
fixtures en `Tests/ArchiveBrowserTests/Fixtures` e **interop real** contra
`zip`/`unzip`.

## App — `App/FilePackr/`

- **`ArchiveDocument`** (`@MainActor ObservableObject`) — el modelo: árbol editable
  de `FileNode` (cada uno `folder` / `diskFile(url)` / `zipEntry(entry)`), abrir
  (`openArchive` async, en segundo plano con progreso), guardar
  (`save(to:encryption:password:)` en streaming), extraer, renombrar/mover/borrar,
  estado de cifrado (`requiresEntryPassword`, `isLocked`, `saveEncryption`).
  `ExportPlan` (Sendable) materializa una entrada a disco en segundo plano (extraer,
  arrastrar, Quick Look).
- **`ArchiveOutlineView`** (`NSViewRepresentable` + `Coordinator`) — el navegador
  `NSOutlineView`: selección, columnas ordenables, arrastre (mover/extraer/añadir,
  con `NSFilePromiseProvider`), Quick Look (barra espaciadora vía `QLPreviewPanel`),
  renombrado en línea, menú contextual. Recibe callbacks `onExtract`/`onNeedPassword`.
- **`ContentView`** — barra superior (Añadir/Eliminar/Crear carpeta/Extraer), barra
  de documento (icono+nombre, candado, Cerrar/Guardar), zona de arrastre vacía,
  overlay de progreso, y los diálogos (conflicto, cerrar, contraseña, opciones de
  guardar, opciones de extraer).

## Flujo de datos típico

- **Abrir**: `ContentView.handleOpen` → `doc.openArchive` (lee índice en 2.º plano)
  → `buildTree` → el outline pinta. Si hay entradas cifradas → pide contraseña.
- **Editar**: el outline/toolbar llaman a métodos de `doc` (rename/move/delete/…),
  que marcan `revision` (el outline recarga) y `hasUnsavedChanges`.
- **Guardar**: `doc.makeSaveInputs()` (plan ligero: `.file(url)` para nuevos,
  `.rawEntry` para entradas sin cifrar, `.data` descifrada para cifradas) →
  `ZipWriter.write` en streaming a un temporal → reemplazo atómico.

## Cómo extender

- **Nuevo formato de lectura** (tar, gz…): crear un `XReader`/`XExtractor` con la
  misma forma que `ZipReader`/`ZipExtractor` y despachar por tipo en `openArchive`.
  El modelo (`FileNode`, `ExportPlan`) es genérico salvo por `.zipEntry`.
- **Nuevo cifrado**: añadir un caso a `ZipEncryption` y su rama en
  `ZipWriter`/`ZipExtractor` (+ campo extra si el formato lo requiere).
- **Convenciones**: `.jsx`/`.swift` UI vs lógica; nada de código muerto; verificar
  con `swift test` y `xcodebuild` (el agente no ejecuta la GUI).
