# FilePackr v1.1

Gestor de archivos comprimidos **nativo para macOS**: abre y explora archivos
(`.zip`, `.tar(.gz/.xz/.bz2)`, `.7z`, `.rar`, `.iso`, `.xar`/`.pkg`, `.cpio`,
`.lha`, `.cab`…) **sin descomprimirlos**, edita su contenido, extrae, previsualiza
con Quick Look, **convierte entre formatos** y **cifra con contraseña** (ZIP estándar,
interoperable con Finder/Keka/WinZip/7-Zip).

Interfaz nativa (SwiftUI + AppKit) con un navegador de ficheros tipo Finder.

---

## Novedades en 1.1

- **RAR con contraseña** — los archivos RAR cifrados ya se abren y extraen.
  Si las cabeceras van cifradas, FilePackr pide la contraseña al abrir; si solo van cifrados
  los datos, la pide al extraer. Antes no era posible.
- **Apertura rápida en discos externos** — los archivos de un disco USB o externo se listan al
  instante. Antes la app los leía enteros en memoria antes de mostrar el contenido
  (por ejemplo, un ZIP de 780 MB tardaba varios segundos).
- **Contraseña al instante** — aceptar la contraseña de un archivo cifrado ya no espera a leer
  un fichero entero (se notaba mucho en discos externos) ni bloquea la app.
- **Quick Look como en Finder** — con la previsualización abierta, ↑/↓ recorren la lista y la
  vista previa sigue a la selección; con varios ficheros seleccionados, ←/→ pasan entre ellos.
  Mientras un fichero grande se descomprime se muestra un indicador de carga (antes salía
  «null») y la app no se queda bloqueada.
- **Nueva ventana «Acerca de»** — más ancha y con los créditos y licencias de terceros.

---

## Descargar

| Archivo | Descripción |
|---|---|
| **[`FilePackr-1.1-unsigned.dmg`](https://github.com/kiko-lin/FilePackr/releases/download/v1.1/FilePackr-1.1-unsigned.dmg)** | La aplicación (imagen de disco). **5,3 MB.** Universal: Intel + Apple Silicon. |

**Requisitos:** macOS 14 (Sonoma) o superior. Compatible con Mac Intel y Apple Silicon (binario universal).

**SHA-256** del DMG (para verificar la descarga):

```
39af108012ac213c385c6bd8796dfbe20a0c5676167c4c9f9818629794dc215f
```

Verifícalo tras descargar con:

```bash
shasum -a 256 FilePackr-1.1-unsigned.dmg
```

---

## Instalación

1. Descarga **[`FilePackr-1.1-unsigned.dmg`](https://github.com/kiko-lin/FilePackr/releases/download/v1.1/FilePackr-1.1-unsigned.dmg)** y haz doble clic para montarlo.
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
| RAR (solo lectura) | `.rar` (cifrado, multivolumen) | ✅ | — |
| libarchive (solo lectura) | `.cpio` `.lha`/`.lzh` `.cab` | ✅ | — |

---

## Licencia

[GPL-3.0-or-later](https://github.com/kiko-lin/FilePackr/blob/main/LICENSE) © 2026 Francisco Javier Linares.

Con una excepción de enlace (GPL v3, §7) para **UnRAR** © Alexander L. Roshal, que FilePackr
usa para leer archivos RAR ([`LICENSE-EXCEPTION`](https://github.com/kiko-lin/FilePackr/blob/main/LICENSE-EXCEPTION)).
