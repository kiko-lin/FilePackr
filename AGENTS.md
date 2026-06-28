# AGENTS.md — Contexto de trabajo de FilePackr

Fichero de contexto para agentes (Claude Code) que retomen el proyecto. Mantén
este archivo al día tras cada bloque de trabajo.

## Qué es

App de macOS (SwiftUI + AppKit) para gestionar archivos comprimidos: abrir/navegar
sin descomprimir, editar, extraer, previsualizar, **convertir entre formatos** y
**cifrar con contraseña** (ZIP estándar). Formatos: **ZIP** (motor propio, lectura
y escritura, con cifrado), **tar / tar.gz / tar.xz / tar.bz2 / gz / xz / bz2**
(Swift puro), y **7z / rar / iso / xar / cpio / lha / cab** (vía libarchive del
sistema; escritura solo 7z/iso/xar). Ver `README.md` para la visión general.

- **Repo local**: `~/Desktop/Repos/FilePackr` (la app y el producto son **FilePackr**).
- **Remoto git**: `git@github.com:kiko-lin/packr.git` (SSH). El entorno del agente
  **no tiene red** → los `git push` los hace el usuario.
- **Plataforma**: macOS 26 (Tahoe), Swift 6.3, Xcode 26. App target `FilePackr`,
  bundle `com.kiko.FilePackr`, lenguaje Swift 5 mode con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

## Cómo trabajar (importante)

- **Tests del motor**: `swift test` (rápido, sin Xcode). 83 tests.
- **Tests de la app** (modelo `ArchiveDocument`): target `FilePackrTests` en Xcode,
  se corren con **⌘U** (o `xcodebuild test`). NO los recoge `swift test` (viven en el
  `.pbxproj`, no en el paquete). 6 tests.
- **Tests de interop** (verifican compatibilidad con herramientas externas): llaman a
  un binario del sistema y se **saltan solos** (`XCTSkipUnless`) si no está, de modo que
  `swift test` siempre queda en verde sin instalar nada (exit 0; salen como *skipped*).
  - ZipCrypto: `/usr/bin/zip` y `/usr/bin/unzip` (Info-ZIP, casi siempre presentes).
  - **AES-256**: contra `pyzipper` (Python). Para activarlos: `pip3 install pyzipper`
    y reejecutar `swift test`. Patrón a seguir para futuros tests de interop: guardar
    con `XCTSkipUnless` al principio del test, nunca asumir que la herramienta está.
- **Compilar la app**: `xcodebuild -project App/FilePackr.xcodeproj -scheme FilePackr -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`.
  - El agente **no puede ejecutar la GUI** ni verificar comportamiento visual:
    solo compilar. El usuario prueba en Xcode (⌘R) y reporta.
  - ⚠️ **No compiles con `CODE_SIGNING_ALLOWED=NO` en el DerivedData de Xcode**:
    deja el `.app` sin firmar y al pulsar ▶ en Xcode falla con *"Unable to obtain a
    task name port right … (os/kern) failure 0x5"* (el depurador no puede
    adjuntarse: falta `get-task-allow`). Para verificación usa un DerivedData aparte:
    `xcodebuild … -derivedDataPath /tmp/fp-verify CODE_SIGNING_ALLOWED=NO build`.
    Si ya se ensució: recompila firmado (sin esa flag) o el usuario hace Clean Build
    Folder (⇧⌘K) y ▶. Firma: automática, equipo `J5HQ9TN2HX`, bundle `com.kiko.FilePackr`.
  - **Índice de SourceKit**: al crear ficheros nuevos por fuera de Xcode (grupos
    sincronizados, objectVersion 77) el editor puede mostrar "Cannot find X in scope"
    aunque compile; se arregla borrando el DerivedData del proyecto y reabriendo.
- **Caché de Xcode**: tras renombrar o cambiar el icono, suele hacer falta
  **Clean Build Folder (⇧⌘K)** y a veces `killall Dock`. La resolución de paquetes
  se atasca a veces → File → Packages → Reset Package Caches.
- **Idioma**: comunicación e interfaz en **español de España**.
- **Estilo**: simplicidad, sin código muerto, causas raíz. Verificar con tests
  antes de dar por hecho.

## Arquitectura (dónde está cada cosa)

- Motor (paquete `FilePackrCore`, `Sources/`):
  - `ArchiveBrowser`: `ZipReader` (índice + ZIP64; **solo lee la cola + central
    directory**, no copia el fichero), `ZipExtractor` (extrae/descifra),
    `ZipWriter` (escribe; `build` en memoria y `write` en streaming a `FileHandle`;
    ZIP64; `ZipEncryption .none/.zipCrypto/.aes256`), `ZipCrypto`, `ZipAES`,
    `Deflate` (framework Compression), `CRC32`. También `Tar`, `Gzip`, `Xz`,
    `Bzip2`, `LibArchive`, `Volumes`.
  - **`ArchiveEntry`** (tipo común a todos los formatos): campos **neutrales** (ruta,
    tamaños, fecha, `isDirectory`, `isEncrypted`) + `dataOffset?` (offset de datos, lo
    usa TAR) + `zip: ZipEntryInfo?` (método/CRC/local header/AES…, presente **solo** en
    entradas de ZIP). Ningún otro formato inventa campos de ZIP a cero.
  - **`ArchiveFormat`** (enum del formato; capacidades `supportsEncryption`/
    `isWritable`/`usesLibArchive`…, `fileExtension`, y detección por nombre
    `detect(from:)`/`isOpenableArchive(_:)`). El `nameKey` (localización) vive en la
    app (`ArchiveFormat+App.swift`).
  - **`ArchiveCodec`** (protocolo + registro `ArchiveFormat.codec`): centraliza
    **leer** (`open` → `ArchiveReadResult`, refina `.gz`→`.tar.gz`) y **extraer una
    entrada** (`entryData`) de cada formato. Antes era un `switch` repetido por el
    documento. Codecs: `ZipCodec`, `TarCodec`, `SingleFileCodec`, `LibArchiveCodec`.
    La **escritura** no va por aquí (rutas dispares: ver `ArchiveSaver`).
  - **`VolumeStore`**: volúmenes sobre disco (`parts`/`gather`/`removeContinuations`/
    `split(file:)` y `joinToTemporaryFile` —concatena las partes a un temporal mapeado
    sin cargarlas en RAM), sobre el esquema de nombres de `Volumes`.
  - Detección de formato en `ArchiveFormat`: `detectByExtension` (por nombre),
    `detectByMagic` (por firma) y `detect(from:contents:)` (extensión y, si no decide,
    firma). `openArchive` y la decisión abrir-vs-añadir caen a la firma si la extensión falla.
