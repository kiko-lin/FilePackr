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
- **Remoto git**: `git@github.com:kiko-lin/FilePackr.git` (SSH). El entorno del agente
  **no tiene red** → los `git push` los hace el usuario.
- **Plataforma**: macOS 26 (Tahoe), Swift 6.3, Xcode 26. App target `FilePackr`,
  bundle `com.kiko.FilePackr`, lenguaje Swift 5 mode con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

## Cómo trabajar (importante)

- **Tests**: `swift test` (rápido, sin Xcode) corre la **suite completa**: motor
  (`ArchiveBrowserTests`) + modelo (`FilePackrModelTests`, el documento/coordinadores, en SPM
  tras la 4ª auditoría). 248 tests. Ya **no** existe el target `FilePackrTests` en el `.pbxproj`.
  - Las clases @MainActor de `FilePackrModelTests` usan `setUp`/`tearDown` **`async`** (no
    síncronos) y **no llaman a `super`**: así compilan tanto en Xcode 26 como en el XCTest del
    runner de CI (Xcode 16), donde esos métodos son `nonisolated` y enviar `self` no-Sendable da
    error. No reintroducir setUp/tearDown síncronos.
- **CI** (`.github/workflows/ci.yml`, runner `macos-15` / Xcode 16.4): dos jobs bloqueantes en
  paralelo — `test` (`swift test`, motor + modelo) y `build-app` (`xcodebuild build` sin firma,
  la capa de vistas). El scheme `FilePackr` está **compartido** (`xcshareddata/xcschemes`) para
  que el runner lo encuentre; el paquete se referencia con `relativePath = ..` (robusto ante el
  nombre de la carpeta de checkout).
  - ⚠️ **Xcode 16 ignora `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** (es de Xcode 26): en el
    runner nada es @MainActor por defecto. Por eso las clases de glue de AppKit (delegados,
    coordinadores) llevan `@MainActor` **explícito**. Si añades una clase NSObject/delegado nueva
    y solo compila en Xcode 26, anótala `@MainActor` para no romper el CI.
- **Tests de interop** (verifican compatibilidad con herramientas externas): llaman a
  un binario del sistema y se **saltan solos** (`XCTSkipUnless`) si no está, de modo que
  `swift test` siempre queda en verde sin instalar nada (exit 0; salen como *skipped*).
  - ZipCrypto: `/usr/bin/zip` y `/usr/bin/unzip` (Info-ZIP, casi siempre presentes).
  - **AES-256**: contra `pyzipper` (Python). Para activarlos: `pip3 install pyzipper`
    y reejecutar `swift test`. Patrón a seguir para futuros tests de interop: guardar
    con `XCTSkipUnless` al principio del test, nunca asumir que la herramienta está.
- **Compilar la app**: `xcodebuild -project App/FilePackr.xcodeproj -scheme FilePackr -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`.
  - El agente **no puede ejecutar la GUI** ni verificar comportamiento visual:
    solo compilar. El usuario prueba en Xcode (⌘R) y da su valoración.
  - ⚠️ **No compiles con `CODE_SIGNING_ALLOWED=NO` en el DerivedData de Xcode**:
    deja el `.app` sin firmar y al pulsar ▶ en Xcode falla con *"Unable to obtain a
    task name port right … (os/kern) failure 0x5"* (el depurador no puede
    adjuntarse: falta `get-task-allow`). Para verificación usa un DerivedData aparte:
    `xcodebuild … -derivedDataPath /tmp/fp-verify CODE_SIGNING_ALLOWED=NO build`.
    Si ya se ensució: recompila firmado (sin esa flag) o el usuario hace Clean Build
    Folder (⇧⌘K) y ▶. Firma: automática, equipo `969HQC97L9` (el de `kikolincor@gmail.com`;
    antes figuraba `J5HQ9TN2HX`, que no correspondía a la cuenta), bundle `com.kiko.FilePackr`.
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
  - **`CancellationCheck`** (`Cancellation.swift`): señal cooperativa de cancelación de la
    **compresión**. Cada escritor la consulta en sus bucles (por entrada/por trozo) y lanza
    `CancellationError`. Entra por **parámetro** donde hay bucle interno por entrada
    (`ZipWriter.write`, `LibArchive.write`) y por el **`next`** en los compresores *pull*
    (gz/xz/bz2: la envuelve la app). Desacopla el motor del `CancelToken` de la app.
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
    entrada** (`entryData`) de cada formato, y **extraer varias** (`extractAll`, un solo
    recorrido con `onSkip` opcional para reportar el tamaño de las entradas saltadas —
    solo lo usa `LibArchiveCodec`, cuyo iterador es secuencial). Antes era un `switch`
    repetido por el documento. Codecs: `ZipCodec`, `TarCodec`, `SingleFileCodec`,
    `LibArchiveCodec`. La **escritura** no va por aquí (rutas dispares: ver `ArchiveSaver`).
  - **`ArchiveContainer`** (`.data(Data)` / `.rarVolumes([URL])`): el contenedor de un
    archivo abierto, generalizado más allá de `Data` para los volúmenes RAR **nativos**
    (WinRAR/`rar`, ver `RarVolumes`) — a diferencia del esquema propio de FilePackr, esos
    no se pueden concatenar (cada volumen lleva su cabecera intercalada), así que se abren
    con `archive_read_open_filenames` de libarchive. `RAR5TrailingServiceBlock` recorta un
    bloque de servicio QuickOpen obsoleto que si no desincroniza el lector.
  - **`VolumeStore`**: volúmenes **propios** de FilePackr sobre disco (`parts`/`gather`/
    `removeContinuations`/`split(file:)` y `joinToTemporaryFile` —concatena las partes a un
    temporal mapeado sin cargarlas en RAM), sobre el esquema de nombres de `Volumes`. No
    confundir con `RarVolumes`/`ArchiveContainer.rarVolumes` (volúmenes RAR nativos, arriba).
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
    sube). Con archivo abierto: **cabecera** (nombre del archivo + 🔒/volúmenes/«sin
    guardar», y a la derecha `Extraer todo · Cerrar · Exportar · Guardar`), **columna
    vertical** de acciones de interior a la izquierda (Añadir/Crear carpeta/Eliminar/
    Extraer, icono+etiqueta), el visor (`ArchiveOutlineView`) y una **barra de estado**
    inferior (nº de ficheros + tamaño + comprimido). Estado vacío: zona de arrastre
    **clicable**. Diálogos: conflicto de extracción, contraseña (entrada/apertura),
    opciones de guardar/exportar, extraer, y el aviso unificado de cambios sin guardar.
  - `WindowGuard` (`WindowGuard.swift`): `UnsavedChangesAlert` (aviso único de «cambios
    sin guardar») + delegado de `NSWindow` para interceptar el cierre de ventana; el
    salir (⌘Q) lo cubre el `AppDelegate` (`FilePackrApp.swift`). **Sin pestañas de
    ventana** (`allowsAutomaticWindowTabbing = false`): cada archivo en su ventana.
  - `FinderServicesProvider` (`FinderServices.swift`): los **Servicios de macOS** del menú
    contextual del Finder («Abrir en FilePackr» / «Descomprimir aquí»). Declarados en
    `Info.plist` (`NSServices`), registrados por `AppDelegate`. «Descomprimir aquí» extrae sin
    UI reutilizando `ExportPlan.writeContents`. Helpers compartidos en `AppHelpers.swift`
    (`archiveBaseName`, `localizedErrorMessage`).

## Hecho

- **Sesión 2026-08-12 — el progreso ya no se congela al extraer un subconjunto de RAR/7z**
  (commit `fix(progreso)` + `docs`): bug real, no solo teórico — arrastrar al Finder o
  extraer solo un par de ficheros de un archivo grande dejaba la barra sin moverse durante
  todo el tramo en que `libarchive` tenía que **saltar** (sin extraer) las entradas no
  pedidas, porque ese salto no emitía ninguna señal de progreso aunque tenga coste real
  (recorrido secuencial, sin acceso aleatorio; peor aún en 7z sólido). Arreglo: nuevo
  callback `onSkip: ((Int64) -> Void)?` en `ArchiveCodec.extractAll`/`LibArchive.
  extractEntries`/`ExportPlan.writeContents`, que reporta el tamaño sin comprimir de cada
  entrada saltada; `ArchiveDocument.extract` y el `writePromiseTo` de `ArchiveOutlineView`
  lo suman a `done` igual que los bytes escritos. El **total** también se corrige: con
  `usesLibArchive` pasa a ser `max(plan.byteCount(), contentSize)` (antes solo contaba lo
  pedido, así que `done` podía superar `total` y la fracción se disparaba). 3 tests nuevos
  (`ArchiveCodecTests`, `LibArchiveFixtureTests`, `StreamingExtractionTests`) que fijan
  cuántos bytes se reportan como saltados. **248 verdes**. Docs: nueva sección 7 "Librerías
  externas" en `guion-presentacion.md` (qué resuelve cada dependencia del sistema y qué no)
  + mención de "Volúmenes RAR nativos" en el recorrido de funcionalidades.

- **Sesión 2026-08-09 — RAR5: bloque QuickOpen fantasma y volúmenes incompletos que
  recuperan lo ya leído** (commits `b32cc44`, `a209db3`):
  - **Entradas fantasma por un bloque QuickOpen obsoleto** (bug real, hallado con un archivo
    real): un RAR5 editado con WinRAR puede dejar en el bloque de servicio QuickOpen (al
    final del último volumen) restos de una versión **anterior** del archivo. La libarchive
    del sistema no usa ese bloque (su lector lo salta sin más), pero al saltarlo se
    **desincroniza** y reinterpreta esa caché obsoleta como si fueran entradas reales,
    sustituyendo el listado correcto por decenas de entradas fantasma. Arreglo:
    `RAR5TrailingServiceBlock` camina las cabeceras del volumen (sin descomprimir nada) para
    localizar el bloque cuando encaja exactamente con el patrón "SERVICE justo antes de
    ENDARC"; `LibArchive` lo recorta antes de abrir, tanto para un `.rar` suelto
    (`archive_read_open_memory` con la longitud recortada) como para volúmenes nativos en
    disco (nuevo `RARVolumeStream` sobre `archive_read_open2`, solo entra en juego cuando
    hace falta recortar). Verificado además contra el archivo real que reveló el bug:
    listado y extracción correctos (tamaño + SHA-256) de la entrada que cruza el límite
    entre volúmenes y de la que queda pegada al bloque recortado.
  - **Volúmenes RAR incompletos ya no pierden lo que sí se pudo leer**: `listEntries`
    devuelve `truncated` cuando el corte cae a mitad de cabecera (típico de un multivolumen
    al que le falta la última parte) en vez de lanzar y descartar todo lo leído hasta ahí.
    `ArchiveDocument` distingue "no queda ni una entrada legible" (lanza
    `rarVolumeSetIncomplete`) de "abrió parcial" (aviso persistente en naranja en la barra
    de estado, no bloqueante, para no confundirlo con texto normal).

- **Sesión 2026-08-08 — Volúmenes RAR nativos (WinRAR/`rar`) + progreso de apertura de ZIP
  a spinner** (commits `f944f69`, `099cc9d`, `206153a`, `017229b`, `b6b5a30`):
  - **Volúmenes RAR nativos**: hasta ahora FilePackr solo reconocía su **propio** esquema de
    multivolumen (`nombre_001.ext`, concatenable a pelo); un RAR multivolumen real creado
    por WinRAR/`rar` daba "No se pudo leer el archivo." porque se abría solo la primera
    parte suelta, y concatenar esos volúmenes tampoco vale — cada uno lleva su propia
    cabecera intercalada. Nuevo `RarVolumes` (detección de ambos esquemas de nombre:
    moderno `nombre.part1.rar…` y legado `nombre.rar`+`.r00…`) + `archive_read_open_filenames`
    de libarchive para abrir el conjunto real sin concatenar. El contenedor de un archivo
    abierto se generaliza de `Data` a **`ArchiveContainer`** (casos `.data`/`.rarVolumes`),
    propagado por `ArchiveReadResult`/`ArchiveCodec`/`ArchiveDocument`/`SavePayloadBuilder`/
    `ExportPlan`, así que Extraer/Extraer todo/arrastrar al Finder funcionan sobre el
    conjunto, no solo listar entradas. Fixture fabricado a mano
    (`docs/fixtures/make_rar_volumes.py`, RAR4 *storing* partido en 2 volúmenes) sin
    depender de `rar`/`unrar`. Dos hardenings inmediatos sobre lo anterior: el separador
    moderno acepta también **guion bajo** (`nombre_part1.rar`, no solo el punto — lo que
    marca el volumen es la cabecera interna, no el separador del nombre) y, si un `.rar`
    suelto declara pertenecer a un conjunto pero las demás partes no se reconocen por
    nombre (p. ej. el sufijo " (1)" que añade macOS al duplicar), el error ya no es el
    genérico "No se pudo leer el archivo." sino uno explícito de partes que faltan; de paso
    se desglosan otros motivos que compartían ese mensaje genérico (formato no reconocido,
    archivo truncado vía `archive_error_string`, entrada que faltaba al extraer un lote).
  - **Progreso al abrir un ZIP, dos iteraciones**: primero se sincronizó el reporte
    (el hilo de fondo esperaba a que cada tick se aplicara antes de seguir, porque leer el
    central directory es puro cálculo en memoria sin E/S que lo frene y los ticks se
    encolaban y drenaban de golpe al final). Pero el síntoma real era otro: la lectura que
    de verdad tarda (copiar la región del central directory a memoria) ocurre **antes** del
    bucle que reportaba progreso, así que en disco lento esa fase no reportaba nada y el
    bucle posterior (puro cálculo, <1 ms medido) disparaba todo el progreso de golpe al
    final → la barra se quedaba pillada y saltaba a terminado, pareciendo un cuelgue. Como
    esa fase no se puede subdividir en progreso útil, abrir un ZIP pasa a usar **spinner
    indeterminado**, igual que RAR/7z/tar (se retira el reporter con semáforo, ya
    innecesario). De paso, umbral de **300 ms** antes de mostrar el overlay de progreso en
    general: si la operación termina antes, la vista nunca lo construye, así que no hay
    overlay que parpadee en aperturas rápidas.

- **Sesión 2026-08-03 (c) — volúmenes en 7z: NO era un fallo (verificado en la app)**:
  el usuario informó de que «al crear un 7z dividido en lotes los lotes no se realizan, se
  comprime un único archivo». **No se ha reproducido por debajo de la interfaz**: verificado de
  extremo a extremo que 7z sí se trocea (`VolumeSplitSaveTests`, nuevo) —por la vía del modelo,
  por la de `SaveCoordinator` (la hoja real) y reabriendo el juego de partes—, y que lo mismo
  vale para zip/tar/tar.gz/xar. El troceo es **genérico y posterior** a escribir el temporal
  (`VolumeStore.split` en `writeArchive`), así que el formato no influye. Había un **hueco de
  cobertura**: `VolumesTests` probaba el troceo por bytes, pero **ningún test** guardaba un
  documento con volúmenes por formato. Hipótesis vivas para el caso del usuario: (a) **el
  ratio** — 7z comprime mucho más que zip (medido 689 B vs 9149 B con texto repetitivo), así que
  con el tamaño de volumen por defecto (**100 MB**) el mismo contenido puede partirse en zip y
  caber en una sola parte en 7z, que es lo correcto; (b) **`saveDocument` no reabre la hoja**
  cuando el documento ya tiene `sourceURL` y el formato es escribible: re-guarda en el sitio con
  los ajustes previos, así que tras un primer guardado (o al abrir un 7z existente) **no hay
  forma de activar los volúmenes desde «Guardar»** — hay que usar «Exportar».
  **Cerrado**: probado por el usuario en la app real (build de DerivedData, con dos ficheros
  de 5 MB —ruido incompresible y texto repetido— y volúmenes de 1 MB) → **funciona**. Era (a),
  el tamaño. Queda como **mejora pendiente de UX**, abajo: la app acepta «dividir en volúmenes»
  y lo ignora en silencio cuando el archivo cabe en una parte, que es indistinguible de un fallo.
  Nota de entorno: al lanzar la build de desarrollo, macOS levanta **también** la copia instalada
  en `/Applications` (mismo bundle ID) — dos ventanas iguales; cerrar una antes de probar.

- **Sesión 2026-08-03 (b) — extracción por lotes en 7z: de cuadrática a un solo recorrido**:
  hallazgo **colateral** mientras se buscaba lo anterior (el reporte del usuario iba de
  volúmenes, no de esto; se interpretó mal «por lotes»). Aun así es un fallo real y medido:
  `LibArchiveCodec` no sobreescribía `extractAll`, así que caía en el
  por-defecto del protocolo —un `extractEntry` por entrada—, y cada uno **re-abre** el
  archivo y **re-itera** desde el principio. La API de libarchive es un **iterador
  secuencial** (no acceso aleatorio, al contrario de lo que decía el comentario del
  protocolo) y 7z comprime en **bloques sólidos**: saltar hasta la entrada *k* re-descomprime
  todo lo anterior → coste **O(n²)**. Medido con un 7z de 300 entradas / 60 MB: **171,6 s**
  para «Extraer todo» frente a **1,15 s** de un solo pase. Con miles de ficheros la app
  aparenta estar colgada. Arreglo: `LibArchive.extractEntries` (un recorrido, coloca las
  entradas pedidas, salta el resto y **corta** en cuanto no queda ninguna pendiente) +
  `LibArchiveCodec.extractAll` que lo usa — la misma decisión de §10 #1 que ya tenía el tar
  comprimido. Mismo 7z tras el arreglo: **1,10 s (155×)**. Afecta a todo lo que pasa por
  `ExportPlan.writeContents`: Extraer/Extraer todo, arrastre al Finder y «Descomprimir aquí».
  Tests: recorrido único (estructural: se piden en orden inverso y llegan en orden de
  archivo) y `entryNotFound` si falta una entrada pedida. **206 verdes** (con los de volúmenes).

- **Sesión 2026-08-03 — el tema se aplica a toda la app (`NSApp.appearance`), no por ventana**:
  el usuario informó de que al cambiar a **Claro** y volver a **Según el sistema** (sistema en
  oscuro) la ventana quedaba con **fondo oscuro y texto oscuro** en la zona de arrastre, y se
  arreglaba sola al perder el foco o al cerrar Ajustes. Causa: `preferredColorScheme` en
  `ContentView`. Al volver a `nil`, AppKit devuelve la ventana a la apariencia del sistema
  (fondo ya oscuro) pero el `colorScheme` del entorno SwiftUI se queda **obsoleto** en claro
  hasta que algo fuerza un redibujado. Verificado que la vía de AppKit **sí** funcionaba:
  alternar el modo del sistema 22 veces con la app abierta no reproduce el fallo (ni crash log
  ni stderr). Arreglo: `AppTheme.colorScheme` → `AppTheme.nsAppearance`, y `AppDelegate.
  applicationWillFinishLaunching` fija `NSApp.appearance` y se suscribe a `AppSettings.$theme`
  (Combine) para mantenerlo. Se retiran los dos `preferredColorScheme` de `ContentView`.
  **Efecto extra**: el tema ahora lo siguen **todas** las ventanas (Ajustes, Ayuda, la compacta
  de «Descomprimir aquí») y las alertas/paneles del sistema; antes solo la principal.

- **Sesión 2026-07-01 (c) — asociación de archivos que se aplica de verdad en el 1er arranque**:
  el usuario informó de que, tras instalar (build ad-hoc), FilePackr no se hacía app por defecto de
  ningún tipo. Diagnóstico: el aviso de primer arranque **solo abría Ajustes** (no asociaba nada) y
  el default `associatedFormats` premarcaba casillas que **nunca** llamaban a `DefaultHandler.apply`
  (asociación fantasma). Arreglado:
  - `AppSettings.defaultAssociatedFormats` = **solo formatos editables** (`ArchiveFormat.allCases.filter(\.isWritable)`,
    i.e. todo salvo rar/cpio/lha/cab). Antes incluía `.rar` (solo lectura) y omitía varios editables.
    Decisión de alcance del usuario: reclamar solo lo que puede **crear**, no lo que solo lee.
  - **Init honesto**: instalación nueva → `associatedFormats = []` (antes = el default premarcado sin
    aplicar). Las casillas de Ajustes reflejan ahora la asociación REAL.
  - **1er arranque**: `ContentView.promptDefaultCompressorIfNeeded` → al aceptar («Usar FilePackr»)
    llama a `DefaultHandler.apply(defaultAssociatedFormats)` en el acto (como Keka), en vez de abrir
    Ajustes. Retirado el código muerto `openFilesSettings`/`@Environment(\.openSettings)`.
  - Textos `firstrun.message`/`firstrun.yes` reformulados (EN+ES). Test `DefaultAssociationTests`
    (4) fija el alcance editable-only + el init vacío. **swift test 196→200**; app compila 0/0.
  - **Nota macOS**: la asociación de un tipo con handler del sistema (zip→Utilidad de Archivo) NO es
    automática al declararse; hay que llamar a `NSWorkspace.setDefaultApplication` (lo hace
    `DefaultHandler`). Los tipos sin handler (7z/rar/…) sí se toman al registrarse. Y los Servicios
    del Finder necesitan `lsregister -f` + `pbs -update` + relanzar Finder tras instalar.
  - **Casillas de Ajustes ▸ Archivos que reflejan la REALIDAD** (no la intención): `DefaultHandler`
    gana `isDefault` (consulta `NSWorkspace.urlForApplication(toOpen:)`), `clearDefault` (desmarcar
    = reasignar el tipo a otra app que lo abra, vía `urlsForApplications(toOpen:)`; Utilidad de
    Archivo para zip/tar/gz/bz2/xz/cpio; imposible para 7z/rar/xar/lha/cab → no hay otra app) y
    `canClearDefault`. `FileFormatsSettingsView` pasa a un `@State [ArchiveFormat: Bool]` releído de
    macOS en `onAppear` y tras cada cambio (asíncrono por el aviso de consentimiento de macOS 26).
    Cierra el desajuste "casilla marcada sin aplicar" también cuando el usuario **declina** el aviso.
    `associatedFormats` queda vestigial (lo escribe el 1er arranque; la UI ya no lo lee). Texto
    `settings.files.note` reformulado (EN+ES). App compila 0/0; suite 200.

- **Sesión 2026-07-01 (b) — fixtures de formatos solo-lectura + UX de RAR cifrado** (commit
  `feat(rar)+test`): cerrado el último hueco de tests (RAR/CAB/CPIO/LHA sin cobertura por ser
  read-only sin round-trip posible).
  - **Fixtures reales versionados** (`Tests/**/Fixtures/`, generadores en `docs/fixtures/`):
    cpio (`/usr/bin/cpio -H newc`), cab/lha/rar4 fabricados a mano offline (MSCF store / cabecera
    nivel 0 `-lh0-` / RAR 4.x método 0x30), y **RAR5 reales** con `rar` 7.23 (comprimido + 2
    cifrados). `LibArchiveFixtureTests` (11 tests: list + extract por formato).
  - **Hallazgo verificado**: la libarchive del sistema **no descifra RAR** (ni RAR4 ni RAR5, ni con
    la clave correcta) — solo el `unrar` propietario. RAR sin cifrar sí se lee/extrae (incl. RAR5
    comprimido). Tests fijan la limitación. Ver `docs/fixtures/README.md` y sección Notas de formato.
  - **UX de RAR cifrado**: nuevo `ArchiveDocumentError.encryptionUnsupported(format:)`; al abrir
    (cabeceras cifradas) o extraer (solo datos) un RAR cifrado se muestra «Actualmente FilePackr no
    puede leer archivos cifrados de tipo RAR» en vez de un bucle de contraseña o un error confuso.
    `RarEncryptionTests` (3). Suite 196/0 + xcodebuild app OK.

- **Sesión 2026-06-28 — i18n al idioma del sistema + dos items de UX del TODO**:
  - **i18n idiomática** (commit `refactor(i18n)`): la app sigue el idioma del **sistema** vía
    **String Catalog** (`Localizable.xcstrings`, EN+ES); `es` en `knownRegions`. Se retiraron
    `Localizer`/`Language`/selector de idioma y el parche del menú; `loc(...)` es función global
    sobre `NSLocalizedString`. AppKit localiza gratis menú/paneles/«Clase». Ver sección i18n.
  - **Extracción "Última carpeta usada"**: nuevo `ExtractDestinationMode.lastUsedFolder` +
    `AppSettings.lastUsedExtractFolder`, fijada en `ExtractCoordinator.confirm` y usada en
    `prepareDestination`. Visible en Ajustes (informativa).
  - **Servicios del Finder** (`FinderServices.swift`, `Info.plist` `NSServices`): «Abrir en
    FilePackr» y «Descomprimir aquí» (extracción headless reutilizando `ExportPlan.writeContents`).
    Helpers `archiveBaseName`/`localizedErrorMessage` extraídos a `AppHelpers.swift`. Ver TODO
    para la verificación en GUI pendiente (registro de Servicios + títulos en inglés).
  - **Título de ventana**: `.navigationTitle(documentDisplayName)` en `ContentView`; el menú Ventana
    de macOS lista las ventanas por el nombre del archivo, o «Sin título N» (`UntitledNumbering`).
  - **Cancelación real de compresión + limpieza de extracciones parciales** (TODO 4 y 5 paso 2):
    nuevo `CancellationCheck` (motor) que cada escritor consulta en sus bucles (por entrada y por
    trozo); entra por parámetro en `ZipWriter`/`LibArchive.write` y por el `next` en gz/xz/bz2. La
    compresión es **cancelable** (overlay + cierre de ventana); al cancelar se descarta el `work`
    (destino atómico, intacto). `WindowGuard` gana la rama `writing`; `ArchiveDocument.isWriting`
    evita guardados solapados; `cleanStaleWorkFiles` barre `.work` huérfanos al abrir. La extracción
    en lote rastrea `extractedURLs` y, al cancelar con la X, ofrece **Conservar/Eliminar** (tarjeta
    «Limpiando…»). Tests: `CompressionCancellationTests` (91 del motor verdes).
  - **Progreso de compresión + "Último usado"**: la barra de compresión es determinada con nombre de
    fichero (`WriteProgress`). En Ajustes, **Formato/Cifrado/Nivel** ganan la opción **"Último usado"**
    (`AppSettings.default*` pasan a opcionales; `nil` = último usado, resuelto vía `lastUsed*`, que el
    flujo de guardar/exportar actualiza en `SaveCoordinator.confirm`). Mismo patrón que el destino de
    extracción («Última carpeta usada»). La contraseña no se recuerda.

- **Tercera auditoría (2026-06-22, rama `refactor/auditoria-2026-06-22`)** — informe en
  `docs/auditoria-2026-06-22.md`. Sin hallazgos críticos; 4 MEDIO + 4 BAJO resueltos en 5 commits:
  - **M-A**: nomenclatura neutral en el árbol (`NodeSource.zipEntry`→`.entry`, `FileNode.zipDate`→
    `entryDate`); cierra el ítem 3 a nivel de app (las entradas de cualquier formato ya eran neutrales).
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
  (compress/decompress en streaming + análisis del Index para el tamaño). Interop
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
- **Volúmenes RAR nativos** (2026-08-08, `RarVolumes.swift`): además del esquema propio de
  arriba, se **abren** (no se crean — RAR solo se lee) los multivolumen que crean WinRAR/
  `rar`: moderno `nombre.part1.rar…` (separador punto o guion bajo) y legado `nombre.rar`+
  `.r00…`. No se concatenan como el esquema propio (cada volumen lleva cabecera propia):
  se abren con `archive_read_open_filenames` vía `ArchiveContainer.rarVolumes`. Un conjunto
  al que le falta la última parte no se descarta entero (avisa, muestra lo leído).
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
  Tests del modelo (entonces en `FilePackrTests`/⌘U; **después** movidos a SPM
  `FilePackrModelTests`, los corre `swift test`). Ver sección Arquitectura.
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
  `NSApp.appearance`, ver abajo), **formato por defecto**, **cifrado por defecto** (se aplican
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
  i18n (auditoría ítem 4): emite tokens (`ProgressKind`) y las vistas traducen. **Para añadir texto**:
  nueva entrada en `Localizable.xcstrings` (Xcode) con EN+ES. **No hay selector de idioma en Ajustes.**

## TODO (objetivos pendientes, ordenados por importancia — revisión 2026-07-01)

> **Criterio de orden:** impacto en todos los usuarios × esfuerzo × riesgo de dejarlo sin hacer.
> Los items de formato/streaming de pura completitud van al final, en este orden:
> **DMG ≈ 7z-cifrado (baja) > multinúcleo (solo si el rendimiento duele)**.
> (tar-open ya HECHO 2026-06-30.)

- [x] ~~**Verificar en GUI los flujos del refactor de auditoría**~~ (HECHO 2026-06-30, verificación
      GUI por el usuario tras la 4ª auditoría + reestructuración a SPM): añadir con conflicto,
      extraer en lote con conflictos (caso «React»→«React 4», sin duplicados), guardar/exportar por
      formato, niveles de compresión y la hoja de contraseña compacta — todo correcto. **Bug hallado
      y corregido** (commit `2425e9a`): al cancelar una operación que comparte el overlay pero no es
      del `ExtractCoordinator` (arrastre al Finder / guardado), salía "Conservar/Eliminar" con rutas
      residuales de un lote anterior; ahora `processNext` limpia el estado del lote al terminar.
      Pendiente solo el `git push` (el agente no tiene red).
- [ ] **Comportamiento configurable al arrastrar un archivo al icono de la app**
      (Dock/Finder) · **APARCADO 2026-06-30 — no merece la pena por ahora.** Razones: (1) el
      caso "extraer directo" ya está cubierto por **«Descomprimir aquí» de los Servicios del
      Finder** (`FinderServices.swift`), una vía más natural (menú del propio archivo); (2)
      contradice el valor diferencial de la app (visor/gestor: ver antes de extraer); (3) añade
      preferencia persistida + Picker + rama en `handleOpen` + borde del archivo cifrado (en
      `.extract` igual hay que abrir para pedir la clave) + el `.ask` cansa; (4) no hay demanda
      real. Reconsiderar solo si en el uso diario el gesto "arrastrar al Dock para extraer" se
      vuelve frecuente y los Servicios no bastan; entonces, versión mínima `.open`/`.extract`
      (sin `.ask`). Análisis técnico original (por si se retoma): enum `FileOpenAction` en
      `AppSettings` (persistido como `extractMode`); `handleOpen()` (`ContentView`) consulta la
      preferencia; Picker en `SettingsView`; no toca `CFBundleDocumentTypes` ni `AppDelegate`.
- [ ] **Convertir un icono de la barra superior en menú con opciones rápidas**
      · **APARCADO 2026-06-30 — poco práctico para lo que aporta.** El candidato principal era
      *Exportar*, pero: Exportar es una acción **poco frecuente** (el caso común es Guardar), y un
      "Exportar a ZIP" rápido o **ahorra solo 1 clic** (si igual abre la hoja con el formato ya
      puesto) o exige **inventar una convención de destino/nombre** al saltar la hoja (cambio de
      comportamiento mayor). El candidato secundario *Extraer todo* (menú con destinos rápidos)
      tendría más sentido —ahí el destino es la decisión— pero tampoco hay demanda real.
      Reconsiderar solo si el uso lo pide. Análisis técnico original (por si se retoma): hoy son
      `Button` en un `HStack` custom (`documentBar`, `ContentView`); pasar a `Menu` de SwiftUI es
      directo y reutiliza `SaveCoordinator`/la hoja preseleccionando el formato. Esfuerzo bajo.
- [x] ~~**Limpieza de extracciones parciales al cancelar un lote**~~ (HECHO 2026-06-28, pendiente
      verificación GUI): `ExtractCoordinator` rastrea `extractedURLs` (ítems escritos con éxito;
      `Perform` ahora devuelve `Bool`); `cancelBatch`/`cancelConflict` las devuelven al cancelar.
      Si no está vacío, la vista pregunta **Conservar/Eliminar** (`cleanup.*`) y, al eliminar,
      `ArchiveDocument.cleanUpExtracted` borra en segundo plano con la tarjeta **"Limpiando…"**
      (`ProgressKind.cleaningUp`). **Alcance**: el aviso conservar/eliminar es para la **X del
      overlay** (la ventana sigue abierta); al **cerrar la ventana** se cancela y se cierra
      (los ya extraídos quedan en disco, sin prompt, para no chocar con el cierre).
- [x] ~~**UI de compresión: cancelación real + barra/nombre (TODO 5 pasos 1 y 2)**~~ (HECHO
      2026-06-28, pendiente verificación GUI): la compresión es **cancelable de verdad** y muestra
      **barra determinada + nombre de archivo** (overlay igual que la extracción).
  - **Cancelación** (paso 2): `CancellationCheck` (`Cancellation.swift`) que cada escritor consulta
    en sus bucles (por entrada y por trozo) y lanza `CancellationError`. Entra por **parámetro** en
    `ZipWriter`/`LibArchive.write` (bucle interno por entrada) y por el **`next`** en los compresores
    gz/xz/bz2 (pull, sin tocar su código; lo envuelve `SavePayloadBuilder`). `ArchiveSaver.encode` lo
    propaga; `writeArchive` crea el `CancelToken` y, al cancelar, descarta el `work` (destino atómico
    → intacto).
  - **Progreso** (paso 1): `WriteProgress` (`WriteProgress.swift`, struct) informa de los **bytes de entrada
    + fichero** desde los escritores (ZIP por entrada/intra-fichero, `Tar.reader` expone el fichero en
    curso —incluido tar—, libarchive por entrada, gz/xz/bz2 de un fichero vía el lector). `encode`
    acumula contra `total` (= `contentSize`) y emite `(fracción, fichero)` coalescido al ~1%; el
    overlay ya pinta barra+nombre sin cambios de UI. Solo la ruta en memoria (`.data`, contenido ya en
    RAM) sigue indeterminada.
  - **Cerrar mientras guarda/exporta**: `WindowGuard` gana la rama `writing` (avisa "se cancelará el
    guardado", `save.close.*`); `ArchiveDocument.isWriting` evita un segundo guardado encima.
  - **Limpieza defensiva**: `ArchiveDocument.cleanStaleWorkFiles` borra `.filepackr.work` huérfanos
    (>1 h) de la carpeta al abrir un archivo (restos de un cierre forzado anterior).
  - Tests del motor (`CompressionCancellationTests` + `WriteProgressTests`): cancelación por entrada
    y a mitad de fichero (ZIP/gz/xz/bz2/libarchive) y reporte de bytes+nombre (ZIP, tar). **93 verdes.**
- [ ] **Avisar cuando «dividir en volúmenes» no llega a dividir** · **prioridad MEDIA (UX)**:
      hoy la hoja acepta la opción y, si el archivo comprimido cabe en un volumen, escribe un
      único fichero **sin decir nada** — indistinguible de un fallo (reporte del usuario del
      2026-08-03, sesión (c)). Agravado por el defecto de **100 MB** y por lo bien que comprime
      7z. Opciones: avisar al terminar («no hizo falta dividir: 3 MB < 100 MB»), o advertir en
      la propia hoja comparando el volumen con el tamaño del contenido. El comportamiento del
      motor es correcto; esto es solo señalización.
- [ ] **Opciones de fuerza AES** (128/192) además de 256; ZipCrypto ya está. Nicho de
      seguridad — ZIP+AES-256 ya cubre el caso principal.
- [ ] **(VALORAR) Compresión multinúcleo** · **solo si el rendimiento es queja real**: hoy
      comprimimos **secuencialmente** (un escritor
      en streaming por archivo). En Apple Silicon, comprimir entradas en paralelo y ensamblar
      aceleraría ZIP/7z con muchos ficheros. **Trade-off**: choca con el modelo actual de
      streaming a un único fichero secuencial (habría que comprimir a temporales en paralelo y
      concatenar, o usar el LZMA SDK multihilo para 7z). Decidido priorizar memoria > velocidad;
      reevaluar si el rendimiento se vuelve un problema real. (revisión externa 2026-06-21)
- [x] ~~**Streaming en la apertura de tar comprimido**~~ (HECHO y mergeado a `main` 2026-06-30;
      rama `feat/streaming-tar` ya borrada; doc `docs/diseno-streaming-tar.md`). Cerrada la **única
      grieta** del principio memoria-constante del motor: abrir `.tar.gz`/`.xz`/`.bz2` ya **no**
      descomprime el tar entero en RAM. Solución implementada: **índice incremental** (`Tar.StreamIndexer`,
      parsea descomprimiendo una vez sin guardar bytes; cubre PAX/GNU y rechaza sparse) + **extracción
      por offset** (`Tar.streamExtract`) + **extracción por lotes ordenada en un solo pase**
      (`Tar.streamEntries` → `ArchiveCodec.extractAll`, usado por `ExportPlan.writeContents`, así que
      Extraer/arrastre Finder/Quick Look se benefician). El codec conserva el container **comprimido**
      mapeado e indexa al abrir; solo el acceso aleatorio repetido paga CPU (intrínseco). **Verificado
      ~154× menos RAM** (fixture .tar.gz con tar interno 1.07 GB: RSS pico 1.31 GB → 8.5 MB). Tests de
      paridad xz/bz2, cancelación a mitad de lote y fichero vacío incluidos.
- [ ] **Lectura de DMG** (imagen de disco de Mac) · **prioridad BAJA (opcional)**: libarchive
      no la maneja; sería vía `hdiutil` (montar/adjuntar) o análisis propio. Único formato Mac
      relevante que no leemos, pero es *scope creep* (imagen de disco, no archivo comprimido).
      Señalado en revisión externa (2026-06-21).
- [ ] **7z cifrado al escribir** · **prioridad BAJA**: libarchive no lo soporta (escribe 7z
      en claro). Haría falta el **LZMA SDK** de Igor Pavlov (cifra contenido y nombres; además
      comprime multihilo, ver "valorar" arriba) → vendorizar dependencia, rompe el principio de
      cero-deps. ZIP+AES-256 ya cubre "archivo seguro". Confirmado en revisión externa (2026-06-21).
- [x] ~~**CI: ampliar cobertura (tests de modelo + app)**~~ (HECHO 2026-07-01, sin esperar runner
      macOS 26: se hizo el código **portable a Xcode 16**, el del runner `macos-15`). El CI tiene
      ahora dos jobs bloqueantes: `test` = `swift test` (suite completa **motor + modelo, 248**) y
      `build-app` = `xcodebuild build` sin firma (la capa de vistas). Cómo se desbloqueó cada parte:
      (a) **`FilePackrModelTests`**: `setUp`/`tearDown` pasados a **`async`** y sin llamar a `super`
      (eliminado el mecanismo `FILEPACKR_SKIP_MODEL_TESTS`). (b) **App**: `@MainActor` explícito en las
      clases de glue de AppKit (`AppDelegate`, los dos `Coordinator`, `init` nonisolated en
      `FinderServicesProvider`), porque **Xcode 16 ignora `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**;
      + scheme compartido + ruta de paquete `relativePath = ..`. Verificado verde en el runner.
