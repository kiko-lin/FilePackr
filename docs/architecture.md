# Arquitectura de FilePackr

Tres capas, todas menos las vistas en el paquete Swift `FilePackrCore` (testeable por CLI
con `swift test`):

1. **Motor de archivos sin UI** — `Sources/ArchiveBrowser` (no importa AppKit/SwiftUI).
2. **Modelo de la app** — `Sources/FilePackrModel` (documento, coordinadores, ajustes).
   No tiene vistas, pero sí usa AppKit/SwiftUI puntualmente (panel de carpeta, `ColorScheme`).
   Depende del motor; lo consume el target Xcode de la app. **No** contiene la i18n (`loc`):
   emite tokens y recibe los textos por inyección.
3. **App** — `App/FilePackr/` (target Xcode): solo las **vistas** SwiftUI/AppKit, la i18n
   (`loc` + `Localizable.xcstrings`) y los Servicios del Finder. Consume `FilePackrModel`.

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
  formato refinado, los bytes a conservar y las entradas), **extraer una entrada**
  (`entryData(for:in:password:)`) y **extraer varias** (`extractAll`, un solo recorrido;
  `onSkip` opcional reporta el tamaño de las entradas saltadas — solo relevante en
  `LibArchiveCodec`, cuyo iterador es secuencial sin acceso aleatorio). Concretos:
  `ZipCodec`, `TarCodec` (tar y variantes comprimidas), `SingleFileCodec` (gz/xz/bz2;
  refina `.gz`→`.tar.gz` por firma ustar) y `LibArchiveCodec`. La **escritura NO** pasa
  por aquí (rutas dispares: ver app/`ArchiveSaver`).
- **`ArchiveContainer`** (`.data(Data)` / `.rarVolumes([URL])`) — el contenedor que lleva
  `ArchiveReadResult`, generalizado más allá de `Data` para los **volúmenes RAR nativos**
  (los que crea WinRAR/`rar`, detectados por `RarVolumes`): a diferencia del esquema propio
  de FilePackr (`Volumes`/`VolumeStore`, abajo), esos no se concatenan —cada volumen lleva
  su propia cabecera intercalada— así que se abren con `archive_read_open_filenames` de
  libarchive. `RAR5TrailingServiceBlock` recorta, cuando hace falta, un bloque de servicio
  QuickOpen obsoleto que si no desincroniza el lector y produce entradas fantasma.
- **`ArchiveEntry`** — entrada **neutral** común a todos los formatos: ruta, tamaños,
  fecha, `isDirectory`, `isEncrypted`, `dataOffset?` (lo usa TAR) y `zip: ZipEntryInfo?`
  (método/CRC/local header/dosTime/flags/AES, **solo** en entradas de ZIP). Ningún otro
  formato inventa campos de ZIP a cero.

Lectores/escritores por formato:

- **ZIP** (Swift puro): `ZipReader` (índice por *central directory*, **solo lee la cola
  + el central directory**, no copia el fichero; ZIP64), `ZipExtractor` (extracción
  perezosa, descifra), `ZipWriter` (`build` en memoria / `write` en **streaming** a un
  `FileHandle`; ZIP64; cifrado), `ZipCrypto`, `ZipAES` (incluye `ZipAES.Encryptor`,
  cifrador de flujo AE-2), `Deflate` (framework `Compression`), `CRC32` (con
  `CRC32.Accumulator` incremental).
- **Streaming en memoria constante** (sin cargar el fichero entero):
  - `CompressionStream` centraliza el bucle de `compression_stream` (lee `next` / escribe
    `sink` por trozos); lo usan `Gzip`/`Xz`. Cada compresor tiene **un núcleo pull**
    `compress(next:sink:)` del que cuelgan las variantes en memoria, fichero→fichero y pipe.
  - Comprimir: `Gzip`/`Xz`/`Bzip2` con `compress(from:to:)` y `compress(_:)`; **tar** con
    `Tar.reader(items)` (generador pull que lee los ficheros de disco por trozos), encadenado
    a un compresor para `.tar.gz`/`.tar.xz`/`.tar.bz2` sin montar el tar en RAM.
  - ZIP (escritura): `ZipWriter` comprime cada entrada `.file` al vuelo con **descriptor de
    datos** (bit 3) + ZIP64; el cifrado ZipCrypto/AES (`ZipAES.Encryptor`) se aplica por trozos.
  - Descomprimir/extraer: `Gzip`/`Xz`/`Bzip2` con `decompress(_:sink:)`; `ZipExtractor.extract`
    infla y descifra al vuelo (`ZipAES.Decryptor`, MAC al final); `LibArchive.extractEntry(...,sink:)`
    (7z/iso/xar) y su escritura desde ficheros de disco al vuelo. `ArchiveCodec.extract(...,sink:)`
    expone esto por formato (el `fallback` a `entryData` solo lo usa el tar ya descomprimido en RAM).