- App (`App/FilePackr/`):
  - `ArchiveDocument` (`@MainActor ObservableObject`): árbol `FileNode` (en
    `FileNode.swift`), abrir (`openArchive` async, delega en `format.codec`),
    extraer (`format.codec.entryData`), mover/renombrar, progreso. Para guardar,
    **ensambla un `SavePayload`** (`makeSavePayload`, lee el árbol) y delega en
    `ArchiveSaver`.
  - **`ArchiveSaver`** (`ArchiveSaver.swift`): codifica un `SavePayload` (`Sendable`)
    a disco en segundo plano (streaming ZIP, `Data` para tar/gz/xz/bz2, libarchive a
    fichero). El documento decide *qué* escribir y *colocar* (fichero único o
    volúmenes vía `VolumeStore`); el saver decide *cómo* codificar.
  - `ExportPlan` (`ExportPlan.swift`): instantánea `Sendable` de un nodo para
    extraer en segundo plano al soltar en el Finder.
  - `ArchiveOutlineView` (`NSViewRepresentable` + `Coordinator`): el navegador
    `NSOutlineView` — selección, columnas ordenables, arrastre (mover/extraer/
    añadir), Quick Look (barra espaciadora), renombrado en línea, menú contextual.
  - `ContentView`: la interfaz, **sin barra de título** (`hiddenTitleBar`, el contenido
    sube). Con archivo abierto: **cabecera** (nombre del archivo + 🔒/volúmenes/“sin
    guardar”, y a la derecha `Extraer todo · Cerrar · Exportar · Guardar`), **columna
    vertical** de acciones de interior a la izquierda (Añadir/Crear carpeta/Eliminar/
    Extraer, icono+etiqueta), el visor (`ArchiveOutlineView`) y una **barra de estado**
    inferior (nº de ficheros + tamaño + comprimido). Estado vacío: zona de arrastre
    **clicable**. Diálogos: conflicto de extracción, contraseña (entrada/apertura),
    opciones de guardar/exportar, extraer, y el aviso unificado de cambios sin guardar.
  - `WindowGuard` (`WindowGuard.swift`): `UnsavedChangesAlert` (aviso único de “cambios
    sin guardar”) + delegado de `NSWindow` para interceptar el cierre de ventana; el
    salir (⌘Q) lo cubre el `AppDelegate` (`FilePackrApp.swift`). **Sin pestañas de
    ventana** (`allowsAutomaticWindowTabbing = false`): cada archivo en su ventana.
  - `FinderServicesProvider` (`FinderServices.swift`): los **Servicios de macOS** del menú
    contextual del Finder («Abrir en FilePackr» / «Descomprimir aquí»). Declarados en
    `Info.plist` (`NSServices`), registrados por `AppDelegate`. «Descomprimir aquí» extrae sin
    UI reusando `ExportPlan.writeContents`. Helpers compartidos en `AppHelpers.swift`
    (`archiveBaseName`, `localizedErrorMessage`).

## Hecho

- **Sesión 2026-06-28 — i18n al idioma del sistema + dos items de UX del TODO**:
  - **i18n idiomática** (commit `refactor(i18n)`): la app sigue el idioma del **sistema** vía
    **String Catalog** (`Localizable.xcstrings`, EN+ES); `es` en `knownRegions`. Se retiraron
    `Localizer`/`Language`/selector de idioma y el parche del menú; `loc(...)` es función global
    sobre `NSLocalizedString`. AppKit localiza gratis menú/paneles/«Clase». Ver sección i18n.
  - **Extracción "Última carpeta usada"**: nuevo `ExtractDestinationMode.lastUsedFolder` +
    `AppSettings.lastUsedExtractFolder`, fijada en `ExtractCoordinator.confirm` y usada en
    `prepareDestination`. Visible en Ajustes (informativa).
  - **Servicios del Finder** (`FinderServices.swift`, `Info.plist` `NSServices`): «Abrir en
    FilePackr» y «Descomprimir aquí» (extracción headless reusando `ExportPlan.writeContents`).
    Helpers `archiveBaseName`/`localizedErrorMessage` extraídos a `AppHelpers.swift`. Ver TODO
    para la verificación en GUI pendiente (registro de Servicios + títulos en inglés).

- **Tercera auditoría (2026-06-22, rama `refactor/auditoria-2026-06-22`)** — informe en
  `docs/auditoria-2026-06-22.md`. Sin hallazgos críticos; 4 MEDIO + 4 BAJO resueltos en 5 commits:
  - **M-A**: nomenclatura neutral en el árbol (`NodeSource.zipEntry`→`.entry`, `FileNode.zipDate`→
    `entryDate`); cierra el item 3 a nivel de app (las entradas de cualquier formato ya eran neutrales).
  - **M-B**: `ArchiveSaver` escribe **directo** al temporal de trabajo; se retiró la atomicidad interna
    (redundante: el documento ya coloca `work`→`url` atómicamente). `writeFileAtomically` queda solo
    para la extracción a una ruta real del Finder (`ExportPlan`).
  - **M-C**: nuevo `SaveCoordinator` (en `OperationCoordinators.swift`) para el flujo Guardar/Exportar,
    como Añadir/Extraer. `ContentView` 608→562 LOC, `@State` 17→8. La ejecución (panel + async + error)
    la inyecta la vista por closure (`runSave`).
  - **M-D**: `SingleFileCodec.open` infla en streaming solo los 263 B de cabecera para la firma ustar
    (antes inflaba todo el gz/xz/bz2 solo para mirarla).
  - **B-A** (`describe` cubre `ZipWriteError`), **B-B** (`gzip.entries`/`storedFilename` sin copiar el
    `.gz` a `[UInt8]`), **B-C** (`provideEntryPassword` simétrico), **B-D** (`pendingAfterSave` no queda
    colgado si el guardado falla).
  - Verificado: motor 83 tests + app 6 tests verdes; compila sin avisos. PENDIENTE: verificación en
    GUI del flujo Guardar/Exportar refactorizado + `git push` (lo hace el usuario).

- **Sesión 2026-06-21 (e) — streaming en libarchive (7z/iso/xar)**: `LibArchive.WriteItem`
  acepta origen `.file(url)` (se lee al vuelo con `writeBody`, sin cargar el fichero en RAM);
  `LibArchive.extractEntry(...,sink:)` emite el contenido por trozos (`streamData`), y
  `extractEntry(...) -> Data`/`readData` cuelgan de él. `LibArchiveCodec.extract(...,sink:)`
  y `makeLibArchiveItems` pasan los ficheros como URL. 81 tests del motor verdes (incluye
  7z escrito desde disco y extraído a sink). Único caso restante: apertura de tar comprimido.

