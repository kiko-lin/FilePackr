# Auditoría de arquitectura — 2026-06-22 (tercera)

Revisión exhaustiva de estructura, limpieza, buenas prácticas, arquitectura y deuda
dependiente. Parte de un estado ya maduro: las dos auditorías previas
(`auditoria-2026-06-21.md` + la de 2026-06-20 en AGENTS.md) cerraron 2 ALTO + 9 MEDIO +
todos los BAJO. Base verde confirmada: **83 tests del motor** (`swift test`) + 5 del modelo.

## Veredicto

**Sin hallazgos críticos.** El motor (`Sources/ArchiveBrowser`) es sólido y coherente:
streaming real con memoria constante en todos los caminos (compresión, descompresión,
extracción, libarchive), cripto unificado (`CTRKeystream` compartido), cota anti zip-bomb
en `Deflate`, escritura atómica compartida, detección por firma, ZIP64 lectura/escritura.
Higiene de repo correcta: `.gitignore` cubre `.DS_Store`/`xcuserstate`/`DerivedData`; nada
de basura rastreada; sin `TODO`/`FIXME`/`fatalError`/`try!` en producción.

Lo que queda es **deuda menor de coherencia** (decisiones aplicadas a medias) y un par de
**ineficiencias de borde**. Nada bloquea; todo es mejora incremental.

---

## MEDIO

### M-A · Deuda de nomenclatura «zip» en la capa de app — devalúa el item 3 (ArchiveEntry neutral)
La auditoría de 2026-06-20 (item 3) hizo `ArchiveEntry` **neutral** para todos los formatos.
Pero la capa de app sigue llamando «zip» a lo que ya es genérico:
- `FileNode.zipEntry(ArchiveEntry)` (`FileNode.swift:8`) — envuelve entradas de **tar/7z/gz/…**,
  no solo ZIP. El propio comentario lo admite: «(zip/tar/gz)».
- `FileNode.zipDate` (`FileNode.swift:20`) — guarda la fecha de cualquier formato.
- `ArchiveDocument.sourceArchiveData`, `firstEncryptedFile` iterando `case .zipEntry`.

El tell de que la decisión quedó a medias: `ExportPlan.Payload.archiveEntry`
(`ExportPlan.swift:13`) **sí** recibió el nombre neutral. Un lector ve `.zipEntry(entry)`
para un 7z y duda.
**Propuesta:** renombrar `.zipEntry`→`.entry`, `zipDate`→`entryDate`. Mecánico, sin cambio
de comportamiento, alinea el árbol con `ArchiveEntry`/`ExportPlan`.

### M-B · Doble escritura atómica en el guardado — redundancia introducida por M-3 (AtomicWrite)
`ArchiveDocument.writeArchive` ya escribe a un temporal `work` y luego **mueve/trocea** a
`url` (esa es la colocación atómica real). Pero `ArchiveSaver.encode`, para `.zip` y
`.stream`, envuelve la escritura a `work` en `writeFileAtomically` (crea `.tmp` → mueve a
`work`). Como `work` es desechable y `writeArchive` ya lo borra si algo falla, esa
atomicidad **sobra** (tmp→work→url son dos renames donde basta uno).

Además deja los 4 casos del `switch` **inconsistentes**:
- `.zip` / `.stream`: doble-atómico (tmp→work).
- `.data`: `write(to: work, options: .atomic)` (Foundation hace su propio temporal).
- `.libArchive`: escribe directo a `work` (no atómico).

El helper `writeFileAtomically` es correcto y **necesario** en su otro llamador
(`ExportPlan.writeContents`, que escribe a un destino real del Finder). Solo sobra dentro
de `ArchiveSaver`.
**Propuesta:** que `ArchiveSaver` escriba **directo** a `work` (los 4 casos igual) y que la
única colocación atómica la posea `ArchiveDocument` (move/split de `work`→`url`).

### M-C · El flujo Guardar/Exportar es la única operación por lotes que NO se extrajo a un coordinador
H-2 (auditoría anterior) sacó las colas de Añadir y Extraer a `AddCoordinator`/
`ExtractCoordinator` (`OperationCoordinators.swift`). El flujo de **guardar/exportar** se
quedó en `ContentView` con ~8 `@State` propios (`showingSaveOptions`, `optionsSheetIsExport`,
`saveFormatChoice`, `saveEncryptionChoice`, `saveOptionsPassword`, `splitEnabled`,
`volumeSizeValue`, `volumeUnit`, `pendingAfterSave`) y la lógica en `prefillOptionsSheet`/
`confirmSaveOptions`/`saveDocument`. Por eso `ContentView` reinfló a **608 LOC** (era 574
al cerrar H-2) y mantiene 17 `@State`.
**Propuesta:** `SaveCoordinator` análogo a los otros dos (estado de la hoja de opciones +
`prefill`/`confirm`, ejecución async inyectada por la vista). Completa la decisión de H-2 y
recorta `ContentView`.

