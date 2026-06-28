# Tests pendientes — verificación en GUI

Lista de pruebas **aún por realizar** sobre el trabajo reciente. El agente solo compila y corre
los tests del **motor** (`swift test`, 93 verdes) y los del **modelo** (`FilePackrTests`, ⌘U); la
parte de **GUI / Finder / sistema** la verificas tú en Xcode (**⌘R**) y marcas aquí.

> Relanza siempre con **⌘R** tras compilar: una instancia vieja muestra el comportamiento anterior.
> La lista general (no específica de esta tanda) está en [`pruebas-manuales.md`](pruebas-manuales.md).

## 0. Preparación de datos

```bash
# Fichero grande para que la compresión/extracción dure y dé tiempo a cancelar:
mkfile 1g ~/Desktop/grande.bin          # o: dd if=/dev/urandom of=~/Desktop/grande.bin bs=1m count=800
# Carpeta con varios elementos para lotes de extracción (usa cualquier archivo con muchas entradas).
```

---

## 1. i18n — seguir el idioma del sistema

- [ ] Con el **Mac (o la app)** en **español** → toda la app **y la barra de menús de macOS**
      (menú con el nombre de la app, Archivo, Edición, Ventana, Ayuda) salen en español.
- [ ] En **inglés** → todo en inglés.
- [ ] Columna **«Clase»** del navegador y paneles del sistema (abrir/guardar) siguen el idioma del SO.
- [ ] **Ya no** hay selector de idioma dentro de Ajustes.
  - Probar el idioma por app sin cambiar todo el Mac: Ajustes del Sistema → General → Idioma y
    región → (Apps) → **+** → FilePackr → Español.

## 2. Servicios del Finder («Abrir en FilePackr» / «Descomprimir aquí»)

> Los Servicios solo aparecen tras **registrar el `.app`** con Launch Services:
> instalar en `/Applications` o `/System/Library/CoreServices/pbs -update` (a veces reiniciar sesión).

- [ ] Clic derecho en un archivo comprimido en el Finder → **«Abrir en FilePackr»** lo abre.
- [ ] Clic derecho → **«Descomprimir aquí»** extrae a una carpeta hermana y la revela en el Finder.
- [ ] «Descomprimir aquí» sobre un archivo **cifrado** → abre la app para pedir la contraseña.
- [ ] Con el sistema en español, los títulos del menú de Servicios salen **traducidos**.
- [ ] Selección **múltiple** de archivos → ambos servicios funcionan con todos.

## 3. Título de ventana + numeración «Sin título N»

- [ ] Abre **varias** ventanas nuevas (vacías) → el menú **Ventana** las distingue como
      «Sin título 1», «Sin título 2», «Sin título 3»…
- [ ] Abre/guarda un archivo → su título pasa al **nombre del archivo** (p. ej. `foo.zip`).
- [ ] Cierra una ventana «Sin título 2» y abre otra nueva → reutiliza el número libre.

## 4. Extracción — «Última carpeta usada»

- [ ] Ajustes → Extraer en = **«Última carpeta usada»**.
- [ ] Extrae algo a una carpeta concreta (Elegir…) → la siguiente extracción propone **esa** carpeta.
- [ ] «Extraer todo» también actualiza la última carpeta usada.

## 5. Guardar/Exportar — «Último usado» (formato/cifrado/nivel)

- [ ] Ajustes → Formato por defecto = **«Último usado»** (primera opción).
- [ ] Guarda un documento nuevo como **TAR.GZ** → el siguiente documento nuevo prerrellena **TAR.GZ**.
- [ ] Igual con **Cifrado** y **Nivel de compresión** («Último usado»).
- [ ] Ajustes → Formato = **ZIP fijo** → siempre ZIP aunque exportes otra cosa.
- [ ] La **contraseña** NO se recuerda (siempre vacía al abrir la hoja).
- [ ] Exportar y Guardar comparten la misma memoria de «último usado».

## 6. Cancelación real de compresión 🔴

- [ ] Nuevo documento → añade `grande.bin` → **Guardar como ZIP (nivel Máximo)** → durante la barra,
      pulsa **Cancelar**. Esperado: para en ~1 s; **no** aparece el `.zip` en el destino; la carpeta
      no queda con ningún `.filepackr.work` (`ls -la ~/Desktop/.*filepackr.work` → nada).
- [ ] Repite cancelando para **TAR.GZ**, **7z** y **GZ** (cubre compresores, libarchive y un-fichero).
- [ ] **Re-guardar**: abre un ZIP existente, edítalo, Guardar y **cancela** a mitad → el ZIP original
      sigue **intacto** (vuelve a abrirlo).

## 7. Cerrar la ventana mientras guarda/exporta 🔴

- [ ] Empieza a guardar `grande.bin` → pulsa el botón **rojo de cerrar** → aviso «se cancelará el
      guardado» → **Continuar** cierra y cancela; **Cancelar** mantiene y sigue.
- [ ] Tras cerrar a mitad, no queda ningún `.filepackr.work` en la carpeta.
- [ ] Mientras guarda, intentar **Guardar** otra vez (p. ej. ⌘S) no lanza un segundo guardado.

## 8. Limpieza de extracciones parciales (lote)

- [ ] Selecciona **varios** elementos grandes → Extraer → **Cancelar (X)** a media tanda →
      aviso **Conservar / Eliminar**:
  - [ ] **Eliminar** → tarjeta **«Limpiando…»** → los ya extraídos desaparecen del disco.
  - [ ] **Conservar** → siguen ahí.
- [ ] Provoca un **conflicto** de nombre y pulsa **Cancelar** en ese diálogo → mismo aviso Conservar/Eliminar.
- [ ] **Cerrar la ventana** durante una extracción en lote → se cancela y cierra; los ya extraídos
      **quedan** en disco (sin prompt — alcance acordado).

## 9. Limpieza defensiva de `.work` huérfanos

```bash
touch -t 202001010000 ~/Desktop/.viejo.filepackr.work   # simula un resto de cierre forzado (>1 h)
```
- [ ] Abre cualquier archivo de `~/Desktop` en FilePackr → ese `.work` viejo se **borra**.
- [ ] Un `.filepackr.work` **reciente** (de un guardado en curso en esa carpeta) **no** se toca.

## 10. Barra de progreso de compresión + nombre de archivo

- [ ] Al comprimir `grande.bin` a **ZIP**, el overlay muestra **barra determinada** que avanza +
      el **nombre** `grande.bin` (ya no un spinner indeterminado).
- [ ] Igual para **un fichero** gz/xz/bz2, **7z** (libarchive) y **tar/tar.gz/tar.xz/tar.bz2**
      (en tar el nombre cambia por fichero).
- [ ] Un archivo con **varias** entradas → la barra avanza y el nombre va cambiando por entrada.

## 11. (Pendiente antiguo) Flujos del refactor de auditoría

- [ ] **Añadir con conflicto** de nombre → Sobrescribir / Conservar ambos / Cancelar.
- [ ] **Extraer en lote** con conflictos → Sobrescribir / Conservar ambos / Cancelar; caso «React /
      React 2 / React 3» con «conservar ambos» no deja dos ficheros con el mismo nombre.
- [ ] **Guardar/Exportar** en cada formato (zip, tar.gz, 7z, gz…) produce el archivo correcto (ábrelo).
- [ ] Una vez validado todo → `git push` (lo hace el usuario; el agente no tiene red).