- **Sesión 2026-06-21 (d) — tar en streaming + descompresión en streaming**:
  - **Núcleo pull único por compresor**: `Gzip`/`Xz`/`Bzip2` exponen `compress(next:sink:)`
    (lee por trozos `next`, emite por trozos `sink`); las variantes en memoria, fichero→
    fichero y el pipe tar cuelgan de ahí. Se retiró `Deflate.deflate` (gzip ya usa el núcleo).
  - **tar en streaming**: `Tar.WriteItem.Source` (`.data`/`.file(url)`) + `Tar.reader(items)`
    (generador **pull** del flujo TAR que lee los ficheros de disco por trozos). `Tar.write(_:)`
    es ahora un adaptador del generador. `makeTarItems` pasa los ficheros como URL. Los cuatro
    formatos tar van por `.stream` encadenando `Tar.reader → compresor → fichero` (sin temporal).
  - **descompresión/extracción en streaming**: `Gzip`/`Xz`/`Bzip2` ganan `decompress(_:sink:)`
    (bzip2 con la API incremental `BZ2_bzDecompressInit/Decompress/End`; se retiró
    `BZ2_bzBuffToBuffCompress` y `BZ_OUTBUFF_FULL`). `ZipExtractor.extract(_:in:password:sink:)`
    infla y descifra al vuelo (ZipCrypto/AES); en AES valida la contraseña al empezar (pv) y el
    **MAC al final**. `ArchiveCodec.extract(...,sink:)` (con fallback a `entryData` para tar ya
    en RAM y libarchive) + sobrecargas en `ZipCodec`/`SingleFileCodec`. `ExportPlan` extrae a
    un temporal y mueve al final (atomicidad + limpieza si el MAC falla a mitad).
  - **DRY cifrado**: `ZipAES.CTRKeystream` (keystream CTR por trozos) lo comparten `ctrCrypt`,
    `Encryptor` y el nuevo `ZipAES.Decryptor` (espejo del `Encryptor`).
  - **Tests**: round-trip tar/tar.gz/.xz/.bz2 desde fichero de disco + interop `tar` del sistema;
    descompresión gz/xz/bz2 a sink; extracción ZIP a sink (sin cifrar, ZipCrypto, AES + clave
    incorrecta). 80 tests del motor verdes; app compila.

- **Sesión 2026-06-21 (c) — streaming de compresión (memoria constante)**: comprimir ya
  no requiere tener el fichero entero en RAM (pico antes ≈ original + comprimido).
  - **Primitivas**: `CRC32.Accumulator` (CRC incremental por trozos) y `CompressionStream`
    (centraliza el bucle de `compression_stream` leyendo/escribiendo por trozos; lo usan
    gzip y xz, antes el bucle vivía dentro de `Xz`).
  - **gz/xz/bz2**: cada uno gana `compress(from:to:)` (fichero→fichero). Clave de diseño:
    **una sola implementación por algoritmo** con dos adaptadores (en memoria / fichero).
    xz/gzip comparten `CompressionStream.run`; bzip2 tiene un núcleo incremental único
    (`compressStream`, API `BZ2_bzCompressInit`/`Compress`/`End`) del que cuelgan ambas
    variantes — ya **no** se usa `BZ2_bzBuffToBuffCompress`. Los puntos de entrada en
    memoria siguen porque hay datos que ya están en RAM (tar montado, entradas de un
    archivo abierto): ahí no hay fichero del que hacer streaming.
  - **ZIP**: `ZipWriter` comprime cada entrada `.file` al vuelo desde disco. Como CRC y
    tamaños no se conocen al escribir la cabecera local, usa **descriptor de datos** (bit 3)
    + **ZIP64 siempre** en la entrada en streaming (tamaños 0xFFFFFFFF + extra; los valores
    reales van en el descriptor tras los datos y en el central directory, que es el que lee
    el lector). `makeRecord` ya no maneja `.file` (`preconditionFailure`).
  - **Cifrado en streaming**: `ZipCrypto` ya era incremental; `ZipAES.Encryptor` (nuevo)
    cifra AE-2 por trozos (CTR con contador continuo + HMAC-SHA1 incremental, MAC al final)
    y es la **única** implementación del cifrado: `ZipAES.encrypt(buffer)` es ahora un
    adaptador fino sobre `Encryptor` (antes duplicaba la secuencia CTR+HMAC). Refactor:
    `ZipAES.keystreamBlock` (compartido con `ctrCrypt` del descifrado) y `aesExtraField` en
    `ZipWriter` (compartido con `aesExtra`).
  - **App**: nuevo `SavePayload.stream` + `ArchiveSaver.streamToFile`; `ArchiveDocument.
    singleFilePayload` elige streaming si el origen es `diskFile`, si no la ruta en memoria.
  - **Tests** (`StreamingCompressionTests` + extras): CRC incremental, round-trip gz/xz/bz2,
    ZIP `.file` (round-trip + flag bit 3 + interop `unzip`), ZIP cifrado ZipCrypto/AES
    (round-trip + contraseña incorrecta) e **interop pyzipper del AES en streaming**. 71
    tests del motor verdes; app compila (xcodebuild).