- [ ] **Branch protection en `main`** · **CONGELADO** — retomar en un momento de mayor estabilidad
      del proyecto (o cuando se trabaje con PRs). Objetivo: exigir el check verde del CI antes de
      integrar. Matiz por el que se congela: el CI corre **después** del push, así que "required
      status checks" sin PR bloquea el push directo (huevo-y-gallina) → no encaja con el flujo actual
      en solitario. Mientras tanto, la red de seguridad local es el **hook `pre-push`**
      (`.githooks/pre-push`, activado con `git config core.hooksPath .githooks`): corre `swift test`
      y aborta el push si falla (`git push --no-verify` para saltárselo). Cuando se retome: GitHub →
      Settings → Branches → regla sobre `main` → "Require status checks to pass" con los checks
      `swift test (motor + modelo)` y `build app (xcodebuild)`; con PRs si el equipo crece.
- [x] ~~**Accesibilidad / VoiceOver** (Tier 1 + 2 + 3)~~ (HECHO 2026-07-01). Tier 1 (operabilidad):
      la **zona de arrastre** del estado vacío (antes `onTapGesture`, no activable por VoiceOver) se
      expone como botón con label/pista/acción. Tier 2 (estado anunciado): **iconos de cabecera**
      (cifrado/volúmenes) ganan `accessibilityLabel` (antes solo `.help`, que VoiceOver no lee); el
      **icono de fila** del outline se marca decorativo (`setAccessibilityElement(false)`) — la columna
      «Clase» ya da el tipo. Tier 3 (progreso): la **barra** del overlay gana `accessibilityLabel` con
      la actividad ("Comprimiendo X, 45 %") y se **anuncia** el arranque/cambio de fase y el fin
      (`AccessibilityNotification.Announcement`, observando solo `kind` → sin spam; clave nueva
      `a11y.operationFinished`). **Diagnóstico**: el resto ya era accesible de base (NSOutlineView con
      NSTextField, botones con texto, NSAlert nativos, ojo de contraseña); el orden de foco de la
      cabecera ya era lineal y correcto → no se tocó. **PENDIENTE**: verificación manual con VoiceOver
      (⌘F5), la hace el usuario. Descartado por riesgo>valor: mover el foco al overlay
      (`@AccessibilityFocusState`).
