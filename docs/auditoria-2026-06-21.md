# Auditoría de arquitectura — FilePackr

**Fecha:** 2026-06-21 · **Alcance:** todo el código fuente (motor `FilePackrCore` + app)
· **Método:** lectura del 100% de los `.swift`, dos análisis paralelos (motor / app) y
verificación manual de los hallazgos concretos. No se modificó ningún fichero.

> Auditoría de seguimiento. La auditoría anterior (2026-06-20, items 1–7) está cerrada;
> esta evalúa el estado tras la rama `feat/streaming-compresion` (sesiones 21-jun a–e).

---

## 1. Veredicto general

El proyecto está **bien diseñado y maduro** para su tamaño (~6.100 LOC de producción +
1.350 de tests). La línea motor/UI es estricta y se respeta; las abstracciones clave
(`ArchiveCodec`, `ArchiveEntry` neutral, `ArchiveSaver`/`SavePayload`) cumplen su función;
el streaming de memoria constante está implementado de verdad y bien razonado; y las
afirmaciones del `AGENTS.md` sobre unificación de cripto y compresión se **verifican como
ciertas** (no queda duplicación significativa en esa capa).

La deuda abierta es **localizada y de severidad media-baja**. Dos ejes principales:

1. **Modularidad de la capa app** — dos *god objects* (`ArchiveDocument` 929 LOC y
   `ContentView` 902 LOC) que reclaman extracción. El documento volvió a crecer (718→929)
   por la maquinaria de ensamblado de payloads de guardado.
2. **Corrección en rutas extremas del motor** — un bug de precedencia real (gzip), copias
   completas en RAM donde podría haber streaming, y una asignación no acotada (zip-bomb).

No hay hallazgos **críticos**: sin `try!`/`as!`/force-unwraps en rutas alcanzables, sin
`fatalError` accesible por el usuario, sin data races detectadas.

| Métrica | Valor |
|---|---|
| LOC producción | 2.703 (motor) + 3.374 (app) |
| LOC tests | 1.350 (61 motor + 5 app) |
| Ficheros > 500 LOC | 4 (`ArchiveDocument` 929, `ContentView` 902, `ArchiveOutlineView` 575, `ZipWriter` 488) |
| TODO/FIXME en código | 0 (los pendientes viven en `AGENTS.md`) |

---

## 2. Hallazgos prioritarios

### ALTO

**H-1 · `ArchiveDocument` reacumula responsabilidades (929 LOC).**
`ArchiveDocument.swift`. El delta 718→929 es el ensamblado de payloads por formato:
`makeSavePayload` (switch de 13 ramas, `576-625`), `makeTarItems` (`647`),
`makeLibArchiveItems` (`670`), `makeSaveInputs` (`694`), `singleFilePayload` (`630`).
Es código puro de serialización árbol→estructuras `Sendable`, sin estado de UI.
**Recomendación:** extraer un `SavePayloadBuilder` (o extensión `ArchiveDocument+SaveInputs.swift`)
que reciba `roots`/`sourceData`/`password`/`format` y produzca el `SavePayload`. Baja el
documento ~200 LOC y replica el patrón ya exitoso de `ArchiveSaver` (separó el *cómo*; falta
separar el *qué* ensamblar).

**H-2 · `ContentView` concentra toda la coordinación (902 LOC, 34 `@State`).**
`ContentView.swift:215-249` declara 34 `@State`; el `body` arrastra 4 `.sheet`, 2
`.confirmationDialog`, 1 `.alert` y 2 `.onChange`, más tres máquinas de cola (añadir,
extraer, guardar-tras-acción). **Recomendación:** (a) mover las hojas privadas
(`SaveOptionsSheet`/`ExtractOptionsSheet`/`PasswordSheet`, `45-207`, ~160 LOC) a ficheros
propios; (b) encapsular las colas en coordinadores `@Observable` (`AddCoordinator`,
`ExtractCoordinator`) que absorban sus ~10 `@State` y los `processNext*`.

### MEDIO

**M-1 · Bug de precedencia en el análisis de FEXTRA de gzip. _(verificado)_**
`Gzip.swift:126`: `p += 2 + Int(bytes[p]) | (Int(bytes[p+1]) << 8)`. En Swift `|` tiene
`AdditionPrecedence` (igual que `+`), así que esto es `(2+low) | (high<<8)` — incorrecto.
La versión correcta, con paréntesis, está en la misma clase justo arriba (`:89`). Solo
afecta a `storedFilename` (nombre mostrado de un `.gz`) y solo si FEXTRA mide >255 B.
**Fix:** copiar los paréntesis de `:89`.

