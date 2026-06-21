# FilePackr

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
- **Editar**: arrastrar/añadir ficheros y carpetas, borrar, renombrar en línea, mover
  arrastrando sobre carpetas, crear carpetas (la vista despliega y revela la nueva).
- **Extraer**: por nodo (botón / menú / arrastre al Finder) o **Extraer todo** el
  archivo a una carpeta; con diálogo de conflictos (sobrescribir / guardar como / cancelar).
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
- **Aviso de cambios sin guardar** al cerrar/salir; **sin pestañas** (una ventana por
  archivo); **Ajustes** en el menú de la app (⌘,): tema, idioma (EN/ES), formato y
  cifrado por defecto, destino de extracción.

Ver [`docs/architecture.md`](docs/architecture.md) y [`docs/encryption.md`](docs/encryption.md).

## Arquitectura

```
FilePackr/                            (raíz del repo; remoto: github.com/kiko-lin/packr)
├── Package.swift                     paquete "FilePackrCore" (motor, sin UI, testeable por CLI)
├── Sources/
│   ├── ArchiveBrowser/               motor de archivos (sin UI)
│   │   ├── ArchiveFormat.swift        enum de formato: capacidades + detección (ext/firma)
│   │   ├── ArchiveCodec.swift         registro formato→codec: leer/extraer por formato
│   │   ├── ArchiveEntry.swift         entrada neutral (+ bloque ZIP opcional)
│   │   ├── ZipReader / ZipExtractor / ZipWriter / ZipCrypto / ZipAES / Deflate / CRC32
│   │   ├── Tar / Gzip / Xz / Bzip2    tar y compresores (Swift puro / Compression / libbz2)
│   │   ├── LibArchive.swift           puente a la libarchive del sistema (7z/rar/iso/…)
│   │   └── Volumes / VolumeStore      troceado por bytes (en memoria / en disco)
│   ├── Cbz2/                          systemLibrary → libbz2 del sistema
│   └── Carchive/                      systemLibrary → libarchive del sistema (shim.h propio)
├── Tests/                            tests del motor (swift test); interop opcional (zip/unzip, pyzipper)
└── App/                             proyecto Xcode de la app (SwiftUI/AppKit)
    ├── FilePackr.xcodeproj
    ├── FilePackr/                    fuentes de la app
    │   ├── ArchiveDocument.swift      modelo (árbol editable, abrir/guardar/exportar/extraer)
    │   ├── ArchiveSaver.swift         codifica el SavePayload a disco (streaming/saver)
    │   ├── FileNode / ExportPlan      nodo del árbol / instantánea Sendable para extraer
    │   ├── ArchiveOutlineView.swift   navegador NSOutlineView (selección, drag, Quick Look)
    │   ├── ContentView.swift          cabecera + columna de acciones + barra de estado + diálogos
    │   ├── WindowGuard.swift          aviso de cambios sin guardar (cierre de ventana)
    │   ├── SettingsView / AppSettings / Localization
    │   └── FilePackrApp.swift
    └── FilePackrTests/               tests del modelo de la app (⌘U; no los ve `swift test`)
```

La lógica de archivos vive en un paquete Swift independiente de la UI, así la parte
sensible (formato, cifrado) se prueba sin levantar la interfaz.

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

## Estado y pendientes

Ver [`AGENTS.md`](AGENTS.md) para el detalle de lo hecho y los objetivos pendientes (TODO).
