# Diseño — Streaming en la apertura de tar comprimido

> Documento de **planificación** (no de implementación). Base para el plan de diseño de la
> rama `feat/streaming-tar`. Objetivo: que abrir/extraer `.tar.gz`/`.tar.xz`/`.tar.bz2` deje de
> cargar el tar descomprimido **entero en RAM**, sin sacrificar el acceso a entradas.

## 1. Por qué

El motor es **memoria-constante** en todo (compresión y extracción en streaming, ZIP mapeado).
La **única excepción** es abrir un tar comprimido: hoy descomprime el tar completo a RAM. Para
una app de distribución general (no sabemos el tamaño de los archivos del usuario), eso es:

- **RAM** ∝ tamaño descomprimido (un `.tar.gz` de 5 GB → 5 GB en RAM; varios a la vez, peor).
- Una **inconsistencia** con el principio de diseño del resto del motor.

Las dos alternativas "baratas" se descartaron por no optimizar recursos:
- *Tar entero en RAM* (actual): gasta RAM siempre, incluso para solo listar.
- *Tar entero en disco temporal mapeado*: gasta disco/E-S siempre, incluso para solo listar.

## 2. El compromiso intrínseco (a tener presente)

gzip/xz/bz2 **no tienen acceso aleatorio**: para llegar al byte N hay que descomprimir 0…N.
Por tanto, para acceso aleatorio a un tar comprimido solo hay tres palancas — **guardar**
(RAM/disco), **re-descomprimir** (CPU) o limitar el patrón de acceso. No existe una vía que
optimice las tres a la vez. La estrategia elegida minimiza RAM y disco a cambio de CPU en el
acceso aleatorio **repetido**, y evita ese coste en los flujos comunes con un diseño cuidadoso.

## 3. Estado actual (código)

| Pieza | Hoy |
|------|-----|
| `TarCodec.open` ([ArchiveCodec.swift:114](../Sources/ArchiveBrowser/ArchiveCodec.swift)) | `decompress(data)` → **tar entero en RAM** (`container`) + `Tar.listEntries` |
| `SingleFileCodec.open` ([ArchiveCodec.swift:135](../Sources/ArchiveBrowser/ArchiveCodec.swift)) | *peek* de 263 B en streaming para detectar `ustar` (ya optimizado); si es tar → `decompress` entero a RAM |
| `Tar.listEntries` ([Tar.swift:17](../Sources/ArchiveBrowser/Tar.swift)) | parsea cabeceras de 512 B sobre el `Data`; registra `dataOffset` por entrada; cubre **ustar + PAX (`x`/`g`) + GNU `L`** |
| `Tar.entryData` ([Tar.swift:77](../Sources/ArchiveBrowser/Tar.swift)) | `subdata` desde `dataOffset` (acceso aleatorio barato: el tar ya está descomprimido en RAM) |
| `ArchiveReadResult.container` | lo conserva el documento como `sourceArchiveData`; de él se extraen las entradas |

**Piezas reutilizables que ya existen:**
- `Gzip/Xz/Bzip2.decompress(_:sink:)` — descompresión en **streaming** por trozos.
- `CompressionStream` — bucle común de descompresión pull/push.
- `Tar.reader` — generador **pull** (para escritura; muestra el patrón a replicar en lectura).
- `ArchiveEntry.dataOffset` — ya existe el concepto de offset de datos.

## 4. Decisión de diseño

**Streaming real con índice de offsets + re-descompresión bajo demanda.** El `container` que se
conserva pasa a ser los **bytes comprimidos originales** (el `.tar.gz`, que ya llega mapeado con
`mappedIfSafe` → poca RAM), no el tar descomprimido.

Tres operaciones:

1. **Indexar (al abrir):** descomprimir en streaming y parsear el tar **al vuelo**, sin guardar
   los bytes de contenido. Por entrada se registra: `path`, `size`, `mtime`, `isDirectory` y el
   **offset lógico** (posición de inicio de sus datos en el flujo *descomprimido*). RAM = solo el
   índice (metadatos), no el contenido.
2. **Extraer una entrada:** re-descomprimir desde el inicio, **descartar** hasta el offset de la
   entrada, emitir sus `size` bytes por el `sink`. Coste: CPU de descomprimir hasta ahí.
