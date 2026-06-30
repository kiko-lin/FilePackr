# FilePackr

[![CI](https://github.com/kiko-lin/FilePackr/actions/workflows/ci.yml/badge.svg)](https://github.com/kiko-lin/FilePackr/actions/workflows/ci.yml)

Gestor de archivos comprimidos para **macOS**: abre y navega archivos **sin
descomprimirlos**, edita (añadir, borrar, renombrar, mover, crear carpetas), extrae,
previsualiza con Quick Look, **convierte entre formatos** y **cifra con contraseña**
(estándar ZIP, interoperable con Finder/Keka/WinZip/7‑Zip).

Interfaz nativa (SwiftUI + AppKit) con un navegador de ficheros tipo Finder
(`NSOutlineView`).

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
- **ZIP64** (archivos > 4 GB o > 65.535 entradas) y **volúmenes** (división por bytes).
- **Cifrado ZIP estándar**:
  - **Débil** — ZipCrypto / PKWARE clásico (universal, inseguro).
  - **Fuerte** — AES‑256 de WinZip (AE‑2), interop verificada contra `pyzipper`.
  - Abrir archivos con contraseña de otras apps (pide la clave, la valida y la
    recuerda); re‑guardar conserva el cifrado; un cifrado bloqueado es de solo lectura.
- **Aviso de cambios sin guardar** al cerrar/salir, con tres opciones **Guardar /
  Cerrar sin guardar / Cancelar** (Guardar ejecuta el guardado y luego cierra);
  **sin pestañas** (una ventana por archivo); **Ajustes** en el menú de la app (⌘,):
  tema, idioma (EN/ES), formato y cifrado por defecto, destino de extracción.

Ver [`docs/architecture.md`](docs/architecture.md) y [`docs/encryption.md`](docs/encryption.md).

## Arquitectura

```
FilePackr/                            (raíz del repo; remoto: github.com/kiko-lin/FilePackr)
├── Package.swift                     paquete "FilePackrCore": librerías ArchiveBrowser + FilePackrModel
├── .github/workflows/ci.yml          CI (GitHub Actions): compila y corre los tests del motor en cada PR
├── Sources/
│   ├── ArchiveBrowser/               motor de archivos (sin UI)
│   │   ├── ArchiveFormat.swift        enum de formato: capacidades + detección (ext/firma)
│   │   ├── ArchiveCodec.swift         registro formato→codec: leer/extraer por formato
│   │   ├── ArchiveEntry.swift         entrada neutral (+ bloque ZIP opcional)
│   │   ├── ZipReader / ZipExtractor / ZipWriter / ZipCrypto / ZipAES / Deflate / CRC32
│   │   ├── Tar / Gzip / Xz / Bzip2    tar y compresores (Swift puro / Compression / libbz2)
│   │   ├── LibArchive.swift           puente a la libarchive del sistema (7z/rar/iso/…)
│   │   └── Volumes / VolumeStore      troceado por bytes (en memoria / en disco)
│   ├── FilePackrModel/               capa de modelo de la app (sin vistas; testeable por CLI)
│   │   ├── ArchiveDocument.swift      modelo (árbol editable, abrir/guardar/exportar/extraer)
│   │   ├── ArchiveSaver / SavePayloadBuilder   codifica el SavePayload a disco (streaming)
│   │   ├── FileNode / ExportPlan      nodo del árbol / instantánea Sendable para extraer
│   │   ├── OperationCoordinators.swift  coordinadores de añadir / extraer / guardar
│   │   └── AppSettings.swift          ajustes (tema, idioma, formato/cifrado por defecto)
│   └── Cbz2 / Carchive / Cz / Clzma  systemLibrary → libbz2 / libarchive / zlib / liblzma del sistema
├── Tests/
│   ├── ArchiveBrowserTests/          tests del motor (swift test; interop opcional zip/unzip, pyzipper)
│   └── FilePackrModelTests/          tests del modelo (en local; excluidos del CI, ver AGENTS.md)
└── App/                             proyecto Xcode de la app (SwiftUI/AppKit)
    ├── FilePackr.xcodeproj
    ├── FilePackr/                    vistas y arranque de la app
    │   ├── ArchiveOutlineView.swift   navegador NSOutlineView (selección, drag, Quick Look)
    │   ├── ContentView.swift          cabecera + columna de acciones + barra de estado + diálogos
    │   ├── WindowGuard.swift          aviso de cambios sin guardar (cierre de ventana)
    │   ├── SettingsView / Localization
    │   └── FilePackrApp.swift
    └── FilePackrTests/               tests del modelo de la app (⌘U; no los ve `swift test`)
```

La lógica de archivos (`ArchiveBrowser`) y la capa de modelo (`FilePackrModel`) viven en
un paquete Swift independiente de la UI, así la parte sensible (formato, cifrado, edición)
se prueba sin levantar la interfaz.

## Compilar y probar

Tests del motor (sin Xcode):

```bash
swift test
# Interop AES-256 opcional: pip3 install pyzipper && swift test
```

La app (requiere Xcode, macOS):

```bash
open App/FilePackr.xcodeproj   # luego ⌘R (esquema FilePackr); tests del modelo con ⌘U
# o por línea de comandos:
xcodebuild -project App/FilePackr.xcodeproj -scheme FilePackr \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### Integración continua

Cada PR (y push) a `main` dispara [GitHub Actions](.github/workflows/ci.yml): compila las
librerías y corre los **tests del motor** en un runner de macOS. Los tests de `FilePackrModel`
y la app quedan fuera del CI por ahora (requieren la toolchain de Xcode 26, aún no disponible
en los runners alojados) y se ejecutan en local; ver [`AGENTS.md`](AGENTS.md) para el detalle.

## Estado y pendientes

Ver [`AGENTS.md`](AGENTS.md) para el detalle de lo hecho y los objetivos pendientes (TODO).