- **Sesión 2026-06-21 (b) — selección múltiple, multi-extraer, conflicto al añadir,
  aviso de cierre con 3 botones**:
  - `ArchiveDocument.selection` (un `FileNode.ID?`) pasó a **`selectedIDs: Set<FileNode.ID>`**.
    `NSOutlineView.allowsMultipleSelection = true`; el coordinator sincroniza el `Set`
    en ambos sentidos (`syncSelection` revela ancestros y enfoca todas las filas).
    **Borrado en lote** (`removeSelected` + tecla Supr) y **arrastre múltiple** (ya iba
    por `draggedNodes`). Botones Eliminar/Extraer activos con `!selectedIDs.isEmpty`.
  - **Multi-extraer**: `ExtractRequest.makePlans: () -> [ExportPlan]`; el botón Extraer con
    varios seleccionados encola un plan por nodo y `processNextExtraction()` los procesa
    uno a uno encadenando el diálogo de conflicto (Sobrescribir/Guardar como/Cancelar→aborta
    el lote). Clave i18n `extract.items` ("%@ elementos").
  - **Añadir/arrastrar revela y enfoca** lo añadido (selección = nodos nuevos), igual que
    crear carpeta; arrastrar sobre un **archivo bloqueado pide la clave** antes de añadir
    (el drop pasa por `editGuarded` vía la closure `onAddFiles` del outline view).
  - **Conflicto de nombre al añadir**: si el nombre ya existe en el destino, diálogo
    **Sobrescribir / Conservar ambos / Cancelar** (`add.conflict.*`). Cola `startAdd →
    processNextAdd → finishAdd` en la vista; modelo: `child(named:in:)`,
    `uniqueChildName` (conserva extensión, "nombre 2.ext"), `addFile(_:into:replacing:renameTo:)`,
    `archiveToOpen(from:)`/`addTargetFolder()` para que la vista decida abrir-vs-añadir y
    resuelva conflictos. (El `addFiles` en lote se conserva para el test de round-trip.)
  - **Aviso de cambios sin guardar → 3 botones**: `UnsavedChangesAlert` devuelve un
    `Choice` (`.save`/`.discard`/`.cancel`) en vez de un `Bool`. Botones **Guardar**
    (por defecto), **Cancelar** (Escape) y **Cerrar sin guardar** (destructivo, a la
    izquierda). "Guardar" ejecuta el flujo real (`saveDocument(then:)`, incluido el panel
    para documento nuevo, con `pendingAfterSave`) y **luego** cierra. Funciona en los tres
    caminos: botón Cerrar, cierre de ventana (`WindowGuard` con closure `onSave`) y salir
    ⌘Q (`AppDelegate` busca el guardado de la ventana editada en `WindowSaveHandlers`).
    Claves i18n: `unsaved.dontSave` (antes `unsaved.continue`), título/mensaje reescritos.
  - Estado: **compila** (`BUILD SUCCEEDED`). Sin verificación en GUI esta sesión (computer-use
    sin permisos de Accesibilidad/Grabación); el usuario revisa en Xcode. Limitación conocida
    (igual que antes): al salir con varias ventanas editadas, el aviso atiende la primera.
- Navegar ZIP sin descomprimir; apertura rápida (no copia el fichero).
- ZIP64 lectura y escritura (+test de 70.000 entradas).
- Editar: añadir/borrar/renombrar/mover (drag a carpetas)/crear carpeta.
- Extraer (botón / menú / arrastre al Finder) + diálogo de conflictos.
- Quick Look (espacio), columnas Finder ordenables, iconos por tipo.
- Operaciones en segundo plano con barra de progreso; guardado en streaming.
- Cifrado ZIP estándar: **ZipCrypto (Débil)** — interop verificada contra
  `zip`/`unzip`; **AES-256 WinZip (Fuerte)** — round-trip propio verificado.
- Diálogo de guardar: selector de formato (ZIP/TAR/TAR.GZ/GZIP) + cifrado
  (none/débil/fuerte, solo ZIP) + contraseña. GZIP solo si el documento es un único fichero.
- **tar / gzip / tar.gz (Tier 1)**: lectura y escritura en Swift puro, interop
  **bidireccional** verificada contra `tar`/`gzip`/`gunzip` del sistema.
  `Tar.swift` (ustar + PAX `x` + GNU `L`), `Gzip.swift` (RFC 1952), `Deflate.deflate`.
  La app detecta el formato al abrir y reconstruye el contenido al guardar en otro.
- **xz / tar.xz (Tier 2)**: lectura y escritura en Swift puro vía la *Compression
  framework* (`COMPRESSION_LZMA`, cuya salida es `.xz` estándar). `Xz.swift`
  (compress/decompress en streaming + parseo del Index para el tamaño). Interop
  **bidireccional** verificada: `.xz` contra `python3 lzma` (liblzma) y `.tar.xz`
  contra `bsdtar -J` (liblzma 5.4.3).
- **bzip2 / tar.bz2 (Tier 3)**: enlaza la **`libbz2` del sistema** (target SwiftPM
  `Cbz2` = systemLibrary, modulemap expone `bzlib.h` del SDK + `link "bz2"`).
  `Bzip2.swift` usa `BZ2_bzBuffToBuff*` (descompresión con búfer creciente porque
  bzip2 no guarda el tamaño). Interop verificada: `.bz2` vs `bzip2`/`bunzip2`,
  `.tar.bz2` vs `bsdtar -j`. `ArchiveFormat.isSingleFileOnly` agrupa gz/xz/bz2.
- **7z (lectura+escritura) / rar (solo lectura) (Tier 4)**: vía la **`libarchive`
  del sistema** (NO vendorizada; Apple la mantiene). Target SwiftPM `Carchive` =
  systemLibrary con `shim.h` de prototipos **propios** (Apple no trae las cabeceras
  pero sí el stub `libarchive.tbd`) + `link "archive"`. `LibArchive.swift`:
  `listEntries`/`extractEntry` (iterador en streaming, re-abre para extraer por ruta)
  y `write7z`. **El escritor de 7z de libarchive NO cifra** → 7z se escribe en claro;
  el **descifrado de 7z solo en lectura** (passphrase). 7z con cabeceras cifradas →
  `requiresOpenPassword`/`provideOpenPassword`. `ArchiveFormat.isWritable` (rar=false)
  y `.usesLibArchive`. rar se excluye del diálogo Guardar.
- **iso/cpio/xar/lha/cab** (misma libarchive): **lectura** de los cinco; **escritura**
  de iso y xar (`LibArchive.WriteFormat`). cpio/lha/cab son solo lectura. Añadir más
  formatos = un `case` en `ArchiveFormat` + su `case` en el registro `ArchiveFormat.codec`
  + detección (`ArchiveFormat.detect`) + `nameKey` (localización) + el `case` de
  escritura en `makeSavePayload`/`ArchiveSaver` si es escribible (la lectura por
  libarchive ya va por `support_format_all`; la escritura necesita su `archive_write_set_format_*`).
- **Volúmenes** (división por bytes): `Volumes.swift` (split/join + naming, testeado).
  Esquema `nombre.zip`, `nombre_001.zip`, `nombre_002.zip`… (1ª parte = nombre base).
  Diálogo Guardar con toggle "Dividir en volúmenes" + tamaño/unidad, por formato
  (`supportsVolumeSplit`). Al abrir cualquier parte se reúnen y concatenan; re-guardar
  conserva el troceo. Guardar como fichero único limpia los `_NNN` sobrantes.
- **Pedir contraseña al abrir** un zip cifrado (de otra app): valida la clave
  extrayendo la primera entrada y la recuerda (`entryPassword`) para extraer/
  previsualizar/arrastrar. `ExportPlan.zipEntry` lleva la contraseña.