3. **Extraer todo / un lote:** ordenar las entradas por offset y hacer **un solo pase** de
   descompresión, soltando cada entrada a su destino conforme se cruza su offset. Evita
   re-descomprimir N veces — clave para que el flujo común sea óptimo.

### Coste por flujo (objetivo)
| Flujo | RAM | Disco extra | CPU |
|------|-----|-------------|-----|
| Listar al abrir | índice (pequeño) | 0 | 1 pase |
| Extraer todo | mínima | solo el resultado | 1 pase |
| Extraer un lote (N entradas) | mínima | solo el resultado | 1 pase (ordenado por offset) |
| Quick Look / 1 entrada suelta | mínima | 0 | descomprimir hasta su offset |

## 5. Esbozo de API (a refinar en el plan)

- **`TarIndex`** (nuevo): resultado de indexar — `[ArchiveEntry]` con `dataOffset` = offset lógico
  en el flujo descomprimido. Reutiliza `ArchiveEntry` (semántica de `dataOffset` pasa de "offset en
  RAM" a "offset lógico en el stream"; documentar el cambio).
- **`Tar.index(stream:)`** (nuevo): variante incremental de `listEntries` que consume un generador
  pull de bytes descomprimidos y un **lector de bloques de 512 B** sobre ese stream (las cabeceras
  pueden cruzar fronteras de chunk del descompresor → hace falta un buffer).
- **`TarCodec`/`SingleFileCodec`**: `open` indexa (sin materializar) y devuelve `container` = bytes
  **comprimidos**. `extract(entry, sink)` re-descomprime + salta + emite.
- **Extracción por lotes:** decidir dónde vive el "un solo pase" — el reto es que hoy la extracción
  va por `ExportPlan` nodo a nodo ([ExportPlan.writeContents](../App/FilePackr/ExportPlan.swift), en
  `FilePackrModel`). Opciones: (a) un `extract(entries:sink:)` batch en el codec que el plan use para
  tar; (b) que el `ExportPlan` de un tar agrupe y haga el pase. **Cruza capas motor↔modelo → decisión
  central del plan.**

## 6. Retos y riesgos

- **Lector de bloques sobre el stream:** las cabeceras de 512 B y el padding cruzan los chunks del
  descompresor → buffer de relleno. Hoy `listEntries` lo evita porque tiene todo en RAM.
- **PAX (`x`/`g`) y GNU `L`:** ocupan bloques propios *antes* de la entrada real; el indexador debe
  consumirlos del stream en orden (hoy ya se parsean, pero sobre RAM con índices absolutos).
- **Tar sparse (GNU):** caso exótico; decidir si se soporta o se documenta como no soportado.
- **Acceso aleatorio repetido** (Quick Look navegando entrada por entrada en un tar.gz enorme):
  re-descompresión cada vez. Mitigaciones a valorar: caché LRU de la última entrada, o un punto de
  re-arranque. Probablemente *no* en la primera versión (documentar el coste).
- **Coherencia del `container`:** hoy `sourceArchiveData` se asume "lo que se extrae"; pasa a ser los
  bytes comprimidos. Verificar todos los consumidores (`ExportPlan.payload = .archiveEntry(...)`).
- **Regresión de rendimiento** en el patrón "abrir y extraer varias sueltas": medir frente al actual.

## 7. Plan por fases (incremental, cada una verificable con `swift test`)

1. ✅ **HECHO** — **Indexador incremental** `Tar.StreamIndexer` (push: `consume`/`finish`, encaja
   con `decompress(_:sink:)`); descarta el contenido a medida que llega. Tests `TarStreamTests`:
   paridad con `listEntries` en todos los troceados de chunk (1, 7, 513… bytes), cubriendo PAX,
   carpetas, ficheros vacíos y multi-bloque; los offsets localizan el contenido correcto. No toca
   el codec todavía. (Pendiente de optimizar: el buffer hace `Data(buffer)` tras cada `removeFirst`
   para re-basar índices — correcto pero copia; mejorar con un índice de lectura en la fase de pulido.)
2. ✅ **HECHO** — **Extracción por offset** `Tar.streamExtract(offset:length:decompressing:with:sink:)`:
   re-descomprime, descarta hasta el offset, emite los `length` bytes y **corta** la descompresión
   (no infla el resto). Tests: round-trip sobre un `.tar.gz` real == `Tar.entryData` para todas las
   entradas, y exactitud con una entrada grande no alineada a 512. Sigue sin tocar el codec.
3. Dividida en 3a (motor) y 3b (cableado):
   - 3a. ✅ **HECHO** — **Iterador del motor** `Tar.streamEntries(decompressing:with:selecting:)`:
     recorre el tar comprimido en **un solo pase** y, por cada entrada, el llamador devuelve un
     sink (emitir su cuerpo en streaming) o `nil` (saltarla). Se generalizó `StreamIndexer` para
     soportarlo (indexar = recorrer descartando; mismo núcleo, sin duplicar la máquina de análisis).
     Tests: extraer-todo en un pase == `entryData` por entrada; saltar selectivo en un pase. La
     paridad de Fase 1 sigue verde (el refactor no rompió nada).
   - 3b. ⏳ **PENDIENTE — cableado del codec:** `TarCodec`/`SingleFileCodec` conservan el container
     **comprimido** y usan índice (`StreamIndexer`) al abrir + `streamExtract`/`streamEntries` al
     extraer; ajustar `ArchiveReadResult`. Toca aguas arriba → ejecutar toda la suite.
4. **Extracción por lotes ordenada** (un pase) + integración con `ExportPlan`/extraer-todo.
5. **Verificación de memoria**: medir que abrir+listar un tar.gz grande ya no escala la RAM.

## 8. Plan de tests (exhaustivo — es donde rompe un tar exótico)

- Paridad indexador vs `listEntries` sobre fixtures: ustar simple, **PAX** (rutas/size/mtime
  largos), **GNU `L`** (nombre largo), carpetas, ficheros vacíos, múltiples entradas.
- Round-trip de extracción por offset == `entryData` actual, para cada tipo anterior.
- Extracción por lotes: orden arbitrario de selección → un pase → contenidos correctos.
- Bordes: tar vacío (dos bloques cero), cabecera a caballo entre dos chunks del descompresor,
  entrada cuyo `size` no es múltiplo de 512 (padding).
- Interop (opcional, se salta si no está la herramienta): comparar con `tar tzf`/`tar xzf` del
  sistema sobre los fixtures.
- Memoria: test/medición de que indexar no retiene el contenido (RSS acotado).

## 9. Criterios de aceptación

- Abrir y listar un `.tar.gz` no carga el contenido en RAM (RAM ∝ índice, no ∝ tamaño).
- Extraer todo / un lote = **un solo pase** de descompresión.
- Sin regresión funcional: toda la suite verde; mismas entradas y mismos contenidos que hoy.
- El acceso aleatorio repetido (Quick Look) puede ser más lento — aceptable y documentado.

## 10. Decisiones abiertas (para resolver en el plan)

1. ✅ **RESUELTA (2026-06-30) → Opción A: iterador secuencial en el motor** (estilo libarchive/tar).
   El motor ofrece "recorrer el tar comprimido en **un solo pase**, entregando cada entrada y sus
   bytes en streaming"; el modelo coloca cada una (a su destino) o la salta. Es el patrón canónico
   (tar `xzf` y libarchive `archive_read_next_header`/`archive_read_data`), el más óptimo (un pase +
   memoria constante) y coherente con lo que el proyecto **ya hace** para 7z/rar vía `LibArchive`.
   Descartadas: payload especial en `ExportPlan` (ensucia la abstracción neutral, contra el ítem 3
   de la 1ª auditoría) y "solo offset" (N re-descompresiones). Una entrada suelta sigue usando
   `streamExtract` (Fase 2); varias/todo usan el iterador. Pendiente de diseño en Fase 3-4: la
   integración del iterador con el flujo de extracción **async** del modelo (progreso/cancelación).
2. ✅ **RESUELTA (2026-06-30) → aceptar el coste, sin caché.** Un `.tar.<x>` es un flujo: no
   tiene acceso aleatorio (tar/libarchive re-leen desde el principio; las caché de re-arranque
   tipo `zran`/`dictzip` son optimizaciones especializadas, con estado y memoria — justo lo que
   esta feature evita). `entryData` **no desaparece** (lo usan la validación de contraseña en
   `ArchiveDocument.provideEntryPassword` y el re-guardado en `SavePayloadBuilder.nodeData`): con el
   container comprimido pasa a `streamExtract(offset:length:)`, que re-descomprime hasta el offset y
   **corta**. Caché → solo si la verificación manual (#5) muestra un problema real.
3. ✅ **RESUELTA (2026-06-30) → no soportar sparse en v1, pero detectar y no corromper.** Caso
   exótico (GNU). Lo óptimo no es ignorarlo: **detectar** la cabecera GNU sparse (type `'S'`=`0x53`)
   y las claves PAX `GNU.sparse.*`, y fallar limpio / documentar como limitación — **nunca** emitir
   bytes mal alineados en silencio. Test: un tar sparse debe dar error claro, no datos basura.
4. ✅ **RESUELTA (2026-06-30) → mantenerlo mapeado.** `openArchive` ya carga con `mappedIfSafe`, así
   que el SO pagina los bytes comprimidos bajo demanda y la RAM no escala (equivalente a leer de un
   `fd` como libarchive). Conservar **esos** bytes como `container`; no copiarlos a RAM.
5. ✅ **RESUELTA (2026-06-30) → test estructural de streaming (no RSS) + medición puntual.** Un test
   de RSS en CI es frágil entre máquinas, así que la prueba **automatizada** es estructural y
   determinista: un `streamDecompress` espía que afirme que se procesa por trozos y que el indexer
   **nunca** acumula el flujo entero, y aserción de que el `container` conservado es el **comprimido**
   (`container.count` ≈ tamaño del `.gz`, no del tar inflado).
   **Medición de RSS hecha** (CLI release sobre el motor real + `/usr/bin/time -l`, fixture `.tar.gz`
   de tar interno 1.07 GB / `.gz` 1 MB, extracción completa a un sink que descarta):

   | | código previo (`48469d3`) | streaming (`d4ce9bb`) |
   |---|---|---|
   | `container` conservado | 1.07 GB (tar inflado) | 1 MB (el `.gz` mapeado) |
   | **RSS pico** | **1.31 GB** | **8.5 MB** |

   → ~154× menos RAM, sin escalar con el tamaño del tar. (El método/harness queda en notas de sesión,
   no en el repo.)

## 11. Retoma — arranque de la próxima sesión (Fases 3b y 4)

> Punto de partida: rama `feat/streaming-tar`, `swift test` 144 verde. El **motor está completo**
> (`StreamIndexer` indexar, `streamExtract` por offset, `streamEntries` un pase) y **aislado**
> (no toca el codec). A partir de aquí se **toca aguas arriba**; ir con cuidado y la suite delante.

**Antes de tocar código, resolver §10 #2–#5.** Recomendaciones de partida (revisar al empezar):
- #2 Acceso aleatorio repetido (Quick Look): **aceptar el coste en v1** (re-descomprime hasta el
  offset). Sin caché por ahora; documentar.
- #3 Tar **sparse** (GNU): **no soportar en v1**, documentar como limitación (caso exótico).
- #4 `container` comprimido: **mantenerlo mapeado** — `openArchive` ya carga con `mappedIfSafe`,
  así que el `.tar.gz` original ya está mapeado; basta con conservar **esos** bytes como container.
- #5 Memoria: empezar con **verificación manual** (Instruments / Activity Monitor con un tar.gz
  grande); un test de RSS es frágil, valorarlo aparte.