### M-D · Apertura de gz/xz/bz2 suelto: descomprime TODO en RAM solo para mirar la firma ustar
`SingleFileCodec.open` (`ArchiveCodec.swift:137`) hace `let inner = try decompress(data)` para
distinguir un `.gz`/`.xz`/`.bz2` suelto de un `.tar.<x>`… pero `Tar.hasUstarMagic` solo
necesita **263 bytes**. Para un `.gz` de varios GB descomprimidos es un pico de memoria del
tamaño completo, y para el caso «suelto» ese `inner` se descarta (se conserva `data`).
Choca con el espíritu de los items de streaming (memoria constante): es el mismo problema
que el TODO «streaming en apertura de tar comprimido», pero **independiente y más barato** de
arreglar (descomprimir en streaming y cortar al tener 263 bytes). Curioso que `xz.entries`
ya lee el tamaño del índice sin inflar y `bzip2.entries` evita inflar >25 MB, pero `open`
infla todo igualmente antes de llegar ahí.

---

## BAJO

### B-A · `ContentView.describe` no cubre `ZipWriteError`
El mapeo de errores del motor a i18n (`ContentView.swift:573`) cubre `ExtractError`,
`LibArchiveError`, `ZipAESError`, `ArchiveError`, `Tar/Gzip/Xz/Bzip2Error`… pero **no**
`ZipWriteError` (`fileSourceNotStreamed`), que caería a `localizedDescription` (genérico, sin
traducir). Es un invariante interno improbable, pero rompe la coherencia del mapeo. Un `case`
→ `error.writeFailed`.

### B-B · `gzip.entries`/`storedFilename` copian el `.gz` entero a `[UInt8](data)`
`Gzip.swift:117` y `:127` hacen `[UInt8](data)` del fichero comprimido completo solo para
leer ISIZE (últimos 4 bytes) y FNAME (cabecera). El refactor **M-8** quitó exactamente este
patrón en `Tar.listEntries` (indexar `Data` con offsets absolutos); `gzip` se quedó atrás.
Misma técnica que `Xz`/`Tar` lo resuelve.

### B-C · `provideEntryPassword`: la rama de fallback es inconsistente
`ArchiveDocument.swift:216-223`: cuando no encuentra una entrada `.zipEntry` cifrada, la rama
`guard-else` desbloquea y `return true` pero **no** llama a `changed()` ni fija `savePassword`,
al revés que la rama de éxito (`:229-233`). Caso de borde (estado `needsEntryPassword` sin
nodo cifrado localizable), pero la asimetría puede morder en el futuro.

### B-D · `confirmSaveOptions`: `pendingAfterSave` puede quedar colgado si el guardado falla
`ContentView.swift:529-533`: si el panel da OK pero `doc.save` **lanza** (lo captura
`runAsync`), `!doc.hasUnsavedChanges` es `false`, así que no se ejecuta ni se limpia
`pendingAfterSave` → queda vivo y podría dispararse en un guardado posterior no relacionado.
La rama de cancelar sí lo limpia. Limpiarlo también tras un intento fallido.

---

## Confirmado bien hecho (no tocar)
- **Streaming integral**: `CompressionStream` (driver único gzip/xz), núcleos `compress(next:sink:)`
  por compresor, `Tar.reader` pull, `ZipWriter` con descriptor de datos + ZIP64-siempre,
  extracción a `sink` con verificación de MAC AES al final, libarchive `WriteItem.file`/`sink`.
- **Cripto**: `ZipAES.CTRKeystream` compartido por cifrado/descifrado/memoria; `[UInt8]
  (unsafeUninitializedCapacity:)` sin `append` en ZipCrypto/CTR; interop verificada.
- **Seguridad**: cota anti zip-bomb (`Deflate.maxDeflateRatio`); `LockState` como fuente única;
  doble guard de solo-lectura (UI + modelo).
- **Arquitectura**: `ArchiveCodec` (registro formato→codec); `ArchiveEntry` neutral + `zip:`
  opcional; modelo sin `Localizer` (tokens `ProgressKind`); `SavePayload`/`SavePayloadBuilder`
  separan qué/cómo/orquestación; `Sendable` correcto en todo el cruce de actor.
- **Higiene**: `.gitignore` completo, sin ficheros basura rastreados, 83 tests verdes.

## Orden sugerido de ataque (si se abordan)
1. **M-A** (renombrado mecánico, cierra el item 3 del todo).
2. **M-B** (quita un rename redundante y unifica los 4 casos del saver).
3. **B-A/B-C/B-D** (quick wins de coherencia, sin riesgo).
4. **M-C** (`SaveCoordinator`: refactor de UI, verificar en GUI).
5. **M-D / B-B** (ineficiencias de apertura gz/xz/bz2; valor real solo con ficheros enormes).
</content>
</invoke>
