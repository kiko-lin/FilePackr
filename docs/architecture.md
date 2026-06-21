# Arquitectura de FilePackr

Dos capas: un **motor de archivos sin UI** (paquete Swift `FilePackrCore`, testeable
por CLI) y una **app** SwiftUI/AppKit que lo consume. La línea divisoria es estricta:
el motor no importa AppKit/SwiftUI.

## Motor — `Sources/` (paquete `FilePackrCore`)

`ArchiveBrowser` (sin dependencias de UI). La pieza central es la abstracción por
**formato**:

- **`ArchiveFormat`** — enum de todos los formatos. Lleva sus **capacidades**
  (`supportsEncryption`, `isWritable`, `usesLibArchive`, `isSingleFileOnly`,
  `supportsVolumeSplit`, `libArchiveWriteFormat`) y la **detección**:
  `detectByExtension` (por nombre), `detectByMagic` (por firma/magic bytes) y
  `detect(from:contents:)` (extensión y, si no decide, firma).
- **`ArchiveCodec`** (protocolo + registro `ArchiveFormat.codec`) — centraliza
  **leer** (`open(_:fallbackName:passphrase:progress:)` → `ArchiveReadResult` con el
  formato refinado, los bytes a conservar y las entradas) y **extraer una entrada**
  (`entryData(for:in:password:)`). Concretos: `ZipCodec`, `TarCodec` (tar y variantes
  comprimidas), `SingleFileCodec` (gz/xz/bz2; refina `.gz`→`.tar.gz` por firma ustar) y
  `LibArchiveCodec`. La **escritura NO** pasa por aquí (rutas dispares: ver app/`ArchiveSaver`).
- **`ArchiveEntry`** — entrada **neutral** común a todos los formatos: ruta, tamaños,
  fecha, `isDirectory`, `isEncrypted`, `dataOffset?` (lo usa TAR) y `zip: ZipEntryInfo?`
  (método/CRC/local header/dosTime/flags/AES, **solo** en entradas de ZIP). Ningún otro
  formato inventa campos de ZIP a cero.

Lectores/escritores por formato:

- **ZIP** (Swift puro): `ZipReader` (índice por *central directory*, **solo lee la cola
  + el central directory**, no copia el fichero; ZIP64), `ZipExtractor` (extracción
  perezosa, descifra), `ZipWriter` (`build` en memoria / `write` en **streaming** a un
  `FileHandle`; ZIP64; cifrado), `ZipCrypto`, `ZipAES`, `Deflate` (framework
  `Compression`), `CRC32`.
- **tar y compresores** (Swift puro): `Tar` (ustar + PAX + GNU L), `Gzip` (RFC 1952),
  `Xz` (`COMPRESSION_LZMA`), `Bzip2` (`libbz2` del sistema vía target `Cbz2`).
- **libarchive** (`LibArchive.swift`): puente a la **libarchive del sistema** (target
  `Carchive` = systemLibrary, con `shim.h` de prototipos propios). Lee 7z/rar/iso/xar/
  cpio/lha/cab; escribe 7z/iso/xar. API de **iterador en streaming**.
- **Volúmenes**: `Volumes` (split/join por bytes en memoria + naming) y `VolumeStore`
  (volúmenes sobre disco: descubrir partes, trocear un fichero ya escrito, y
  `joinToTemporaryFile` —concatena las partes a un temporal mapeado sin cargarlas en RAM).

Tests en `Tests/` (engine + codec + formatos + volúmenes + metadatos + detección + cifrado),
con interop **opcional** (se salta si la herramienta no está): `zip`/`unzip` para
ZipCrypto, `pyzipper` para AES‑256.

## App — `App/FilePackr/`

- **`ArchiveDocument`** (`@MainActor ObservableObject`) — el modelo: árbol editable de
  `FileNode` (`folder` / `diskFile(url)` / `zipEntry(entry)`). Abrir (`openArchive`
  async, delega en `format.codec.open`), extraer (`format.codec.entryData`),
  renombrar/mover/borrar/crear. **No usa i18n**: emite tokens `ProgressKind` (la vista
  traduce) y recibe los nombres por defecto inyectados. Guardar/exportar: ensambla un
  **`SavePayload`** (`makeSavePayload`, lee el árbol) y lo entrega al saver; `save`
  adopta el fichero (`markSaved`), `export` no (copia aparte). Resumen para la barra de
  estado cacheado (`contentFileCount`/`contentSize`/`contentCompressedSize`).
- **`ArchiveSaver`** (`enum`) — codifica un `SavePayload` (`Sendable`) a disco en
  segundo plano: streaming ZIP, `Data` para tar/gz/xz/bz2, libarchive a fichero. El
  documento decide *qué* escribir y dónde *colocar* (fichero único o volúmenes vía
  `VolumeStore`); el saver decide *cómo* codificar.
- **`FileNode`** — nodo del árbol (dato puro). **`ExportPlan`** — instantánea `Sendable`
  de un nodo para materializarlo a disco en segundo plano (extraer, arrastrar, Quick Look).
- **`ArchiveOutlineView`** (`NSViewRepresentable` + `Coordinator`) — el navegador
  `NSOutlineView` (estilo `.plain`): selección, columnas ordenables, arrastre
  (mover/extraer/añadir con `NSFilePromiseProvider`), Quick Look (espacio vía
  `QLPreviewPanel`), renombrado en línea, menú contextual. Despliega y revela el nodo
  seleccionado (p. ej. carpeta recién creada).
- **`ContentView`** — la interfaz **sin barra de título** (`hiddenTitleBar`): cabecera
  (nombre + estado + `Extraer todo · Cerrar · Exportar · Guardar`), columna vertical de
  acciones de interior, el visor y una barra de estado inferior. Diálogos: conflicto,
  contraseña, opciones de guardar/exportar, extraer, y el aviso unificado de cambios sin
  guardar. `WindowGuard` intercepta el cierre de ventana; `FilePackrApp.AppDelegate` el
  salir (⌘Q). Sin pestañas de ventana. **Ajustes** en el menú (⌘,, escena `Settings`).

## Flujo de datos típico

- **Abrir**: `ContentView` → `doc.openArchive` (en 2.º plano: carga/mapea los bytes,
  `detected.codec.open`) → `buildTree` → el outline pinta. Si hay entradas cifradas →
  pide contraseña. Multivolumen → `VolumeStore.joinToTemporaryFile` + mapeo.
- **Editar**: el outline/columna llaman a métodos de `doc`, que suben `revision` (el
  outline recarga), recalculan el resumen y marcan `hasUnsavedChanges`.
- **Guardar/Exportar**: `doc.makeSavePayload(for:)` (zip: `.rawEntry` copia en crudo las
  entradas sin cifrar; resto: `Data` reconstruido) → `ArchiveSaver.encode` a un temporal
  → colocar (mover atómico o `VolumeStore.split`). `export` no toca el documento activo.

## Cómo extender

- **Nuevo formato**: un `case` en `ArchiveFormat`, su `case` en el registro
  `ArchiveFormat.codec` (+ un codec si hace falta uno nuevo), detección
  (`ArchiveFormat.detect*`), `nameKey` (en `ArchiveFormat+App.swift`) y, si es
  escribible, su rama en `makeSavePayload`/`ArchiveSaver`.
- **Nuevo cifrado**: añadir un caso a `ZipEncryption` y su rama en
  `ZipWriter`/`ZipExtractor` (+ campo extra si el formato lo requiere).
- **Convenciones**: motor sin UI; nada de código muerto; verificar con `swift test`
  (motor) y `xcodebuild` + ⌘U (app); el agente no ejecuta la GUI.