- [~] **Ampliar cobertura de tests** (huecos de la evaluación 2026-07-01). **Casi todo HECHO**
      (suite 158→182); solo restan piezas que necesitan fixtures externos o son de bajo valor:
  - **Robustez ante corrupción** — ✅ HECHO lo básico (`RobustnessTests`): truncado + magic inválido
    en gz/xz/bz2, cuerpo DEFLATE alterado, no-zip y zip sin EOCD, tar truncado y con `size` corrupto
    → todos fallan limpio (0 bugs). Opcional pendiente: **ZIP no valida CRC32 al extraer** (a
    diferencia de gzip; leniencia — podría añadirse verificación) y recuperación de central directory
    parcialmente dañado.
  - **Anti-DoS** — ✅ HECHO: cota por-flujo en gzip/xz/bz2 (`DecompressionLimit`) **y** cota
    **agregada** en ZIP (`ZipReader.listEntries` rechaza total declarado desproporcionado), ambas
    con tests.
  - **Cifrado AES 128/192** — ✅ HECHO el round-trip de las tres fuerzas + wrong-password. Opcional:
    **interop** externa (pyzipper) de 128/192, no solo round-trip interno.
  - **Multivolumen** — ✅ HECHO edge cases (naming >999 con índice de 4 dígitos + round-trip, rechazo
    de no-continuación, split/join con 1667 partes y nombres únicos). Nota: la recuperación ante una
    parte ausente es de `VolumeStore` (disco), no cubierta aún.
  - **`streamEntries`** — ✅ HECHO: entradas grandes multi-trozo en un pase y saltar una grande sin
    desincronizar (confirmado 0 bugs).
  - **Formatos libarchive** — ✅ HECHO (2026-07-01): **RAR/CAB/CPIO/LHA con tests de lectura**
    (`LibArchiveFixtureTests.swift`, 11 tests: list + extract por formato). Fixtures en
    `Tests/ArchiveBrowserTests/Fixtures/`. Almacenados (sin compresión), fabricados **offline**: cpio
    con `/usr/bin/cpio -H newc`; cab/lha/rar4 a mano (scripts en `docs/fixtures/`, MSCF store /
    cabecera nivel 0 `-lh0-` / RAR 4.x método 0x30). **RAR5 reales** generados con `rar` 7.23:
    `comp-rar5.rar` (comprimido sin cifrar — libarchive lo descomprime de verdad, verificado) y dos
    cifrados (`enc-rar5-headers`/`enc-rar5-data`, clave real "clave123").
  - **⚠️ LIMITACIÓN VERIFICADA (2026-07-01): la libarchive del sistema NO descifra RAR** (ni RAR4 ni
    RAR5), solo el `unrar` propietario. Empírico: un RAR5 cifrado con la clave **correcta** sigue
    dando error (`passphraseRequired`/`wrongPassword`); `unrar` con la misma clave sí extrae. Además,
    en RAR5 con solo datos cifrados libarchive **ni marca** las entradas como cifradas (`isEncrypted
    = false`) → la app no pediría clave. Tests `testRar5Encrypted*NotDecryptable/NotExtractable` fijan
    esta conducta (saltarán si un macOS futuro añade descifrado RAR). RAR **sin cifrar** sí se lee y
    extrae (incl. RAR5 comprimido). Ver `docs/fixtures/README.md`.
  - **UX de RAR cifrado — ✅ RESUELTO (2026-07-01)**: nuevo `ArchiveDocumentError.encryptionUnsupported(format:)`.
    Caso A (cabeceras cifradas): `openArchive` lo lanza al detectar `.passphraseRequired` en un `.rar`
    (antes → bucle de contraseña con la clave correcta rechazada). Caso B (solo datos cifrados,
    indetectable al abrir porque libarchive no marca cifrado): `performExtraction` mapea el
    `wrongPassword`/`passphraseRequired` de un RAR a ese error (antes → "contraseña incorrecta"
    confuso). La vista lo traduce a `error.encryptionUnsupported` (clave nueva EN+ES en
    `Localizable.xcstrings`, con `%@` = acrónimo del formato): «Actualmente FilePackr no puede leer
    archivos cifrados de tipo RAR.» Tests: `Tests/FilePackrModelTests/RarEncryptionTests.swift`
    (3: abrir cabeceras, extraer datos, y control RAR sin cifrar intacto).
