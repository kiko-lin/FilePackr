# Pruebas manuales — FilePackr

Lista de verificación de las funciones que **no** cubren los tests automáticos del motor
(`swift test`, 85+ en verde): UI/UX, integración con el Finder, interoperabilidad real,
ciclo de vida de la app y regresiones de extremo a extremo.

Marca 🔴 lo crítico/arriesgado (toca el corazón del motor o el hilo principal); el resto es
UI de menor riesgo. Relanza siempre con **⌘R** tras compilar: una instancia vieja muestra el
comportamiento anterior.

---

## 0. Preparación de datos de prueba

```bash
# Carpeta con ocultos/sistema + un visible
mkdir -p ~/Desktop/PruebaPackr/carpeta/sub
touch ~/Desktop/PruebaPackr/carpeta/.DS_Store \
      ~/Desktop/PruebaPackr/carpeta/._recurso \
      ~/Desktop/PruebaPackr/carpeta/.gitignore \
      ~/Desktop/PruebaPackr/carpeta/sub/.DS_Store \
      ~/Desktop/PruebaPackr/carpeta/visible.txt

# Fichero grande para probar streaming/progreso/cancelar (~700 MB)
# Nota: con dd usa "$HOME" en of=, NO ~ (la tilde no se expande tras of=).
mkdir -p ~/Desktop/PruebaPackr
dd if=/dev/urandom of="$HOME/Desktop/PruebaPackr/grande.bin" bs=1m count=700

# Carpeta con muchos ficheros del mismo tipo (para ordenar por "Clase")
mkdir -p ~/Desktop/PruebaPackr/muchos
for i in $(seq 1 500); do touch ~/Desktop/PruebaPackr/muchos/v$i.mov; done
```

---

## 1. Nivel de compresión 🔴

El cambio más delicado: la escritura de todos los formatos comprimibles pasa por zlib /
liblzma / libbz2 (no por el framework de Apple). Un fallo aquí sería silencioso.

- [ ] **1.1 · El nivel se nota.** Comprime una carpeta de texto/código a cada formato en
  **Rápido** y **Máximo** y compara el tamaño en la barra de estado. Máximo ≤ Rápido en:
  `zip`, `gz`/`tar.gz`, `xz`/`tar.xz`, `bz2`/`tar.bz2`, `7z`. El selector de nivel aparece
  para todos (incluido **zip**, el de por defecto).
- [ ] **1.2 · Interoperabilidad** (que otras apps lean lo nuestro). Para cada archivo de 1.1:
  - Doble clic en el **Finder** (Utilidad de Archivo) → extrae idéntico.
  - Terminal: `unzip -t`, `gzip -t`, `xz -t`, `bzip2 -t`, `7z t` (si tienes p7zip/Keka).
  - Sin avisos de corrupción.
- [ ] **1.3 · Round-trip** en FilePackr: abre lo guardado en 1.1 y extrae → contenido idéntico.
- [ ] **1.4 · Fichero grande / memoria.** Comprime `grande.bin` a `xz` y `zip` en **Máximo**.
  La memoria en Monitor de Actividad se mantiene estable (streaming), no se dispara.
- [ ] **1.5 · Nivel + cifrado.** zip **Fuerte (AES-256)** + **Máximo** → abrir con contraseña y extraer.
- [ ] **1.6 · Nivel + volúmenes.** Formato con división + **Máximo** → reensamblar y extraer.
- [ ] **1.7 · Default en Ajustes → hoja.** Cambia el nivel por defecto en Ajustes; el selector de
  Guardar/Exportar viene preseleccionado con él.
- [ ] **1.8 · Guardar vs Exportar.** Guarda con **Máximo**, edita, pulsa **Guardar** (sin hoja) →
  recuerda el nivel. Exportar no cambia el documento activo.
- [ ] **1.9 · Bordes.** Fichero vacío y carpeta con un único fichero diminuto a `gz`/`xz`/`bz2` →
  no peta, extrae bien.
- [ ] **1.10 · Sin selector donde no toca.** `tar` puro y `rar` abierto → el selector de nivel no aparece.

---

## 2. Extracción: segundo plano, progreso y cancelar 🔴

- [ ] **2.1 · Arrastrar al Finder sin bloqueo.** Abre un zip grande, arrastra un fichero de
  varios cientos de MB al Finder/Escritorio. La app **responde** (sin bola de colores), la
  imagen de arrastre se suelta enseguida, aparece la **tarjeta de progreso**.
- [ ] **2.2 · Botón Extraer.** Selecciona un fichero grande, pulsa Extraer → tarjeta de progreso,
  barra que **avanza por bytes** (no salta de 0 a 100), con el nombre del fichero debajo.
- [ ] **2.3 · Cancelar (botón).** Durante 2.1 o 2.2, pulsa **Cancelar** (rojo) → para al instante
  y **no** deja el fichero a medias en el destino.