- **Re-guardar conserva el cifrado**: al abrir un cifrado se detecta su tipo y, con
  la contraseña, se re-cifra al guardar; las entradas cifradas se descifran a texto
  claro en `makeSaveInputs` (no se copian en crudo a un zip plano).
- **Bloqueo de solo lectura**: un cifrado sin contraseña no se puede editar
  (renombrar/borrar/mover/crear/añadir); al intentarlo se pide la clave
  (`doc.isLocked`). Doble blindaje: guard en la UI y en el documento.
- Diálogo de extracción compacto (destino = carpeta del zip; "Elegir…" abre el
  navegador; contraseña si hace falta). **Extraer todo**: botón en la cabecera que
  descomprime el archivo entero a una carpeta con su nombre (`exportPlanForAll`).
- **Auditoría de arquitectura** (2026-06-20, items 1-7): `ArchiveCodec` (registro
  `ArchiveFormat.codec`), `ArchiveDocument` troceado 1151→~760 LOC (`FileNode`,
  `ExportPlan`, `ArchiveSaver`, `VolumeStore`), `ArchiveEntry` neutral, modelo sin
  `Localizer`, multivolumen sin cargar todo en RAM, detección por firma. Tests 49→61.
  Tests del modelo de la app en `FilePackrTests` (⌘U). Ver sección Arquitectura.
- **Exportar** (`ArchiveDocument.export`): escribe una **copia** con otro formato/
  cifrado/contraseña/volúmenes **sin cambiar el documento activo** (no llama a
  `markSaved` ni muta los ajustes recordados, a diferencia de `save`). Comparten la
  pieza `writeArchive`. Test de app `testExportDoesNotChangeDocument`.
- **Aviso de cambios sin guardar** en los 3 caminos de cierre (botón Cerrar, cerrar
  ventana, salir ⌘Q): un único `UnsavedChangesAlert` (NSAlert como hoja); `WindowGuard`
  para la ventana y `AppDelegate.applicationShouldTerminate` para salir.
- **Barra de estado** inferior (con contenido): nº de ficheros · tamaño · comprimido.
  Resumen cacheado en el modelo (`contentFileCount`/`contentSize`/`contentCompressedSize`),
  recalculado en `changed()` (no en cada render).
- **Rediseño de UI** (sesión 2026-06-21): sin barra de título (`hiddenTitleBar`),
  acciones de interior en **columna vertical** a la izquierda del visor, cabecera con
  nombre + acciones de archivo, sin pestañas de ventana. La tabla usa estilo `.plain`
  (el `.inset` pintaba un separador inicial en la cabecera). Al **crear una carpeta**
  dentro de otra, la vista despliega y revela la nueva (`expandAncestors` en el
  coordinator). Editar sobre un archivo bloqueado pide la clave y **ejecuta la acción
  pendiente** al desbloquear (`editGuarded` recuerda la acción).
- **Ajustes** (`SettingsView.swift` + `AppSettings.swift`): en el **menú nativo de la
  app** (⌘,, escena `Settings`), no en la interfaz. `AppSettings` (@MainActor,
  ObservableObject, UserDefaults, en caliente): **tema** (sistema/claro/oscuro →
  `preferredColorScheme`), **formato por defecto**, **cifrado por defecto** (se aplican
  a documentos nuevos en `saveDocument`) y **destino de extracción** (carpeta del archivo
  o carpeta fija, se aplica en `extract`). El idioma sigue en `Localizer`.
- **Icono de app**: único, generado desde un SVG (diamante) a `AppIcon.appiconset`
  (todos los tamaños). Ya **no** hay selector de icono ni cambio en caliente (se
  retiraron `AppIconOption` y los 5 image sets de color).
- **i18n** (`Localization.swift` + `Localizable.xcstrings`): **sigue el idioma del sistema**
  (lo idiomático en macOS; reescrito 2026-06-28, antes había un `Localizer` con selector interno
  y cambio en caliente). Los textos viven en un **String Catalog** (`Localizable.xcstrings`, EN+ES);
  el proyecto declara `es` en `knownRegions`, así que macOS elige el idioma y **AppKit localiza
  gratis** la barra de menús, los paneles del sistema y la columna **«Clase»** (`UTType`) — ya no
  hace falta código propio para el menú. Uso en vistas/AppKit: `loc("clave")` / `loc("clave", arg)`,
  ahora **funciones globales** (en `Localization.swift`) sobre `NSLocalizedString` (sin
  `ObservableObject`/`@EnvironmentObject`, porque el idioma no cambia en caliente). El modelo no usa
  i18n (auditoría item 4): emite tokens (`ProgressKind`) y las vistas traducen. **Para añadir texto**:
  nueva entrada en `Localizable.xcstrings` (Xcode) con EN+ES. **No hay selector de idioma en Ajustes.**

## TODO (objetivos pendientes, ordenados por importancia — revisión 2026-06-26)

> **Criterio de orden:** impacto en todos los usuarios × esfuerzo × riesgo de dejarlo sin hacer.
> Los items de formato/streaming de pura completitud van al final, en este orden:
> **DMG ≈ 7z-cifrado (baja) > tar-open (muy baja) > multinúcleo (solo si el rendimiento duele)**.

- [x] ~~**Traducir el menú de la app**~~ (HECHO 2026-06-28, pendiente verificación en GUI):
      resuelto de raíz **pasando a lo idiomático en macOS**: la app **sigue el idioma del sistema**
      en vez de tener selector interno. Migración: textos a **String Catalog** (`Localizable.xcstrings`,
      EN+ES), `es` añadido a `knownRegions`, `Localizer`/`Language`/selector de idioma retirados y
      `loc(...)` convertido en función global sobre `NSLocalizedString`. Así **AppKit localiza gratis**
      la barra de menús completa, los paneles del sistema y la columna «Clase» (`UTType`) según el SO —
      sin el parche `MainMenuLocalizer` (eliminado). Compila; el build genera `en.lproj` + `es.lproj`.
      **Verificar en GUI**: poner el Mac (o la app, en Ajustes → Idioma y región → Apps) en español y
      ver toda la app + el menú en español; en inglés, en inglés.
