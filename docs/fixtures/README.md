# Fixtures de formatos solo-lectura de libarchive

Los formatos **RAR / CAB / CPIO / LHA** son de solo lectura: el motor los lee vía
libarchive pero **no los escribe**, así que no hay round-trip (escribir→leer) posible.
Se prueban contra **fixtures reales** en `Tests/ArchiveBrowserTests/Fixtures/`, ejercitados
por `LibArchiveFixtureTests.swift`.

Todos los fixtures usan la variante **almacenada** (sin compresión): basta para validar el
*análisis* del contenedor por libarchive; la descompresión propietaria no la ejercitamos (ni la
usamos). Contenido conocido y determinista para poder afirmar bytes exactos en los tests.

## Cómo se generaron (sin conexión, sin dependencias externas)

| Fixture        | Cómo                                                      |
|----------------|----------------------------------------------------------|
| `sample.cpio`  | `/usr/bin/cpio -o -H newc` (formato SVR4/newc)           |
| `sample.cab`   | `docs/fixtures/make_cab.py` (MSCF store, hecho a mano)   |
| `sample.lha`   | `docs/fixtures/make_lha.py` (cabecera nivel 0, `-lh0-`)  |
| `sample.rar`   | `docs/fixtures/make_rar.py` (RAR 4.x, método 0x30 store) |

CAB/LHA/RAR se fabrican a mano porque las herramientas que los crean (`gcab`, `lha`, WinRAR)
no vienen con macOS y requerirían `brew install` / software propietario. Los tres scripts
producen contenedores válidos que la libarchive del sistema (`bsdtar`) lee sin avisos.

Regenerar (p. ej. si se cambia el contenido de prueba):

```sh
python3 docs/fixtures/make_cab.py Tests/ArchiveBrowserTests/Fixtures/sample.cab
python3 docs/fixtures/make_lha.py Tests/ArchiveBrowserTests/Fixtures/sample.lha
python3 docs/fixtures/make_rar.py Tests/ArchiveBrowserTests/Fixtures/sample.rar
```

## Fixtures RAR5 reales (generados con `rar` 7.23)

Además del `sample.rar` almacenado a mano (RAR 4.x), hay tres RAR5 hechos con el `rar` oficial
de RARLAB (contraseña real `clave123` donde aplica):

| Fixture                  | Cómo se generó                          | Qué prueba                          |
|--------------------------|-----------------------------------------|-------------------------------------|
| `comp-rar5.rar`          | `rar a -ma5 -m5`                        | descompresión RAR5 real (sin cifrar)|
| `enc-rar5-headers.rar`   | `rar a -ma5 -hpclave123`                | cifrado de datos **y** cabeceras    |
| `enc-rar5-data.rar`      | `rar a -ma5 -pclave123`                 | cifrado de solo datos               |

> **Limitación verificada**: la libarchive del sistema **no descifra RAR** (ni RAR4 ni RAR5), solo
> el `unrar` propietario. Un RAR5 cifrado con la clave **correcta** sigue fallando en el motor,
> mientras que `unrar -pclave123` sí lo extrae. Los tests `testRar5Encrypted*` fijan esta conducta.
> RAR **sin cifrar** (incl. RAR5 comprimido) sí se lee y extrae.
>
> Nota: RAR 7 ya **no crea** archivos RAR4 (`-ma4` retirado); por eso el fixture RAR4 se fabrica
> a mano. Y crear estos requiere el `rar` de RARLAB (no viene con macOS, no reproducible del todo
> sin conexión) — quedan versionados en el repo precisamente para no depender de él en CI.

## Fixtures de volúmenes RAR **nativos** (multivolumen, no el esquema propio de FilePackr)

| Fixture                              | Cómo                                | Qué prueba                                   |
|---------------------------------------|--------------------------------------|-----------------------------------------------|
| `volumes.part1.rar`/`volumes.part2.rar` | `docs/fixtures/make_rar_volumes.py` | esquema moderno (`nombre.partN.rar`)          |
| `volumes.rar`/`volumes.r00`           | mismos bytes, renombrados            | esquema legado (`nombre.rar`+`.r00`…)         |

RAR 4.x (*storing*, 0x30) fabricado a mano igual que `sample.rar`, pero partido en **2
volúmenes**: `partido.txt` queda partido entre ambos (banderas `LHD_SPLIT_AFTER`/
`LHD_SPLIT_BEFORE` del `FILE_HEAD` y `MHD_VOLUME` en el `MAIN_HEAD` de cada volumen) y
`entero.txt` vive entero en el segundo, para ejercitar varias entradas. No se puede fabricar
por concatenación simple de dos `sample.rar`: cada volumen real lleva su propia cabecera
intercalada, que es justo lo que `archive_read_open_filenames` (y no `Volumes.join`) sabe
saltar. Verificado leyendo con `LibArchive.listEntries(volumes:)`/`extractEntries(volumes:)`
antes de fijar el fixture — ver `LibArchiveFixtureTests.testRarVolumes*`.

Regenerar:
```sh
python3 docs/fixtures/make_rar_volumes.py Tests/ArchiveBrowserTests/Fixtures/volumes.part1.rar Tests/ArchiveBrowserTests/Fixtures/volumes.part2.rar
cp Tests/ArchiveBrowserTests/Fixtures/volumes.part1.rar Tests/ArchiveBrowserTests/Fixtures/volumes.rar
cp Tests/ArchiveBrowserTests/Fixtures/volumes.part2.rar Tests/ArchiveBrowserTests/Fixtures/volumes.r00
```
(y copiar los cuatro ficheros también a `Tests/FilePackrModelTests/Fixtures/`, que tiene su
propio target de recursos — ver `Package.swift`).
