# FilePackr v1.0

Gestor de archivos comprimidos **nativo para macOS**: abre y explora archivos
(`.zip`, `.tar(.gz/.xz/.bz2)`, `.7z`, `.rar`, `.iso`, `.xar`/`.pkg`, `.cpio`,
`.lha`, `.cab`…) **sin descomprimirlos**, edita su contenido, extrae, previsualiza
con Quick Look, **convierte entre formatos** y **cifra con contraseña** (ZIP estándar,
interoperable con Finder/Keka/WinZip/7-Zip).

Interfaz nativa (SwiftUI + AppKit) con un navegador de ficheros tipo Finder.

---

## Descargar

| Archivo | Descripción |
|---|---|
| **[`FilePackr-1.0-unsigned.dmg`](https://github.com/kiko-lin/FilePackr/releases/download/v1.0/FilePackr-1.0-unsigned.dmg)** | La aplicación (imagen de disco). **4,7 MB.** Universal: Intel + Apple Silicon. |

**Requisitos:** macOS 14 (Sonoma) o superior. Compatible con Mac Intel y Apple Silicon (binario universal).

**SHA-256** del DMG (para verificar la descarga):

```
5c713ad98d446782f4b6df4e6f4a2176719aa90241bc5f6f02765bce053d74f9
```

Verifícalo tras descargar con:

```bash
shasum -a 256 FilePackr-1.0-unsigned.dmg
```

---

## Instalación

1. Descarga **[`FilePackr-1.0-unsigned.dmg`](https://github.com/kiko-lin/FilePackr/releases/download/v1.0/FilePackr-1.0-unsigned.dmg)** y haz doble clic para montarlo.
2. Arrastra **FilePackr** a la carpeta **Aplicaciones**.
3. Expulsa la imagen de disco.

### Primera apertura (importante)

Esta versión está firmada de forma *ad-hoc* pero **no está notarizada por Apple**
(la notarización requiere una cuenta de pago del Apple Developer Program). Por eso,
la **primera vez** macOS mostrará un aviso de seguridad. Para abrirla:

- Ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el aviso sobre
  «FilePackr» y pulsa **«Abrir igualmente»**. Confirma una vez más al abrir la app.

O, alternativamente, desde la Terminal:

```bash
xattr -d com.apple.quarantine /Applications/FilePackr.app
```

Solo hay que hacerlo **una vez**. A partir de ahí la app abre con normalidad.

### Alternativa: compilar desde el código

Al ser **open source** (GPL-3.0), también puedes compilarla tú mismo sin ningún aviso:

```bash
git clone https://github.com/kiko-lin/FilePackr.git
cd FilePackr
open App/FilePackr.xcodeproj   # ⌘R con el esquema «FilePackr» (requiere Xcode)
```

---

## Funcionalidades principales

- **Navegar sin descomprimir** — abre archivos de varios GB al instante (lee solo el índice).
- **Editar** — añadir/arrastrar ficheros y carpetas, borrar, renombrar, mover, crear carpetas,
  con selección múltiple y resolución de conflictos.
- **Extraer** — por elemento, en lote o «Extraer todo», con diálogo de conflictos.
- **Convertir entre formatos** — abre en un formato y guarda en otro.
- **Cifrado ZIP** — débil (ZipCrypto) o **fuerte AES-256** (WinZip AE-2, interoperable).
- **Quick Look**, columnas ordenables tipo Finder y barra de estado.
- **Guardado en streaming a disco** con barra de progreso (no carga el archivo entero en memoria).
- **ZIP64** (>4 GB o >65.535 entradas) y **división en volúmenes**.
- **Ajustes**: tema, formato y cifrado por defecto, destino de extracción, política de ficheros ocultos. El **idioma sigue al del sistema** (app traducida ES/EN, sin selector propio).

---

## Formatos soportados

| Familia | Formatos | Lectura | Escritura |
|---|---|---|---|
| ZIP | `.zip` (ZIP64, cifrado) | ✅ | ✅ |
| tar y compresores | `.tar` `.tar.gz` `.tar.xz` `.tar.bz2` `.gz` `.xz` `.bz2` | ✅ | ✅ |
| libarchive | `.7z` `.iso` `.xar`/`.pkg` | ✅ | ✅ |
| libarchive (solo lectura) | `.rar` `.cpio` `.lha`/`.lzh` `.cab` | ✅ | — |

---

## Licencia

[GPL-3.0-or-later](https://github.com/kiko-lin/FilePackr/blob/main/LICENSE) © 2026 Francisco Javier Linares.
