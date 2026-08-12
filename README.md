# FilePackr

[![CI](https://github.com/kiko-lin/FilePackr/actions/workflows/ci.yml/badge.svg)](https://github.com/kiko-lin/FilePackr/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Gestor de archivos comprimidos para **macOS**: abre y explora archivos **sin
descomprimirlos**, edita (añadir, borrar, renombrar, mover, crear carpetas), extrae,
previsualiza con Quick Look, **convierte entre formatos** y **cifra con contraseña**
(estándar ZIP, interoperable con Finder/Keka/WinZip/7‑Zip).

Interfaz nativa (SwiftUI + AppKit) con un navegador de ficheros tipo Finder
(`NSOutlineView`).

## Entrega (TFM)

Proyecto Final del Máster — Francisco Javier Linares (`kikolincor@gmail.com`).

| Entregable | Enlace |
|---|---|
| **Código fuente** | https://github.com/kiko-lin/FilePackr |
| **Despliegue / descarga** (app en funcionamiento) | [Release v1.0](https://github.com/kiko-lin/FilePackr/releases/tag/v1.0) (con el `.dmg`) |
| **Presentación (slides)** | [`docs/FilePackr-presentacion.pptx`](docs/FilePackr-presentacion.pptx) · [PDF](docs/FilePackr-presentacion.pdf) _(URL pública pendiente)_ |
| **Vídeo explicativo** | _pendiente_ ⏳ |
| **Usuario y contraseña de prueba** | N/A — la aplicación no tiene login |

> **Nota sobre el «despliegue»:** FilePackr es una **aplicación de escritorio nativa
> de macOS**, no un servicio web, por lo que su publicación en funcionamiento es un
> **GitHub Release** con la app empaquetada en un `.dmg` descargable
> ([notas de la versión](docs/release-notes-v1.0.md)). El evaluador puede **descargarla y
> usarla** directamente, o **compilarla desde el código** (`⌘R` en Xcode) al ser open source.
> Requisitos: macOS 14 (Sonoma) o superior · Intel y Apple Silicon (binario universal).

## Formatos

| Familia | Formatos | Motor | Lectura | Escritura |
|---|---|---|---|---|
| ZIP | `.zip` | propio (Swift) | ✅ (+ZIP64, cifrado) | ✅ |
| tar y compresores | `.tar` `.tar.gz` `.tar.xz` `.tar.bz2` `.gz` `.xz` `.bz2` | Swift puro / `Compression` / `libbz2` | ✅ | ✅ |
| libarchive | `.7z` `.iso` `.xar`/`.pkg` | libarchive del sistema | ✅ | ✅ |
| libarchive (solo lectura) | `.rar` `.cpio` `.lha`/`.lzh` `.cab` | libarchive del sistema | ✅ | — |

Abrir un archivo en un formato y **guardarlo en otro** reconstruye el contenido.

## Características

- **Navegar sin descomprimir**: el ZIP lee solo el índice (central directory); abrir
  es rápido aunque el archivo sea de varios GB.
- **Editar**: arrastrar/añadir ficheros y carpetas (varios a la vez), borrar, renombrar
  en línea, mover arrastrando sobre carpetas, crear carpetas. La vista despliega y revela
  lo recién añadido/creado y le da el foco; **selección múltiple** para arrastrar o borrar
  en lote. Añadir un nombre que ya existe pregunta **sobrescribir / conservar ambos / cancelar**.
- **Extraer**: por nodo o **varios seleccionados a la vez** (botón / menú / arrastre al
  Finder), o **Extraer todo** el archivo a una carpeta; con diálogo de conflictos
  (sobrescribir / guardar como / cancelar) por cada elemento.
- **Exportar**: escribe una **copia** con otro formato, cifrado, contraseña o
  troceado en volúmenes, sin tocar el documento abierto.
- **Quick Look** (barra espaciadora), columnas tipo Finder ordenables (Nombre, Fecha,
  Tamaño, Clase, Comprimido) y **barra de estado** (nº de ficheros · tamaño · comprimido).
- **Operaciones en segundo plano** con barra de progreso; el guardado va en **streaming
  a disco** (no carga el archivo entero en memoria).
- **ZIP64** (archivos > 4 GB o > 65.535 entradas) y **volúmenes** (división por bytes, propia
  de FilePackr). También **abre** los volúmenes RAR nativos que crean WinRAR/`rar`
  (`nombre.part1.rar…` o `nombre.rar`+`.r00…`), sin necesidad de concatenarlos a mano.
- **Cifrado ZIP estándar**:
  - **Débil** — ZipCrypto / PKWARE clásico (universal, inseguro).
  - **Fuerte** — AES‑256 de WinZip (AE‑2), interop verificada contra `pyzipper`.
  - Abrir archivos con contraseña de otras apps: pide la clave y la valida; mientras el
    archivo está abierto la mantiene en memoria (no hay que repetirla por entrada ni al
    re‑guardar conservando el cifrado), pero **no se persiste** —al cerrar y reabrir se
    vuelve a pedir. Un cifrado bloqueado (sin contraseña) es de solo lectura.
- **Aviso de cambios sin guardar** al cerrar/salir, con tres opciones **Guardar /
  Cerrar sin guardar / Cancelar** (Guardar ejecuta el guardado y luego cierra);
  **sin pestañas** (una ventana por archivo); **Ajustes** en el menú de la app (⌘,):
  tema, formato y cifrado por defecto, destino de extracción, política de ficheros ocultos.
  El **idioma sigue al del sistema** (la app está traducida ES/EN; no hay selector propio).

Ver [`docs/architecture.md`](docs/architecture.md) y [`docs/encryption.md`](docs/encryption.md).

## Arquitectura

```
FilePackr/                            (raíz del repo; remoto: github.com/kiko-lin/FilePackr)
├── Package.swift                     paquete "FilePackrCore": librerías ArchiveBrowser + FilePackrModel
├── .github/workflows/ci.yml          CI (GitHub Actions): swift test (motor + modelo) + compila la app, en cada PR
├── Sources/
│   ├── ArchiveBrowser/               motor de archivos (sin UI)
│   │   ├── ArchiveFormat.swift        enum de formato: capacidades + detección (ext/firma)
│   │   ├── ArchiveCodec.swift         registro formato→codec: leer/extraer por formato
│   │   ├── ArchiveEntry.swift         entrada neutral (+ bloque ZIP opcional)
│   │   ├── ZipReader / ZipExtractor / ZipWriter / ZipCrypto / ZipAES / Deflate / CRC32
│   │   ├── Tar / Gzip / Xz / Bzip2    tar y compresores (Swift puro / Compression / libbz2)
│   │   ├── LibArchive.swift           puente a la libarchive del sistema (7z/rar/iso/…)
│   │   ├── RarVolumes.swift           detecta volúmenes RAR nativos (WinRAR/`rar`, no concatenables)
│   │   └── Volumes / VolumeStore      troceado propio por bytes (en memoria / en disco)
│   ├── FilePackrModel/               capa de modelo de la app (sin vistas; testeable por CLI)
│   │   ├── ArchiveDocument.swift      modelo (árbol editable, abrir/guardar/exportar/extraer)
│   │   ├── ArchiveSaver / SavePayloadBuilder   codifica el SavePayload a disco (streaming)
│   │   ├── FileNode / ExportPlan      nodo del árbol / instantánea Sendable para extraer
│   │   ├── OperationCoordinators.swift  coordinadores de añadir / extraer / guardar
│   │   └── AppSettings.swift          ajustes (tema, formato/cifrado por defecto; idioma = el del sistema)
│   └── Cbz2 / Carchive / Cz / Clzma  systemLibrary → libbz2 / libarchive / zlib / liblzma del sistema
├── Tests/
│   ├── ArchiveBrowserTests/          tests del motor (swift test; interop opcional zip/unzip, pyzipper)
│   └── FilePackrModelTests/          tests del modelo (documento + coordinadores; los corre `swift test`)
└── App/                             proyecto Xcode de la app (SwiftUI/AppKit)
    ├── FilePackr.xcodeproj
    ├── FilePackr/                    vistas y arranque de la app
    │   ├── ArchiveOutlineView.swift   navegador NSOutlineView (selección, drag, Quick Look)
    │   ├── ContentView.swift          cabecera + columna de acciones + barra de estado + diálogos
    │   ├── WindowGuard.swift          aviso de cambios sin guardar (cierre de ventana)
    │   ├── SettingsView / Localization
    │   └── FilePackrApp.swift
    └── FilePackr.xcodeproj/xcshareddata/xcschemes/   scheme compartido (lo usa el CI)
```

La lógica de archivos (`ArchiveBrowser`) y la capa de modelo (`FilePackrModel`) viven en
un paquete Swift independiente de la UI, así la parte sensible (formato, cifrado, edición)
se prueba sin levantar la interfaz.

## Compilar y probar

Tests del motor y del modelo (sin Xcode):

```bash
swift test
# Interop AES-256 opcional: pip3 install pyzipper && swift test
```

La app (requiere Xcode, macOS):

```bash
open App/FilePackr.xcodeproj   # luego ⌘R (esquema FilePackr)
# o por línea de comandos:
xcodebuild -project App/FilePackr.xcodeproj -scheme FilePackr \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### Integración continua

Cada PR (y push) a `main` dispara [GitHub Actions](.github/workflows/ci.yml) en un runner de
macOS, con dos jobs en paralelo: **`swift test`** (suite completa, motor + modelo) y
**`xcodebuild build`** (compila la app, la capa de vistas). Si algo no compila o un test falla,
el PR queda en rojo. Ver [`AGENTS.md`](AGENTS.md) para el detalle.

## Distribución

Se distribuye de forma **directa** (fuera de la Mac App Store), con dos vías:

- **Gratuita** — `scripts/release.sh --unsigned` genera un `.dmg` con firma ad-hoc (sin
  coste ni cuenta de pago); el usuario lo autoriza la primera vez desde *Ajustes del Sistema
  → Privacidad y seguridad*. Al ser open source, cualquiera puede además **compilarla desde
  el código** (⌘R en Xcode) y correrla sin avisos.
- **Notarizada** — `scripts/release.sh` produce un `.dmg` firmado con **Developer ID** y
  **notarizado** (doble clic, sin avisos); requiere el Apple Developer Program.

El hardened runtime ya está activado y el pipeline listo. Guía paso a paso en
[`docs/distribution.md`](docs/distribution.md).

## Licencia

[GPL-3.0-or-later](LICENSE) © 2026 Francisco Javier Linares.

## Estado y pendientes

Ver [`AGENTS.md`](AGENTS.md) para el detalle de lo hecho y los objetivos pendientes (TODO).