### Fase 3b — cablear el codec (`Sources/ArchiveBrowser/ArchiveCodec.swift`)
Hoy `TarCodec.open` hace `decompress(data)` → **tar entero en RAM** como `container`, y
`entryData`/`extract` leen de ese tar. Cambiar a conservar el **container comprimido**:

1. **`TarCodec`** necesita también el `streamDecompress` del formato (hoy solo tiene `decompress`).
   Distinguir dos casos:
   - **`.tar` puro** (sin compresión): dejar como hoy — `container = data` (ya viene mapeado),
     `entries = listEntries`, `entryData = Tar.entryData` (acceso aleatorio directo). **No tiene el
     problema de RAM** (no se descomprime nada), así que no hace falta cambiarlo.
   - **`.tarGzip`/`.tarXz`/`.tarBzip2`**: `container = data` **comprimido**; `entries =` indexar con
     `StreamIndexer` alimentado por `streamDecompress(data){…}`; `entryData(entry,container) =`
     `streamExtract` a un buffer; `extract(entry,container,sink) =` `streamExtract` directo al sink.
2. **`SingleFileCodec.open`**: cuando detecta tar (ustar magic), hoy `decompress(data)` entero →
   cambiar a **indexar** (`StreamIndexer` con `streamDecompress`) y devolver `container = data`
   comprimido + `format = tarFormat`. Aguas arriba la extracción usará `format.codec` (el `TarCodec`
   del `tarFormat`) sobre ese container comprimido → **debe re-descomprimir** (de ahí el punto 1).
