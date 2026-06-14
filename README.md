# FilePackr

Gestor de archivos comprimidos para **macOS**: abre y navega ZIP **sin
descomprimirlos**, crea/edita archivos (añadir, borrar, renombrar, mover, carpetas),
extrae, previsualiza con Quick Look y **cifra con contraseña** (estándar ZIP).

Interfaz nativa (SwiftUI + AppKit), con un navegador de ficheros basado en
`NSOutlineView` tipo Finder.

## Características

- **Navegar sin descomprimir**: lee solo el índice (central directory) del ZIP;
  abrir es rápido aunque el archivo sea de varios GB.
- **Editar**: arrastrar/añadir ficheros y carpetas, borrar, **renombrar** en línea,
  **mover** arrastrando sobre carpetas, crear carpetas.
- **Extraer**: botón, menú contextual o **arrastrar al Finder**; diálogo de
  conflictos (sobrescribir / guardar como / cancelar).
- **Quick Look**: barra espaciadora, como en Finder.
- **Columnas tipo Finder**: Nombre, Fecha, Tamaño, Clase, Comprimido; ordenables
  por cabecera.
- **Operaciones en segundo plano** con barra de progreso (abrir / guardar /
  extraer); el guardado va en **streaming a disco** (no carga el ZIP en memoria).
- **ZIP64**: lee y escribe archivos > 4 GB o con > 65.535 entradas.
- **Cifrado ZIP estándar** (interoperable con Finder, Keka, WinZip, 7-Zip):
  - **Débil** — ZipCrypto / PKWARE clásico (universal, inseguro).
  - **Fuerte** — AES-256 de WinZip (AE-2).
  - Diálogo de guardado: formato + cifrado + contraseña opcional.
  - **Abrir archivos con contraseña** (de cualquier app): pide la clave, la valida
    y la recuerda. Re-guardar conserva el cifrado.
  - Un archivo cifrado **bloqueado** es de solo lectura hasta dar la contraseña.

Ver [`docs/encryption.md`](docs/encryption.md) y [`docs/architecture.md`](docs/architecture.md).

## Arquitectura

```
Cifrador/                         (raíz del repo; remoto git: github.com/kiko-lin/packr)
├── Package.swift                 paquete "CifradorCore" (lógica, testeable por CLI)
├── Sources/
│   ├── ArchiveBrowser/           motor ZIP (sin UI)
│   │   ├── ZipReader.swift       lee el índice (central directory) + ZIP64
│   │   ├── ZipExtractor.swift    extrae una entrada (deflate/almacenado, descifra)
│   │   ├── ZipWriter.swift       escribe ZIP (streaming, ZIP64, cifrado)
│   │   ├── ZipCrypto.swift       cifrado clásico "Débil"
│   │   ├── ZipAES.swift          cifrado AES-256 de WinZip "Fuerte"
│   │   ├── Deflate.swift         DEFLATE vía framework Compression
│   │   └── CRC32.swift
│   └── CryptoCore/               AES-256-GCM + PBKDF2 (formato propio .fpkz, legacy)
├── Tests/                        26+ tests (swift test), con interop contra zip/unzip
└── Cifrador/                     proyecto Xcode de la app
    ├── FilePackr.xcodeproj
    └── FilePackr/                fuentes de la app (SwiftUI/AppKit)
        ├── FilePackrApp.swift
        ├── ContentView.swift     barra superior + barra de documento + diálogos
        ├── ArchiveDocument.swift modelo (árbol editable, abrir/guardar/extraer)
        └── ArchiveOutlineView.swift  navegador NSOutlineView (selección, drag, QL)
```

La lógica del ZIP vive en un paquete Swift independiente de la UI, así la parte
sensible (formato, cifrado) se prueba sin levantar la interfaz.

## Compilar y probar

Tests del motor (sin Xcode):

```bash
swift test
```

La app (requiere Xcode, macOS):

```bash
open Cifrador/FilePackr.xcodeproj   # luego ⌘R (esquema FilePackr)
# o por línea de comandos:
xcodebuild -project Cifrador/FilePackr.xcodeproj -scheme FilePackr \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

> El icono de macOS 26 es *full-bleed* (cuadrado opaco): el sistema le aplica la
> máscara redondeada.

## Estado y pendientes

Ver [`AGENTS.md`](AGENTS.md) para el detalle de lo hecho y los objetivos
pendientes (TODO).