- [ ] **Verificar en GUI los flujos del refactor de auditoría (rama `refactor/auditoria-2026-06-21`)**
      · el agente solo compila/test del modelo, no ejecuta la GUI. Probar en Xcode (⌘R) y reportar:
  - **Añadir con conflicto** de nombre → Sobrescribir / Conservar ambos / Cancelar (H-2b).
  - **Extraer en lote** con conflictos → diálogo "Sobrescribir / Conservar ambos / Cancelar".
  - **Caso concreto reportado**: carpeta con «React Compiler – React» y «…React 2»; extraer
    «…React», «…React 2», «…React 3» y, con "conservar ambos", verificar que C acaba como
    «…React 3» (su nombre) y **no hay dos ficheros con el mismo nombre** (fix `5772c41`:
    el alternativo evita disco ∪ lo ya extraído del lote ∪ los nombres literales pendientes).
  - **Guardar/Exportar** en cada formato (zip, tar.gz, 7z, gz…) sigue produciendo el archivo correcto.
  - Una vez validado, el usuario hace el `git push` (el agente no tiene red).
  - Deuda de validación pendiente sobre código ya mergeado: bloquea confianza en el refactor.
- [ ] **Comportamiento configurable al arrastrar un archivo al icono de la app**
      (Dock/Finder) · análisis hecho 2026-06-26: hoy `.onOpenURL` (`ContentView.swift:142`)
      → `handleOpen()` siempre abre y muestra contenido (`doc.openArchive()`), sin
      opción. No existe preferencia alguna en `AppSettings` para esto.
  - Nuevo enum `FileOpenAction` (`.open` / `.extract` / `.ask`) en `AppSettings`,
    persistido igual que `extractMode`.
  - `handleOpen()` consulta la preferencia: si `.extract`, salta `openArchive()` y va
    directo a extracción (reusa `extractMode`/`fixedExtractFolder` ya existentes para
    el destino); si `.ask`, alerta "¿Abrir o extraer?" antes de decidir.
  - Exponer el Picker en `SettingsView`.
  - Esfuerzo bajo: no toca `CFBundleDocumentTypes` ni `AppDelegate`, el flujo de
    apertura ya es robusto y centralizado. Uso diario frecuente.
- [x] ~~**Carpeta de extracción por defecto: opción "Última usada"**~~ (HECHO 2026-06-28):
      nuevo case `lastUsedFolder` en `ExtractDestinationMode`; `AppSettings.lastUsedExtractFolder:
      URL?` persistida igual que `fixedExtractFolder`. `ExtractCoordinator.confirm` la fija al
      confirmar cada extracción (recibe `settings`), y `prepareDestination` la usa cuando el modo
      es `.lastUsedFolder` (cae a la carpeta del archivo / home si aún no hay). En Ajustes el Picker
      la incluye solo (CaseIterable) y muestra la carpeta recordada (informativa, sin "Elegir…").
      Clave `extract.dest.lastUsedFolder` EN/ES. Compila; build genera la clave en en/es.lproj.
- [x] ~~**Menú contextual de Finder** ("Abrir en FilePackr", "Descomprimir aquí")~~
      (HECHO 2026-06-28, pendiente verificación en GUI): vía **NSServices** (sin sandbox, sin
      target aparte). `FinderServicesProvider` (`FinderServices.swift`) con dos `@objc` que casan
      con `NSMessage`; registrado en `AppDelegate` (`NSApp.servicesProvider` + `NSUpdateDynamicServices`).
      `NSServices` declarado en `Info.plist` (`NSSendFileTypes` = los mismos UTIs que abrimos).
  - **Abrir en FilePackr**: entrega las rutas a la app por la vía normal (`NSWorkspace.open`
    con nuestro bundle), igual que el doble clic.
  - **Descomprimir aquí**: extracción **headless** reusando `openArchive` + `exportPlanForAll` +
    `ExportPlan.writeContents` (a una carpeta hermana libre `<nombre>`/`<nombre> 2`); revela lo
    extraído en el Finder. Si el archivo pide contraseña (`isLocked`/`requiresOpenPassword`), cae a
    abrirlo en la app. Errores → `NSAlert` (mensajes vía `localizedErrorMessage`, extraído a
    `AppHelpers.swift` junto con `archiveBaseName`, antes privados de `ContentView`).
  - **Títulos localizados**: `InfoPlist.xcstrings` traduce los títulos de los Servicios (AppKit
    los busca en `InfoPlist.strings` por su título inglés). El build genera `en/es.lproj/InfoPlist.strings`;
    falta confirmar en GUI que el menú los muestra traducidos.
  - **PENDIENTE de verificar en GUI**: el Servicio solo aparece tras registrar el `.app` con
    Launch Services (`pbs`): instalar en /Applications o `/System/Library/CoreServices/pbs -update`
    y, si hace falta, reiniciar sesión. Probar «Abrir» y «Descomprimir aquí» (incl. uno cifrado →
    debe abrir la app para pedir clave) y que los títulos salgan en el idioma del sistema.
- [ ] **Convertir un icono de la barra superior en menú con opciones rápidas**
      (`documentBar`, `ContentView.swift:324`, botones a la derecha: Extraer todo ·
      Cerrar · Exportar · Guardar) · análisis hecho 2026-06-26: hoy son `Button`
      simples en un `HStack` custom (no hay `NSToolbar` nativo), cambiar a `Menu` de
      SwiftUI es directo.
  - **Candidato principal: Exportar** (`ContentView.swift:350`) — hoy abre siempre la
    hoja completa de opciones; menú propuesto: accesos directos a formatos usados
    ("Exportar a ZIP", "Exportar a TAR.GZ"…) + separador + "Exportar como…" (hoja
    completa, comportamiento actual).
  - Candidato secundario: **Extraer todo** — "Extraer aquí" / "Extraer en…" /
    "Extraer a escritorio".
  - Reusa `SaveCoordinator`/hoja de opciones existentes, solo parametrizar el punto
    de entrada (formato preseleccionado).
  - Esfuerzo bajo (< 1h por icono), sin bloqueos arquitectónicos.
- [ ] **Título de ventana = nombre del archivo (y numerar los nuevos)** · análisis hecho
      2026-06-28: hoy el menú **Ventana** de macOS lista todas las ventanas igual porque **no se
      fija ningún `title`** (`WindowGroup` + `.windowStyle(.hiddenTitleBar)` en `FilePackrApp.swift`;
      la barra de título está oculta pero el `title` sigue alimentando el menú Ventana y Mission
      Control). Además los documentos nuevos no se numeran: `ArchiveDocument.documentName` queda
      vacío y la vista lo muestra como «Sin título» (`ContentView.documentDisplayName`,
      `ContentView.swift:230`), así que dos ventanas nuevas se verían ambas como «Sin título».
  - **Fijar el título**: `.navigationTitle(documentDisplayName)` en `ContentView` (funciona con
    `hiddenTitleBar`: pone el `NSWindow.title` aunque no se dibuje). Un archivo abierto → su nombre
    (`doc.documentName`); uno nuevo → «Sin título N».
  - **Numerar los nuevos**: hace falta coordinación entre ventanas (cada `WindowGroup` tiene su
    propio `ArchiveDocument`). Pequeño registro `@MainActor` que **vende** el menor número libre al
    crear un documento sin guardar y lo **devuelve** al cerrar la ventana o al pasar a tener nombre
    real (abrir/guardar). El número vive en la vista (el modelo deja `documentName` vacío, item 4 de
    la auditoría); `documentDisplayName` pasaría a «Sin título N». Decidir: reusar el menor libre
    (como TextEdit) vs. contador siempre creciente (más simple, deja huecos).
  - Esfuerzo bajo-medio, sin tocar el motor.