- [~] **Distribución directa (Developer ID + notarización)** — **INFRAESTRUCTURA HECHA
      2026-07-01, falta el paso con cuenta de desarrollador** (lo hace el usuario). Canal
      elegido: **directa fuera de la App Store** (la GPL-3.0 es incompatible en la práctica
      con la Store, y así no hay que reactivar sandbox + security-scoped bookmarks). Hecho en
      el repo: **`LICENSE` GPL-3.0** (copyright Francisco Javier Linares); **Hardened Runtime
      activado** (`ENABLE_HARDENED_RUNTIME = YES` en Debug y Release del pbxproj) — verificado
      `BUILD SUCCEEDED` en Release; **copyright** en el «Acerca de»
      (`INFOPLIST_KEY_NSHumanReadableCopyright`); **sin `.entitlements`** (la app no lo necesita:
      no subprocesos/`dlopen`/JIT, solo enlaza libs del sistema); **pipeline de release**
      (`scripts/release.sh` + `scripts/ExportOptions.plist`, método `developer-id`): archive →
      export firmado → notarizar app → grapar → `.dmg` → notarizar dmg → grapar → validar con
      `spctl`. Guía completa en `docs/distribution.md`. **PENDIENTE (usuario, requiere Apple
      Developer Program):** (1) certificado *Developer ID Application* en el llavero;
      (2) `xcrun notarytool store-credentials "FilePackr" …` con contraseña específica de app;
      (3) `scripts/release.sh` (modo notarizado); (4) prueba en frío del `.dmg`. App Sandbox
      sigue **OFF** a propósito (solo haría falta para la App Store).
      **Vía GRATUITA añadida (2026-07-01)**: `scripts/release.sh --unsigned` genera un `.dmg`
      con firma **ad-hoc** (sin certificado ni cuenta de pago), verificado aquí (BUILD SUCCEEDED
      + `.dmg` de 4,4 MB, app `valid on disk`); el usuario final lo autoriza con «Abrir
      igualmente» / `xattr -d com.apple.quarantine`. Instrucciones en `docs/distribution.md`.
      **Team ID corregido**: el real de `kikolincor@gmail.com` es **`969HQC97L9`** (no
      `J5HQ9TN2HX`, que daba 403 en notarytool); actualizado en pbxproj + ExportOptions. Falta
      confirmar si esa cuenta está en el **programa de pago** (si no, solo la vía `--unsigned`).
      **Publicado en GitHub Releases (2026-08-14)**: el tag `v1.0` original (y un `v1.1` suelto)
      apuntaban a commits desincronizados entre local y remoto, y la release `v1.0` que existía
      en GitHub estaba **vacía (sin `.dmg` adjunto)** — de ahí que no se encontrara la descarga.
      Se borraron esa release y ambos tags, se reconstruyó el `.dmg --unsigned` desde `main`
      (HEAD actual), y se republicó `v1.0` con el `.dmg` adjunto y el SHA-256 corregido en
      `docs/release-notes-v1.0.md`. Sigue pendiente la vía notarizada (arriba).