- [ ] **2.4 · Cerrar durante la extracción.** Pulsa la **X** de la ventana (o ⌘W) mientras extrae
  → sale un aviso **¿Cerrar la ventana?** (Cancelar / Continuar):
  - **Cancelar** → no cierra, sigue extrayendo.
  - **Continuar** → cancela la extracción y cierra.
- [ ] **2.5 · El proceso no queda vivo.** Cierra la ventana a media extracción. En Monitor de
  Actividad **no** debe quedar `FilePackr` descomprimiendo de fondo.
- [ ] **2.6 · Quick Look de fichero grande.** Selecciona un fichero grande, pulsa **barra
  espaciadora** → no congela la app; la vista previa aparece cuando esté lista. Los pequeños
  (≤16 MB) se previsualizan al instante, sin parpadeo.

---

## 3. Tarjeta de progreso (UI)

- [ ] **3.1 · Tarjeta flotante.** Al extraer, "Extrayendo…" es una **tarjeta compacta centrada**
  con la app atenuada detrás (no tapa toda la ventana).
- [ ] **3.2 · Sin agrandamiento.** La caja **no crece** cuando aparece el nombre del fichero
  (la línea está reservada).
- [ ] **3.3 · Botón rojo con borde** (no relleno, no sombra).
- [ ] **3.4 · Semáforos visibles** (cerrar/minimizar/zoom no se ocultan durante el progreso).

---

## 4. Navegador de archivos

- [ ] **4.1 · Ordenar sin cuelgue** 🔴. Abre la carpeta `muchos` (500 `.mov`) comprimida. Haz clic
  en la cabecera **"Clase"** varias veces (asc/desc). **No** debe colgarse. Prueba también
  Nombre, Fecha, Tamaño, Comprimido.
- [ ] **4.2 · Doble clic en carpeta** → la pliega/despliega.
- [ ] **4.3 · Renombrar sigue funcionando** (menú contextual / Intro). Si el doble clic sobre el
  **nombre** de una carpeta abre el renombrado en vez de plegar, anotarlo.
- [ ] **4.4 · Imagen de arrastre = solo el icono.** Al arrastrar un fichero (o varios), se ve el
  **icono** (estilo Finder), no el snapshot de la fila entera con todas las columnas.

---

## 5. Archivos ocultos al añadir

Con la carpeta `carpeta` (tiene `.DS_Store`, `._recurso`, `.gitignore`, `sub/.DS_Store`):

- [ ] **5.1 · Excluir archivos de sistema** (por defecto): entran `visible.txt`, `.gitignore` y
  `sub`; **no** los `.DS_Store`/`._*`. Aviso en barra de estado: *"Se excluyeron N…"* (~5 s).
- [ ] **5.2 · Incluir todo**: entran también los `.DS_Store`/`._*`, sin aviso.
- [ ] **5.3 · Excluir todos los ocultos**: no entra ningún nombre que empiece por `.`.
- [ ] **5.4 · Override explícito.** Arrastra **directamente** un `.DS_Store` suelto (no dentro de
  carpeta) → entra (la elección explícita gana).
- [ ] **5.5 · El visor no oculta.** Lo añadido con "Incluir todo" se ve íntegro en la lista.
- [ ] **5.6 · El aviso no se queda pegado.** Arrastra varias veces seguidas → el aviso se renueva,
  no parpadea ni se queda fijo.

---

## 6. Asociación de formatos en el Finder

- [ ] **6.1 · Primer arranque.** (Build limpia / prefs borradas.) Sale el diálogo de "compresor por
  defecto"; "Sí" abre Ajustes › Archivos.
- [ ] **6.2 · Marcar/desmarcar formatos** en la pestaña Archivos y comprobar en el Finder
  ("Abrir con") que FilePackr aparece para los marcados.
- [ ] **6.3 · Checkbox** separado del icono/nombre, se pulsa bien.

---

## 7. Regresión (que lo de siempre siga bien)

- [ ] **7.1 · Extraer** uno / varios / **todo**, con conflictos de nombre
  (Sobrescribir / Conservar ambos / Cancelar).
- [ ] **7.2 · Cifrado de lectura**: abrir un zip con contraseña.
- [ ] **7.3 · Cambios sin guardar**: aviso de 3 botones al cerrar (Guardar / Cerrar sin guardar / Cancelar).
- [ ] **7.4 · Idioma y Tema** en caliente.
- [ ] **7.5 · Abrir desde el Finder** (doble clic en un archivo asociado).
- [ ] **7.6 · ⌘Q** con cambios sin guardar → aviso unificado.

---

## Prioridad si vas con poco tiempo

**1.1 → 1.2 → 1.3 → 1.4** (zlib/liblzma, lo único que toca el núcleo de compresión) y
**2.1 → 2.3 → 2.5** (segundo plano + cancelar + no dejar proceso vivo) y **4.1** (cuelgue al
ordenar). El resto es UI de menor riesgo.