- [ ] **Limpieza de extracciones parciales al cancelar un lote** · análisis hecho
      2026-06-26: la cancelación (`CancelToken` en `ExportPlan.swift`) y el cierre con
      confirmación (`WindowGuard`) ya existen; cada archivo individual es atómico
      (`writeFileAtomically` en `AtomicWrite.swift` autolimpia su `.tmp`). Falta solo
      el caso de **lote** (varios elementos): los ya completados antes de cancelar
      quedan en disco sin aviso. Hacer:
  - Trackear `extractedURLs: [URL]` en `ExtractCoordinator`/documento, rellenado en
    `processNext` tras cada elemento completado con éxito.
  - Al cancelar (botón X, cerrar ventana, arrastrar a Finder), si `extractedURLs` no
    está vacío, mostrar alerta "¿Conservar los archivos ya extraídos o eliminarlos?".
  - Si elige eliminar: tarjeta flotante "Limpiando…" (reusar `progressOverlay`, nuevo
    `ProgressKind.cleaningUp`) con barra determinada por nº de archivos, que se cierra
    sola al terminar.
  - Esfuerzo bajo-medio: extiende mecanismos existentes, no requiere tocar el motor.
    Afecta integridad de datos, pero es un caso de borde (cancelar a mitad de lote).
- [ ] **UI de compresión equivalente a la de extracción** (barra + nombre de archivo +
      cancelar) · análisis hecho 2026-06-26, dividir en dos pasos:
  - **Paso 1 (bajo esfuerzo)**: para **ZIP**, que ya reporta fracción de progreso
    (`ZipWriter.writeStream`, callback `Double`), ampliar el callback a
    `(fraction, currentFile)` y generalizar `progressOverlay`/`extractionCancellable`
    → flag neutro reusado por ambas operaciones. tar/gz/xz/bz2 y libarchive (7z/iso/xar)
    siguen con spinner indeterminado por ahora.
  - **Paso 2 (esfuerzo alto, motor)**: no existe hoy cancelación de compresión —
    requiere propagar un `CancelToken` por `ArchiveDocument.writeArchive` →
    `ArchiveSaver.encode` → `ZipWriter`/escritores libarchive, con chequeos en cada
    bucle de escritura. Añadir progreso por archivo a los formatos que hoy no
    reportan nada (tar.*, libarchive) si la librería lo permite.
  - Tratar el paso 2 como ítem separado del paso 1 al planificar trabajo. Paso 1 tiene
    valor inmediato; paso 2 es caro y puede ir después.
- [ ] **Opciones de fuerza AES** (128/192) además de 256; ZipCrypto ya está. Nicho de
      seguridad — ZIP+AES-256 ya cubre el caso principal.
- [ ] **(VALORAR) Compresión multinúcleo** · **solo si el rendimiento es queja real**: hoy
      comprimimos **secuencialmente** (un escritor
      en streaming por archivo). En Apple Silicon, comprimir entradas en paralelo y ensamblar
      aceleraría ZIP/7z con muchos ficheros. **Trade-off**: choca con el modelo actual de
      streaming a un único fichero secuencial (habría que comprimir a temporales en paralelo y
      concatenar, o usar el LZMA SDK multihilo para 7z). Decidido priorizar memoria > velocidad;
      reevaluar si el rendimiento se vuelve un problema real. (revisión externa 2026-06-21)
- [ ] **Streaming en la apertura de tar comprimido** · **prioridad MUY BAJA** (casi descartado):
      abrir un `.tar.gz`/`.xz`/`.bz2` aún
      descomprime el tar entero en RAM (su `container`). Haría falta un **índice de tar
      incremental** (parsear descomprimiendo una vez, sin guardar los bytes, cubriendo
      PAX/GNU) y una extracción que **re-descomprima** saltando hasta el offset de la entrada.
      Es el único caso de streaming que falta; mayor riesgo/menor valor (navegar un tar.gz enorme).
- [ ] **Lectura de DMG** (imagen de disco de Mac) · **prioridad BAJA (opcional)**: libarchive
      no la maneja; sería vía `hdiutil` (montar/adjuntar) o parseo propio. Único formato Mac
      relevante que no leemos, pero es *scope creep* (imagen de disco, no archivo comprimido).
      Señalado en revisión externa (2026-06-21).
- [ ] **7z cifrado al escribir** · **prioridad BAJA**: libarchive no lo soporta (escribe 7z
      en claro). Haría falta el **LZMA SDK** de Igor Pavlov (cifra contenido y nombres; además
      comprime multihilo, ver "valorar" arriba) → vendorizar dependencia, rompe el principio de
      cero-deps. ZIP+AES-256 ya cubre "archivo seguro". Confirmado en revisión externa (2026-06-21).
- [ ] **Distribución** (APLAZADO — lo último de todo, por ahora no se distribuye):
      reactivar App Sandbox (paneles de guardado + security-scoped bookmarks),
      notarización, `.dmg`. Aplazado a propósito, no por bajo valor.

### Hecho (referencia, no reordenado)

- [x] ~~**Verificar interop AES-256**~~ (hecho 2026-06-20): **verificado bidireccional**
      contra `pyzipper` — ambos sentidos pasan. Test automático en `ZipCryptoTests`
      (`testPyzipperReadsOurAES256` / `testReadsAES256FromPyzipper`), que se **salta** si
      falta la librería. Reejecutar: `pip3 install pyzipper && swift test`. Si alguna vez
      fallara, revisar `ZipAES` (PBKDF2/CTR/HMAC, campo extra 0x9901, AE-2 CRC=0).