> Lo ya realizado vive en la sección **Hecho** (arriba) y en el historial de git; aquí solo
> quedan objetivos **pendientes**.

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
  **RAR cifrado NO soportado** (verificado 2026-07-01): libarchive lee/descomprime RAR4/RAR5
  **sin cifrar**, pero **no descifra** RAR con contraseña —ni con la clave correcta— porque no
  incorpora el `unrar` propietario de RARLAB. Sí descifra ZIP (ZipCrypto/AES) y 7z. En RAR5 con
  solo datos cifrados libarchive ni siquiera indica `isEncrypted`. Ver `docs/fixtures/README.md`.
  **Volúmenes RAR nativos SÍ soportados** (2026-08-08): además del esquema propio de FilePackr
  (`Volumes`/`VolumeStore`, división por bytes concatenable), se reconocen los volúmenes que
  crean WinRAR/`rar` — `RarVolumes.parts(for:)` detecta el esquema moderno
  (`nombre.part1.rar…`, separador punto **o** guion bajo) y el legado (`nombre.rar`+`.r00…`).
  A diferencia del esquema propio, estos **no** se concatenan (cada volumen lleva su propia
  cabecera intercalada): se abren con `archive_read_open_filenames`, expuesto como el caso
  `.rarVolumes` de `ArchiveContainer` (junto a `.data`). Un conjunto incompleto (falta la
  última parte) no se descarta entero: `listEntries` devuelve lo leído hasta el corte
  (`truncated`) y la app avisa en vez de fingir que está completo. **Bug real hallado y
  corregido** (2026-08-09): un volumen RAR5 editado por WinRAR puede dejar en el bloque de
  servicio QuickOpen (final del último volumen) restos de una versión anterior del archivo;
  libarchive lo salta pero se desincroniza y lo reinterpreta como entradas reales
  (fantasma). `RAR5TrailingServiceBlock` localiza y recorta ese bloque antes de abrir. Sigue
  **NO soportado**: multivolumen nativo de **7z** (`.7z.001`).
- Volúmenes: división **por bytes** (no spanning PKWARE nativo). La primera parte
  conserva el nombre base (`nombre.zip`) y las siguientes llevan `_NNN` antes de la
  extensión (`nombre_001.zip`, `nombre_002.zip`…). Reconstrucción = concatenar en
  orden. Detección al abrir: si existe `nombre_001.<ext>` junto a `nombre.<ext>` es
  un juego; un `nombre_NNN.<ext>` solo cuenta como volumen si su base existe (evita
  falsos positivos tipo `backup_2024.zip`). Guardar como fichero único limpia los
  `_NNN` sobrantes (si no, se reabriría como multivolumen). NO soportado: el split
  PKWARE nativo `.z01`/.zip (cabeceras de spanning) — sería trabajo aparte.