**M-2 · Tres `walk(_:prefix:)` casi calcados.** `ArchiveDocument.swift:647-727`.
`makeTarItems`/`makeLibArchiveItems`/`makeSaveInputs` repiten el recorrido del árbol
(carpeta / `.diskFile` / `.zipEntry`); solo varía el tipo de ítem destino. Riesgo: un fix
aplicado a uno y no a los otros. **Fix:** un `walk` genérico parametrizado por una closure
`(node, path) -> Item?`, o un recorrido a representación intermedia neutra.

**M-3 · Patrón "temporal + reemplazo atómico" triplicado.**
`ArchiveSaver.swift:48-94` (`streamZip`, `streamToFile`) y `ExportPlan.swift:55-71`. El
idioma «escribir a `.tmp` → cerrar → mover sobre destino → borrar en `catch`» aparece 3
veces. **Fix:** helper compartido `writeAtomically(to:_ body:)`.

**M-4 · Estado de cifrado disperso en ~8 flags booleanos.**
`ArchiveDocument.swift:36-39` (`requiresEntryPassword`/`requiresOpenPassword`/`isLocked`) +
vista (`showingEntryPassword`/`showingOpenPassword`/`entryPasswordWrong`/`openPasswordWrong`/
`pendingEditAction`). Es una máquina de estados implícita. **Fix:** `enum LockState { unlocked,
needsOpenPassword(URL), needsEntryPassword }` hace imposible el estado contradictorio y
simplifica los dos `.onChange` de `ContentView.swift:373-382`.

**M-5 · `handleIncoming` es código muerto. _(verificado: 0 llamadores)_**
`ArchiveDocument.swift:110-120`. La vista reimplementa la decisión abrir-vs-añadir con
`archiveToOpen`+`addTargetFolder` (`ContentView.swift:645-651`). **Fix:** borrarlo, o mejor
que la vista lo use en lugar de duplicar la lógica.

**M-6 · Doc-comment de `ZipReader` falso. _(verificado)_**
`ZipReader.swift:14-17` afirma «sin ZIP64, sin cifrado de entradas… en producción se
sustituye por libarchive». El propio fichero implementa ZIP64 (`:47-100`) y lee metadatos
AES (`:105-146`), y libarchive coexiste (no sustituye). **Fix:** reescribir el comentario.

**M-7 · Asignación no acotada al descomprimir (zip-bomb por declaración).**
`Deflate.swift:32`: `Data(count: uncompressedSize)` con un tamaño tomado del *central
directory* (controlado por el fichero de entrada). Un ZIP malicioso con tamaño declarado
enorme fuerza una asignación gigante. Relevante porque el motor abre archivos no confiables.
**Fix:** acotar o crecer el buffer incrementalmente.

**M-8 · Copias completas a `[UInt8]` del contenedor.**
`Tar.swift:16` (`[UInt8](data)` del TAR entero) y `ZipReader.swift:38,59`. Para un tar.gz de
varios GB ya descomprimido en RAM, materializar `[UInt8]` duplica el pico. **Fix:** indexar
sobre `Data` con offsets (como ya hace `Gzip.decompress` con slices sin copia).

**M-9 · `WindowSaveHandlers` no purga ventanas cerradas.**
`WindowGuard.swift:43-89`. El diccionario global `[ObjectIdentifier: closure]` retiene la
entrada de cada ventana indefinidamente (fuga lenta y acotada; la closure es `[weak self]`).
**Fix:** en `windowWillClose`/`forceClose`, `WindowSaveHandlers.handlers[id] = nil`.

### BAJO (selección)

- **B-1 · Rendimiento cripto byte a byte.** `ZipAES.swift:100-112` (`CTRKeystream.xor`) y
  `ZipCrypto.swift:34-51` operan byte a byte con `[UInt8]`/`Data` por trozo; cada chunk de 64 KB
  hace ~3 copias. Es la ruta caliente más cara. Optimización: XOR sobre buffer preasignado con
  `withUnsafeBytes`. _(impacto real solo en ficheros cifrados grandes)_
- **B-2 · `preconditionFailure` frágil.** `ZipWriter.swift:295` aborta si `makeRecord` recibe
  `.file`; hoy inalcanzable pero por invariante implícito. Convertir en `throws`.
- **B-3 · Progreso de extracción sin throttle.** `ArchiveDocument.swift:449` emite un
  `Task { @MainActor }` por fichero; la apertura ya coalesce a ~1% (`:152-156`). Aplicar el
  mismo throttling en `runExtraction`.
- **B-4 · gzip `ISIZE` truncado >4 GB.** `Gzip.swift:31,106` — conforme al RFC 1952 (mód 2³²)
  pero la comprobación de tamaño pierde valor; el CRC sigue protegiendo. Documentar como intencional.
