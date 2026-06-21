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

- **Tests del motor**: `swift test` (rápido, sin Xcode). 61 tests.
- **Tests de la app** (modelo `ArchiveDocument`): target `FilePackrTests` en Xcode,
  se corren con **⌘U** (o `xcodebuild test`). NO los recoge `swift test` (viven en el
  `.pbxproj`, no en el paquete). 5 tests.
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

## Hecho

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
- **i18n** (`Localization.swift`): `Localizer` (@MainActor, ObservableObject) con
  catálogo EN/ES en memoria y cambio de idioma **en caliente** (recordado en
  UserDefaults). **Inglés por defecto**. El selector de idioma vive en la ventana de
  **Ajustes** (⌘,). Uso: en vistas `@EnvironmentObject var loc` y `loc("clave")`/
  `loc("clave", arg)`. **El modelo ya NO usa `Localizer`** (auditoría item 4): emite
  tokens (`ProgressKind`) y las vistas traducen; los nombres por defecto (carpeta nueva,
  "Sin título") los inyecta la vista. `ArchiveOutlineView` (coordinator) sí usa
  `Localizer.shared` (es vista AppKit). Para añadir texto: nueva clave en `en`/`es`.
  Nota: los nombres de "Clase" vienen de `UTType.localizedDescription` (siguen el idioma
  del SO, no el de la app), y el **menú de la app** tampoco sigue aún el idioma interno
  (ver TODO).

## TODO (objetivos pendientes, en orden lógico)

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
- [ ] **7z cifrado al escribir**: libarchive no lo soporta; haría falta otra librería.
- [x] ~~Limpieza legacy~~ (hecho 2026-06-14): retirados `.fpkz`, librería `CryptoCore`,
      `CipherView.swift` y `ArchiveTree.swift`. El cifrado es solo ZIP estándar.
- [x] ~~**Cambiar cifrado/contraseña al re-guardar**~~ (hecho — vía **Exportar…**): botón
      "Exportar…" en la barra de documento abre la hoja de opciones (formato/cifrado/
      contraseña/volúmenes) y escribe una **copia aparte** SIN cambiar el documento activo
      (`ArchiveDocument.export` reusa `writeArchive`; no llama a `markSaved` ni muta los
      ajustes recordados, a diferencia de `save`). Test de app `testExportDoesNotChangeDocument`.
- [ ] **Opciones de fuerza AES** (128/192) además de 256; ZipCrypto ya está.
- [ ] **Streaming de compresión** de un único fichero enorme (hoy cada fichero se
      carga entero en memoria para comprimir).
- [x] ~~Localización~~ (hecho: EN/ES con selector de idioma — ver "Hecho"). Pendiente
      menor: más idiomas, y que "Clase" use el idioma de la app y no el del SO.
- [ ] **Traducir el menú de la app** (barra de menús de macOS: menú con el nombre de la
      app, Archivo, Edición…) según el idioma **interno** de la app (`Localizer`), no el
      del SO. Hoy el `WindowGroup` usa los menús por defecto y no siguen el selector de idioma.
- [ ] **Distribución** (APLAZADO — lo último de todo, por ahora no se distribuye):
      reactivar App Sandbox (paneles de guardado + security-scoped bookmarks),
      notarización, `.dmg`.

## Notas de formato/cifrado (para no re-investigar)

- ZipCrypto: verificación de contraseña por byte alto del CRC, o de la **hora DOS**
  si la entrada usa descriptor de datos (bit 3) — Info-ZIP `zip` lo hace así.
- AES WinZip: método cabecera 99, campo extra **0x9901** (versión 2 = AE-2, vendor
  "AE", fuerza 1/2/3, método real). AE-2 pone CRC = 0. Datos por entrada:
  `salt | verificación(2) | cifrado | auth(10)`. CTR con contador 128-bit
  little-endian que empieza en 1. PBKDF2-HMAC-SHA1, 1000 vueltas.
- ZIP64: el lector sigue EOCD64 + locator si el EOCD de 32 bits está saturado, y
  el campo extra 0x0001 por entrada. El escritor lo emite cuando hace falta.
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