3. **Invariante clave a respetar:** "el `container` de `ArchiveReadResult` es lo que se conserva
   como `sourceArchiveData` y de lo que se extrae". Pasa de *tar descomprimido* a *bytes comprimidos*;
   verificar **todos** los consumidores de `sourceArchiveData`/`entryData`/`extract` (sobre todo
   `ExportPlan.payload = .archiveEntry(...)` en `FilePackrModel`).
4. Correr **toda** la suite: los tests de `ArchiveDocumentTests` (round-trip tar.gz) deben seguir
   verdes — mismo resultado, menos RAM.

### Fase 4 — "extraer todo"/lote en un pase (modelo, `FilePackrModel`)
Hoy la extracción recorre el árbol `ExportPlan` y llama `codec.extract` por entrada → con tar
comprimido serían N re-descompresiones. Falta **diseñar la integración** (decisión §10 #1 ya fija el
*qué*: usar `Tar.streamEntries`; falta el *cómo* en el modelo):
- Detectar que una extracción cubre **varias entradas del mismo tar comprimido** (p. ej. "Extraer
  todo", o una carpeta entera) y desviarla a **un solo `streamEntries`**, colocando cada entrada en
  su destino relativo y **saltando** las no seleccionadas.
- Respetar **progreso** (bytes emitidos) y **cancelación** (`CancelToken`) dentro del pase.
- Una entrada suelta (Quick Look, selección de 1) sigue por `streamExtract` (offset).
- **Sub-decisión a tomar al empezar:** cómo encaja con `ExportPlan` (¿un camino especial cuando el
  nodo raíz a extraer es un archivo tar comprimido entero? ¿el coordinador agrupa por archivo?).
  Mantener `ExportPlan` **neutral** (no meter un caso por-formato; el "un pase" lo orquesta el modelo
  llamando al motor).

### Checklist de "hecho" (toda la feature)
- [x] Abrir+listar+extraer un `.tar.gz` **no** infla el TAR en RAM — container comprimido +
      `StreamIndexer` (Fase 3b). Test estructural en `ArchiveCodecTests` **y RSS medido** (ver §10 #5).
- [x] Extraer **todo** = un solo pase de descompresión (Fase 4: `extractAll` → `streamEntries`;
      test `testTarGzipExtractAllUsesSinglePass` afirma 1 pase).
- [x] Extraer **una** entrada suelta = `streamExtract` (offset), corta antes (Fase 4: `extractAll`
      con 1 entrada → `extract` → `streamExtract`).
- [x] Sin regresión: `swift test` 152 verde + `xcodebuild` app SUCCEEDED.
- [x] Limitaciones documentadas y aplicadas: Quick Look re-descomprime; **sparse no soportado con
      guard real** — `listEntries` y `StreamIndexer` lanzan `TarError.unsupportedSparse` ante type
      `'S'` (GNU antiguo) o claves `GNU.sparse.*` (PAX), nunca emiten basura (`TarStreamTests`).
- [x] Pulido: `StreamIndexer` usa un **índice de lectura** (`head`) que solo avanza y compacta una
      vez por `consume` (antes re-basaba con `Data(buffer)` en cada cabecera/trozo → copia cuadrática).
      Sin cambio de comportamiento; cubierto por la paridad con `listEntries` a varios troceados.

---

**Estado: COMPLETA** en la rama `feat/streaming-tar`. Todas las fases hechas y verificadas —
Fase 1 (`StreamIndexer`), Fase 2 (`streamExtract`), Fase 3a (`streamEntries`), **Fase 3b** (codec
conserva el container comprimido + API `extractAll`), **Fase 4** (extracción en un solo pase en el
modelo, `ExportPlan` neutral), guard de **sparse** (§10 #3) y **pulido** del `StreamIndexer` (índice
de lectura). Decisiones §10 #1–#5 resueltas. **`swift test` 152 verde + `xcodebuild` app OK + RSS
medido** (§10 #5: 1.31 GB → 8.5 MB). Pendiente solo: decidir **push / PR** de la rama.
