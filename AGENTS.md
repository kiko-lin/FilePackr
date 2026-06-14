# AGENTS.md — Contexto de trabajo de FilePackr

Fichero de contexto para agentes (Claude Code) que retomen el proyecto. Mantén
este archivo al día tras cada bloque de trabajo.

## Qué es

App de macOS (SwiftUI + AppKit) para gestionar archivos comprimidos **ZIP**:
abrir/navegar sin descomprimir, editar, extraer, previsualizar y **cifrar con
contraseña** (estándar ZIP). Ver `README.md` para la visión general.

- **Repo local**: `~/Desktop/Repos/Cifrador` (la carpeta se llama `Cifrador` por
  historia; la app y el producto son **FilePackr**).
- **Remoto git**: `git@github.com:kiko-lin/packr.git` (SSH). El entorno del agente
  **no tiene red** → los `git push` los hace el usuario.
- **Plataforma**: macOS 26 (Tahoe), Swift 6.3, Xcode 26. App target `FilePackr`,
  bundle `com.kiko.FilePackr`, lenguaje Swift 5 mode con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

## Cómo trabajar (importante)

- **Tests del motor**: `swift test` (rápido, sin Xcode). Hay tests de interop que
  llaman a `/usr/bin/zip` y `/usr/bin/unzip` (ZipCrypto).
- **Compilar la app**: `xcodebuild -project Cifrador/FilePackr.xcodeproj -scheme FilePackr -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build`.
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

- Motor (paquete `CifradorCore`, `Sources/`):
  - `ArchiveBrowser`: `ZipReader` (índice + ZIP64; **solo lee la cola + central
    directory**, no copia el fichero), `ZipExtractor` (extrae/descifra),
    `ZipWriter` (escribe; `build` en memoria y `write` en streaming a `FileHandle`;
    ZIP64; `ZipEncryption .none/.zipCrypto/.aes256`), `ZipCrypto`, `ZipAES`,
    `Deflate` (framework Compression), `CRC32`. También `Tar`, `Gzip`, `Volumes`.
- App (`Cifrador/FilePackr/`):
  - `ArchiveDocument` (`@MainActor ObservableObject`): árbol `FileNode`, abrir
    (`openArchive` async), guardar (`save(to:encryption:password:)` en streaming),
    extraer, mover/renombrar, plan de exportación (`ExportPlan`), progreso.
  - `ArchiveOutlineView` (`NSViewRepresentable` + `Coordinator`): el navegador
    `NSOutlineView` — selección, columnas ordenables, arrastre (mover/extraer/
    añadir), Quick Look (barra espaciadora), renombrado en línea, menú contextual.
  - `ContentView`: barra superior (Añadir/Eliminar/Crear carpeta/Extraer), barra
    de documento (icono+nombre, Cerrar/Guardar), zona de arrastre, overlay de
    progreso, diálogos (conflicto, cerrar, contraseña, **opciones de guardar**).

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
  navegador; contraseña si hace falta).
- Icono de app (full-bleed macOS 26).
- **Ajustes** (`SettingsView.swift` + `AppSettings.swift`): el engranaje de la barra
  abre una **hoja modal** (no menú). `AppSettings` (@MainActor, ObservableObject,
  UserDefaults, en caliente): **tema** (sistema/claro/oscuro → `preferredColorScheme`),
  **formato por defecto**, **cifrado por defecto** (se aplican a documentos nuevos en
  `saveDocument`), **destino de extracción** (carpeta del archivo o carpeta fija, se
  aplica en `extract`), e **icono de app**. El idioma sigue en `Localizer`.
- **Iconos de app** (5: naranja/verde/morado/azul/rojo): image sets en
  `Assets.xcassets` (`AppIconOrange/Green/Purple/Blue/Red`), catálogo en
  `AppIconOption.all`. Se aplican al **Dock** con `NSApp.applicationIconImage`
  (recortado a esquinas redondeadas; se reaplica al arrancar). Nota: el icono del
  **bundle** (Finder, `AppIcon`) es fijo y no cambia en caliente. Para añadir uno
  nuevo: image set + entrada en `AppIconOption.all`.
- **i18n** (`Localization.swift`): `Localizer` (@MainActor, ObservableObject) con
  catálogo EN/ES en memoria y cambio de idioma **en caliente** (recordado en
  UserDefaults). **Inglés por defecto**. Icono de ajustes (engranaje) en la barra →
  menú con selector de idioma. Uso: en vistas `@EnvironmentObject var loc` y
  `loc("clave")`/`loc("clave", arg)`; en modelo `Localizer.shared("clave")`. Para
  añadir texto: nueva clave en `en`/`es`. `ArchiveOutlineView` recibe `language` y
  re-titula columnas/menú al cambiar. Nota: los nombres de "Clase" vienen de
  `UTType.localizedDescription` (siguen el idioma del SO, no el de la app).

## TODO (objetivos pendientes, en orden lógico)

- [ ] **Verificar interop AES-256 en Keka/7-Zip** (lo prueba el usuario; el agente
      no tiene esas herramientas). Si falla, revisar `ZipAES` (PBKDF2/CTR/HMAC,
      campo extra 0x9901, AE-2 CRC=0).
- [x] ~~tar/gz/tar.gz en Swift puro~~ (Tier 1, hecho — ver "Hecho").
- [ ] **Más formatos**: 7z/rar/dmg/bzip2/xz con **libarchive** (vendorizar C —
      esfuerzo grande). El selector de formato del diálogo ya está montado.
- [x] ~~Limpieza legacy~~ (hecho 2026-06-14): retirados `.fpkz`, librería `CryptoCore`,
      `CipherView.swift` y `ArchiveTree.swift`. El cifrado es solo ZIP estándar.
- [ ] **Cambiar cifrado/contraseña al re-guardar** ("Guardar como…"): hoy re-guardar
      conserva el cifrado y la contraseña originales; no hay UI para cambiarlos.
- [ ] **Opciones de fuerza AES** (128/192) además de 256; ZipCrypto ya está.
- [ ] **Streaming de compresión** de un único fichero enorme (hoy cada fichero se
      carga entero en memoria para comprimir).
- [x] ~~Localización~~ (hecho: EN/ES con selector de idioma — ver "Hecho"). Pendiente
      menor: más idiomas, y que "Clase" use el idioma de la app y no el del SO.
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
- Volúmenes: división **por bytes** (no spanning PKWARE nativo). La primera parte
  conserva el nombre base (`nombre.zip`) y las siguientes llevan `_NNN` antes de la
  extensión (`nombre_001.zip`, `nombre_002.zip`…). Reconstrucción = concatenar en
  orden. Detección al abrir: si existe `nombre_001.<ext>` junto a `nombre.<ext>` es
  un juego; un `nombre_NNN.<ext>` solo cuenta como volumen si su base existe (evita
  falsos positivos tipo `backup_2024.zip`). Guardar como fichero único limpia los
  `_NNN` sobrantes (si no, se reabriría como multivolumen). NO soportado: el split
  PKWARE nativo `.z01`/.zip (cabeceras de spanning) — sería trabajo aparte.