- **B-5 · Errores mostrados en crudo.** `ContentView.swift:890,894` interpola el `Error` sin
  localizar (app bilingüe). Mapear errores conocidos a mensajes ES/EN.
- **B-6 · Helpers de nombre único triplicados** (`ArchiveDocument.swift:79-91,455-468,843-849`),
  **paneles `NSOpenPanel`/`NSSavePanel` repetidos** (`ContentView`/`SettingsView`), **`MARK`
  huérfano** (`ContentView.swift:614-616`), **`Coordinator` usa `Localizer.shared`** directamente
  (`ArchiveOutlineView.swift`, aceptable), **fallback `/dev/null` silencioso** en Quick Look
  (`ArchiveOutlineView.swift:569`), **clasificación de error de libarchive por substring**
  (`LibArchive.swift:195-201`, frágil ante cambios de versión/locale).

---

## 3. Lo que está bien resuelto (no tocar)

**Motor:**
- `ArchiveCodec` — registro formato→codec limpio; añadir formato = un `case`.
- `CompressionStream` centraliza el bucle de `compression_stream` (memoria constante,
  compartido gzip/xz).
- Streaming real de extremo a extremo: `Tar.reader` (generador pull encadenable),
  `ZipWriter.emitStreamedFile` (deflate+cifrado al vuelo con descriptor de datos + ZIP64),
  `ZipExtractor.extract` (descifra+infla a sink, MAC AES validado al final).
- **Unificación cripto confirmada**: `CTRKeystream`/`keystreamBlock` compartidos;
  `ZipAES.encrypt` es un adaptador fino de `Encryptor`. Sin duplicación cripto.
- `ArchiveEntry` neutral con `zip: ZipEntryInfo?` — buena decisión de modelado.
- `unsafe`: `allocate`+`defer deallocate` y `withUnsafeBytes` correctamente emparejados;
  punteros C locales a cada llamada. Sin fugas detectadas.
- `ZipWriter` (488 LOC) **no es un god type**: bien seccionado (núcleo/streaming/registro/
  cabeceras), responsabilidad única por método.

**App:**
- Desacople de localización modelo/vista **se mantiene limpio** (ítem 4 previo): el modelo
  emite tokens `ProgressKind`, la vista traduce. `AppSettings`/`Localizer` no aparecen en el modelo.
- Concurrencia sólida: `@MainActor` ensambla `Sendable`, `Task.detached` hace el trabajo
  pesado, progreso vuelve al main sin capturar `self`. Sin races.
- Sin force-unwraps/`try!`/`fatalError` en toda la capa.
- `WindowGuard` puentea `windowShouldClose` con `forwardingTarget` de forma idiomática.
- Colas `processNext*` correctas (consumo + reanudación + limpieza en cancelación).
- Guardas `lastRevision`/`lastLanguage` del Coordinator evitan recargas de más.
- `docs/architecture.md` y `docs/encryption.md` están **al día** y son precisos.

---

## 4. Backlog priorizado

| # | Sev. | Acción | Ubicación | Esfuerzo |
|---|------|--------|-----------|----------|
| H-1 | ALTO | Extraer `SavePayloadBuilder` de `ArchiveDocument` | `ArchiveDocument.swift:496-727` | M |
| H-2 | ALTO | Sacar hojas + coordinadores de cola de `ContentView` | `ContentView.swift:45-207,215-249` | M |
| M-1 | MEDIO | Fix precedencia gzip FEXTRA | `Gzip.swift:126` | XS |
| M-5 | MEDIO | Borrar/usar `handleIncoming` | `ArchiveDocument.swift:110` | XS |
| M-6 | MEDIO | Reescribir doc-comment `ZipReader` | `ZipReader.swift:14-17` | XS |
| M-2 | MEDIO | Unificar los tres `walk` | `ArchiveDocument.swift:647-727` | S |
| M-3 | MEDIO | Helper `writeAtomically` | `ArchiveSaver.swift`,`ExportPlan.swift` | S |
| M-4 | MEDIO | `enum LockState` para cifrado | `ArchiveDocument.swift:36` + vista | S |
| M-7 | MEDIO | Acotar asignación de descompresión | `Deflate.swift:32` | S |
| M-8 | MEDIO | Evitar `[UInt8]` del contenedor completo | `Tar.swift:16` | S |
| M-9 | MEDIO | Purgar `WindowSaveHandlers` al cerrar | `WindowGuard.swift` | XS |
| B-* | BAJO | Cripto byte a byte, throttle progreso, errores localizados, paneles/nombres duplicados, etc. | varios | — |

**Quick wins** (XS, alto valor/esfuerzo): M-1, M-5, M-6, M-9.
**Refactor estructural** (el grueso de la deuda): H-1 y H-2.