- [x] ~~tar/gz/tar.gz en Swift puro~~ (Tier 1, hecho — ver "Hecho").
- [x] ~~xz/tar.xz~~ (Tier 2, hecho — `Compression` LZMA, ver "Hecho").
- [x] ~~bzip2/tar.bz2~~ (Tier 3, hecho — `libbz2` del sistema, ver "Hecho").
- [x] ~~7z/rar~~ (Tier 4, hecho — `libarchive` del sistema SIN vendorizar, ver "Hecho").
- [x] ~~iso/cpio/xar/lha/cab~~ (hecho — misma libarchive; lectura todos, escritura iso/xar).
- [x] ~~Limpieza legacy~~ (hecho 2026-06-14): retirados `.fpkz`, librería `CryptoCore`,
      `CipherView.swift` y `ArchiveTree.swift`. El cifrado es solo ZIP estándar.
- [x] ~~**Cambiar cifrado/contraseña al re-guardar**~~ (hecho — vía **Exportar…**): botón
      "Exportar…" en la barra de documento abre la hoja de opciones (formato/cifrado/
      contraseña/volúmenes) y escribe una **copia aparte** SIN cambiar el documento activo
      (`ArchiveDocument.export` reusa `writeArchive`; no llama a `markSaved` ni muta los
      ajustes recordados, a diferencia de `save`). Test de app `testExportDoesNotChangeDocument`.
- [x] ~~**Streaming de compresión** de un único fichero enorme~~ (hecho — ver "Hecho").
      gz/xz/bz2 (de un fichero de disco), cada entrada ZIP de un fichero (cifrada o no) y
      **tar/tar.gz/tar.xz/tar.bz2** se comprimen al vuelo, con memoria constante.
- [x] ~~**Streaming de descompresión/extracción**~~ (hecho — ver "Hecho"): gz/xz/bz2 y las
      entradas ZIP (incl. ZipCrypto/AES) se extraen a disco sin materializar la salida en RAM.
- [x] ~~**Streaming en libarchive (7z/iso/xar)**~~ (hecho — ver "Hecho"): escritura desde
      ficheros de disco al vuelo y extracción a `sink`, sin acumular el contenido en RAM.
- [x] ~~Localización~~ (hecho: EN/ES vía **String Catalog**, sigue el idioma del **sistema** —
      ver "Hecho" e i18n). «Clase» y el menú ya los localiza AppKit. Pendiente menor: más idiomas
      (añadir columnas al `.xcstrings`).

## Notas de formato/cifrado (para no re-investigar)

- ZipCrypto: verificación de contraseña por byte alto del CRC, o de la **hora DOS**
  si la entrada usa descriptor de datos (bit 3) — Info-ZIP `zip` lo hace así.
- AES WinZip: método cabecera 99, campo extra **0x9901** (versión 2 = AE-2, vendor
  "AE", fuerza 1/2/3, método real). AE-2 pone CRC = 0. Datos por entrada:
  `salt | verificación(2) | cifrado | auth(10)`. CTR con contador 128-bit
  little-endian que empieza en 1. PBKDF2-HMAC-SHA1, 1000 vueltas.
- ZIP64: el lector sigue EOCD64 + locator si el EOCD de 32 bits está saturado, y
  el campo extra 0x0001 por entrada. El escritor lo emite cuando hace falta.
- ZIP en streaming (entrada `.file`): como CRC y tamaños no se conocen al escribir la
  cabecera local, se usa **descriptor de datos** (bit 3) — firma `08074b50` + CRC +
  tamaños — tras los datos, y **ZIP64 siempre** en esa entrada (sizes 0xFFFFFFFF + extra,
  descriptor de 8 bytes). El central directory lleva los valores reales (lo que lee el
  lector). Con bit 3, el byte de verificación de ZipCrypto es el de la **hora DOS**.
- TAR (ustar): bloques de 512 B; `size`/`mtime` en octal; carpetas typeflag `5`.
  `bsdtar` de macOS emite **PAX** (typeflag `x`, registros `len key=value\n`) solo
  cuando un campo no cabe en ustar (rutas largas, mtime sub-segundo) y a veces
  prefija `./`. Nombres largos GNU = typeflag `L`. El escritor emite PAX `path=`
  para rutas > 100 B. tar **no** cifra (cifrado solo en ZIP).
- gzip (RFC 1952): `1F 8B 08` + FLG + MTIME + (FNAME opcional) + DEFLATE +
  CRC32 + ISIZE(LE). `.tar.gz` = TAR envuelto en gzip; un `.gz` "suelto" se
  distingue de un tar.gz comprobando la firma `ustar` tras descomprimir.
- xz: firma `FD 37 7A 58 5A 00`. La *Compression framework* (`COMPRESSION_LZMA`)
  produce/consume `.xz` estándar. El tamaño descomprimido se lee del **Index** del
  pie (Backward Size → Index → suma de "Uncompressed Size", todo en VLI) sin
  descomprimir. `.tar.xz` = TAR + xz; `.xz` suelto vs tar.xz: firma `ustar` tras inflar.
- bzip2: firma `BZh`. `libbz2` del sistema (`-lbz2`, header en el SDK). One-shot
  `BZ2_bzBuffToBuffCompress/Decompress`; al descomprimir bzip2 NO guarda el tamaño,
  así que se reintenta con búfer ×2 si devuelve `BZ_OUTBUFF_FULL`. `.tar.bz2` = TAR + bz2.
- libarchive: la del sistema (macOS, 3.7.x) es **enlazable** (`libarchive.tbd` en el
  SDK) pero **sin cabeceras** → las declaramos en `Sources/Carchive/shim.h`. API de
  **iterador en streaming**: `archive_read_next_header` + `archive_read_data`; para
  extraer una entrada concreta se re-abre desde memoria y se itera hasta su ruta
  (no hay acceso aleatorio). 7z firma `37 7A BC AF 27 1C`. Riesgo bajo (API 3.x
  estable; Apple la actualiza). NO soportado: multivolumen nativo 7z (`.7z.001`).
- Volúmenes: división **por bytes** (no spanning PKWARE nativo). La primera parte
  conserva el nombre base (`nombre.zip`) y las siguientes llevan `_NNN` antes de la
  extensión (`nombre_001.zip`, `nombre_002.zip`…). Reconstrucción = concatenar en
  orden. Detección al abrir: si existe `nombre_001.<ext>` junto a `nombre.<ext>` es
  un juego; un `nombre_NNN.<ext>` solo cuenta como volumen si su base existe (evita
  falsos positivos tipo `backup_2024.zip`). Guardar como fichero único limpia los
  `_NNN` sobrantes (si no, se reabriría como multivolumen). NO soportado: el split
  PKWARE nativo `.z01`/.zip (cabeceras de spanning) — sería trabajo aparte.
