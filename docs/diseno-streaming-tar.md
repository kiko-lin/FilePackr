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

## 2. El trade-off intrínseco (a tener presente)

gzip/xz/bz2 **no tienen acceso aleatorio**: para llegar al byte N hay que descomprimir 0…N.
Por tanto, para acceso aleatorio a un tar comprimido solo hay tres palancas — **guardar**
(RAM/disco), **re-descomprimir** (CPU), o limitar el patrón de acceso. No existe una vía que
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
3. **Cableado del codec:** `TarCodec`/`SingleFileCodec` usan índice + container comprimido; ajustar
   `ArchiveReadResult`. Ejecutar toda la suite (no debe romperse nada aguas arriba).
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

1. **Dónde vive la extracción por lotes** (codec batch vs `ExportPlan`) — cruce motor↔modelo.
2. ¿Caché de re-arranque para acceso aleatorio repetido, o se acepta el coste en v1?
3. ¿Soporte de tar **sparse** o no-soportado documentado?
4. ¿El `container` comprimido se mantiene **mapeado** todo el ciclo de vida del documento?
5. Métrica de éxito de memoria: ¿test automatizado de RSS o verificación manual?

---

**Estado:** rama `feat/streaming-tar`. **Fases 1 y 2 hechas y verificadas** (`Tar.StreamIndexer` +
`Tar.streamExtract` + `TarStreamTests`; suite 142 verdes). Las piezas del motor están listas y
aisladas (aún **no** tocan el codec). **Antes de la Fase 3** (cablear `TarCodec`/`SingleFileCodec`
para conservar el container comprimido en vez del tar en RAM) **hay que cerrar las decisiones
abiertas (§10)** — sobre todo **dónde vive la extracción por lotes** (codec batch vs `ExportPlan`,
cruce motor↔modelo), que condiciona la API del codec. Ese es el punto de decisión, no de código.