- **tar y compresores** (Swift puro): `Tar` (ustar + PAX + GNU L), `Gzip` (RFC 1952),
  `Xz` (`COMPRESSION_LZMA`), `Bzip2` (`libbz2` del sistema vía target `Cbz2`).
- **libarchive** (`LibArchive.swift`): puente a la **libarchive del sistema** (target
  `Carchive` = systemLibrary, con `shim.h` de prototipos propios). Lee 7z/rar/iso/xar/
  cpio/lha/cab; escribe 7z/iso/xar. API de **iterador en streaming**.
- **Volúmenes propios**: `Volumes` (split/join por bytes en memoria + naming) y
  `VolumeStore` (volúmenes sobre disco: descubrir partes, trocear un fichero ya escrito, y
  `joinToTemporaryFile` —concatena las partes a un temporal mapeado sin cargarlas en RAM).
- **Volúmenes RAR nativos** (`RarVolumes.swift`, distinto de lo anterior — solo lectura, no
  concatenable): detecta el esquema moderno (`nombre.part1.rar…`, separador punto o guion
  bajo) y el legado (`nombre.rar`+`.r00…`) de WinRAR/`rar`; ver `ArchiveContainer` arriba.

Tests en `Tests/`: `ArchiveBrowserTests` (motor + codec + formatos + volúmenes + metadatos +
detección + cifrado), con interop **opcional** (se salta si la herramienta no está): `zip`/`unzip`
para ZipCrypto, `pyzipper` para AES‑256. Y `FilePackrModelTests` (documento + coordinadores de
añadir/extraer/guardar). **Todo corre con un solo `swift test`** (248 tests).

## Modelo — `Sources/FilePackrModel/`

La capa de modelo de la app, en el paquete (sin vistas), para que se pueda testear por CLI. Aquí
viven `ArchiveDocument`, los coordinadores (`AddCoordinator`/`ExtractCoordinator`/`SaveCoordinator`),
`FileNode`, `ExportPlan`, `SavePayloadBuilder`, `ArchiveSaver`, `AppSettings`, `VolumeUnit`, la
construcción del árbol (`ArchiveTreeBuilder`: de entradas o de disco) y los helpers de E/S
(`AtomicWrite`, `FolderPanel`, `UntitledNumbering`, `WorkFile` —ciclo de vida de los temporales
`.work`). La describe el resto de esta sección («App»). Las vistas la consumen vía `import FilePackrModel`.

## App (vistas) — `App/FilePackr/`

- **`ArchiveDocument`** (`@MainActor ObservableObject`) — el modelo: árbol editable de
  `FileNode` (`folder` / `diskFile(url)` / `zipEntry(entry)`). Abrir (`openArchive`
  async, delega en `format.codec.open`), extraer (`format.codec.entryData`),
  renombrar/mover/borrar/crear. **No usa i18n**: emite tokens `ProgressKind` (la vista
  traduce) y recibe los nombres por defecto inyectados. Guardar/exportar: ensambla un
  **`SavePayload`** (`makeSavePayload`, lee el árbol) y lo entrega al saver; `save`
  adopta el fichero (`markSaved`), `export` no (copia aparte). Resumen para la barra de
  estado cacheado (`contentFileCount`/`contentSize`/`contentCompressedSize`).
- **`ArchiveSaver`** (`enum`) — codifica un `SavePayload` (`Sendable`) a disco en
  segundo plano. Casos: `.zip` (streaming a `FileHandle`), `.stream` (gz/xz/bz2 y tar/
  tar.gz/.xz/.bz2 comprimidos al vuelo a un `FileHandle` sin cargar nada en RAM), `.data`
  (contenido ya en memoria) y `.libArchive` (7z/iso/xar a fichero). El documento decide
  *qué* escribir y dónde *colocar* (fichero único o volúmenes vía `VolumeStore`) —
  `singleFilePayload` elige `.stream` si el origen es `diskFile`, si no `.data`; el saver
  decide *cómo* codificar.
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
  pide contraseña. Multivolumen propio → `VolumeStore.joinToTemporaryFile` + mapeo. Volumen
  RAR nativo → `RarVolumes.parts` + `ArchiveContainer.rarVolumes` (sin concatenar).
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
- **Convenciones**: motor sin UI; modelo sin vistas ni i18n; nada de código muerto; verificar
  con `swift test` (motor + modelo) y `xcodebuild build` (la app compila); el agente no ejecuta
  la GUI. Tipo nuevo del modelo que use una vista → marcarlo `public`.
