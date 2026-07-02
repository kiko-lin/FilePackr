# Guion de presentación — FilePackr (TFM)

> **Formato sumario**, no guión palabra por palabra: aquí están los **conceptos clave** y las
> **explicaciones técnicas** de cada sección. Tú decides cómo lo cuentas. El orden de secciones
> = orden de diapositivas. La sección 3 (recorrido) conviene apoyarla en **grabación de pantalla**
> (el screencast es obligatorio en Fundae).

**Índice:** 1. Portada · 2. La necesidad y la propuesta · 3. Recorrido por la app · 4. Puntos
fuertes · 5. Arquitectura general · 6. Motor propio · 7. Abstracción por formato · 8. Memoria
constante · 9. Cifrado interoperable · 10. Calidad, ingeniería y seguridad · 11. Distribución ·
12. Retos y aprendizajes · 13. Futuro · 14. Cierre

---

## 1 · Portada

- **FilePackr** — gestor de archivos comprimidos, **nativo para macOS**.
- Trabajo Fin de Máster · Francisco Javier Linares · 2026.

---

## 2 · La necesidad y la propuesta

**La necesidad (el problema):**
- Trabajar con archivos comprimidos en el día a día es incómodo: las apps existentes son cajas
  negras, o te **obligan a descomprimirlo todo** solo para ver o sacar un fichero.
- Cada formato (zip, 7z, rar, iso…) suele requerir **una herramienta distinta**.
- En macOS, el propio Finder se queda corto: descomprime y poco más.

**La propuesta (qué es FilePackr):**
- Un gestor **nativo de macOS** que te deja **abrir y explorar un archivo sin descomprimirlo**, y
  **editarlo como si fuera una carpeta** (añadir, borrar, renombrar, mover).
- **Muchos formatos en una sola app**: zip, tar, 7z, rar, iso, cab…
- Además: **convertir entre formatos** y **cifrar** con estándares interoperables.
- Filosofía: **ligera, nativa y con la ergonomía del Finder**.

**Idea-fuerza:** abrir un comprimido debería ser como abrir una carpeta. FilePackr hace justo eso.

---

## 3 · Recorrido por la app y sus funcionalidades

*(Apoyar en grabación de pantalla; este es el orden natural del recorrido.)*

- **Abrir sin descomprimir** — al abrir un `.zip` solo se lee su índice (no el contenido); aparece
  al instante aunque pese varios GB.
- **Navegación tipo Finder** — árbol de carpetas, columnas ordenables (nombre, fecha, tamaño,
  comprimido) y barra de estado (nº de ficheros · tamaño · comprimido).
- **Quick Look** — previsualizar un fichero **sin extraerlo** (barra espaciadora).
- **Edición del archivo** — añadir/arrastrar, borrar, renombrar en línea, mover, crear carpetas;
  **selección múltiple** y resolución de conflictos de nombre (sobrescribir / conservar ambos /
  cancelar).
- **Extracción** — por elemento, en lote, arrastrando al Finder, o **«Extraer todo»**, con diálogo
  de conflictos.
- **Conversión de formato** — abrir en un formato y **exportar a otro** (p. ej. zip → 7z o `.tar.gz`).
- **Cifrado al exportar** — proteger con contraseña (ZipCrypto o AES-256) y, opcionalmente,
  **trocear en volúmenes**.
- **Ajustes** — tema (sistema/claro/oscuro), formato/cifrado/nivel de compresión por defecto,
  destino de extracción y política de ficheros ocultos. *(El **idioma lo determina el sistema
  operativo**; la app está traducida ES/EN, sin selector propio.)*

---

## 4 · Puntos fuertes

*(Titulares que condensan lo diferenciador, antes de entrar en lo técnico. Para una diapositiva
limpia, quedarse en 5–6.)*

- **Abrir sin descomprimir** — lee solo el índice; abre archivos de varios GB al instante.
- **Editar como una carpeta** — añadir, borrar, renombrar, mover, con selección múltiple.
- **Muchos formatos en una app** — zip, tar y variantes, 7z, rar, iso, cab…
- **Convertir entre formatos** — abrir en uno, guardar en otro.
- **Cifrado interoperable** — ZipCrypto y **AES-256**, compatible con Finder/WinZip/7-Zip.
- **Memoria constante** — trabaja en *streaming*: no carga el archivo entero en RAM (igual con
  10 MB que con 10 GB).
- **Nativa de macOS** — SwiftUI + AppKit, Quick Look, arrastrar y soltar del sistema.

**Idea-fuerza:** de esta lista, la que condiciona todo el diseño interno es **memoria constante** —
enlaza directamente con la arquitectura.

---

## 5 · Arquitectura general

La app se divide en **3 partes** con responsabilidades separadas. De abajo (lo técnico) a arriba
(lo que se ve):

**1. Motor — `ArchiveBrowser`** *(el «experto en formatos»)*
- **Qué hace:** todo el trabajo real con los archivos — **leer** un `.zip`/`.7z`/`.tar`…
  (interpretar su formato binario), **listar** su contenido, **extraer** entradas,
  **comprimir/escribir** y **cifrar/descifrar**.
- **Para qué sirve:** es la «biblioteca» que sabe de compresión. Recibe bytes y devuelve datos;
  **no sabe nada de ventanas ni de usuarios**. Aislado y reutilizable.

**2. Modelo — `FilePackrModel`** *(el «estado de la app, sin pantalla»)*
- **Qué hace:** representa **«un archivo abierto»** como algo editable: mantiene el **árbol de
  carpetas y ficheros** y **coordina las operaciones de alto nivel** (añadir, borrar, renombrar,
  guardar, extraer) dando órdenes al motor. También guarda los **ajustes**.
- **Para qué sirve:** es el puente entre «lo que el usuario quiere hacer» y «lo que el motor sabe
  hacer». Toda la lógica, **sin nada visual**.

**3. App — la interfaz (UI)** *(lo que ves y tocas)*
- **Qué hace:** ventanas, botones, el navegador visual, los diálogos (SwiftUI/AppKit), la
  traducción ES/EN y los Servicios del Finder.
- **Para qué sirve:** presentar y capturar las acciones del usuario. **Delega toda la lógica** en
  el modelo.

**Por qué se separa así (la decisión):**
- Motor + modelo viven en un **paquete Swift independiente de la interfaz** → se pueden **probar
  con `swift test` sin abrir la app**.
- Lo delicado (formato, cifrado, edición) queda **aislado y cubierto por pruebas**; la interfaz
  queda fina.

**Analogía (opcional):** el **motor** es el mecánico que sabe de motores; el **modelo** es el
gestor que lleva el estado del coche y le da órdenes al mecánico; la **app** es el mostrador donde
el cliente pide.

---

## 6 · Decisión de diseño — Motor propio

**La decisión:** escribir el motor de ZIP **desde cero en Swift puro** (leerlo, escribirlo,
comprimir/descomprimir, CRC y cifrado), en lugar de enchufar una librería ya hecha.

**Por qué a mano — es el núcleo del producto y debe encajar en la arquitectura:**
- **El ZIP es el formato central** (el que se usa el 90 % del tiempo) y sobre él se apoyan los
  diferenciadores (abrir sin descomprimir, ZIP64, streaming, cifrado interoperable). Algo tan
  crítico **no puede quedar limitado por lo que una librería externa decida exponer**.
- **Encaje con el diseño memoria-constante** — un ZIP propio se moldea **exactamente** al
  *streaming*; una librería genérica te impone sus supuestos (a menudo «cárgalo todo en memoria»).
- **Sin caja negra en el camino crítico** — código **propio, auditable y evolucionable**.
- **Testabilidad total** — al ser código propio, se puede **probar cada rincón** (casos límite,
  entradas malformadas, interoperabilidad), no solo «la fachada».
- **Dependencias mínimas** — nada de arrastrar una librería pesada para el formato principal.

**Conceptos técnicos que aparecen aquí:**
- **Leer solo el índice** — un ZIP guarda al final una «tabla de contenidos» (el *central
  directory*). Se lee **solo esa tabla**, no el contenido → abrir es instantáneo.
- **ZIP64** — extensión que permite archivos de más de 4 GB o con más de 65.535 ficheros (el ZIP
  clásico se queda corto).
- **Cifrado interoperable** — que un archivo que **tú cifras en FilePackr** se pueda **abrir en
  otras apps** (Finder, WinZip, 7-Zip) con solo la contraseña, y al revés. Lo contrario sería un
  cifrado «propietario» que solo abre tu programa. Exige implementar el cifrado **byte a byte igual
  que el estándar del ZIP**.

**El contrapunto — no reinventar lo ya resuelto:**
- **Qué es `libarchive`:** una **librería de código abierto en C**, muy probada, que lee y escribe
  **decenas de formatos**. **Viene incluida en macOS** (la usa el comando `tar`). FilePackr **la
  llama a través de un puente** (Swift ↔ C) para los formatos exóticos.
- **Por qué NO implementar RAR a mano:** es un **formato propietario y cerrado** de RARLAB — su
  algoritmo **no está documentado abiertamente** y **crear** RAR solo lo permite su herramienta de
  pago. Reimplementarlo sería muchísimo trabajo para un formato que **ni siquiera podrías escribir**
  (solo leer), y **`libarchive` ya lo lee de forma fiable**. No aporta control ni calidad → **no
  compensa**.

**El criterio (en términos de diseño):**
> Se implementa a mano **lo que es núcleo y camino crítico** (ZIP, tar, gzip, xz), para que encaje
> con la arquitectura y sea testeable. Se **delega en `libarchive`** la **larga cola** de formatos
> poco frecuentes y cerrados (7z, rar, iso, cab…). **Cada cosa en su sitio.**

---

## 7 · Decisión de diseño — Abstracción por formato

**El problema que resuelve:** con tantos formatos, el código se llenaría de «si es zip… si no si es
tar…» — imposible de mantener y ampliar. La solución es una **abstracción común**: que el resto de
la app trate **todos los formatos igual**, sin saber cuál tiene delante.

**Las tres piezas (qué es / para qué sirve):**
- **`ArchiveFormat`** — *la ficha técnica de cada formato.* Lista sus **capacidades** (¿se puede
  escribir? ¿cifra? ¿se puede trocear?) y **cómo se detecta**: por la **extensión** y por los
  ***magic bytes*** (la firma de bytes al principio del fichero) → reconoce un `.zip` aunque lo
  hayan renombrado a `.txt`.
- **`ArchiveCodec`** — *el «adaptador» que sabe manejar un formato.* Interfaz común con dos
  operaciones: **abrir/leer** y **extraer una entrada**. La app siempre llama a esas mismas dos;
  detrás, cada formato tiene su codec concreto. Quien llama **no necesita saber cuál es**.
- **`ArchiveEntry`** — *un fichero dentro del archivo, en formato «neutral».* Ruta, tamaño, fecha,
  si es carpeta… **idéntico venga de un zip, un tar o un 7z**. El modelo y la interfaz trabajan
  siempre con el mismo tipo.

**El detalle de diseño fino:**
- Los datos que **solo tiene el ZIP** (método de compresión, CRC, banderas de cifrado…) van en un
  **campo aparte y opcional**, no en la entrada neutral. Así **ningún otro formato inventa campos a
  cero**. La entrada neutral queda limpia: cada formato aporta solo lo que realmente tiene.

**El resultado:**
> **Añadir un formato nuevo** = un caso en `ArchiveFormat` + su codec + su regla de detección. **El
> resto de la app no se toca.** Diseño uniforme, extensible y sin condicionales dispersos.

---

## 8 · Decisión de diseño — Memoria constante (streaming)

**El principio rector:** **nunca cargar el archivo entero en memoria (RAM).** Gobierna todo el motor.

**Los dos conceptos:**
- **Streaming** — procesar los datos **en trozos pequeños que fluyen**: leer un poco → procesarlo →
  escribirlo → descartarlo → repetir. En vez de cargarlo todo de golpe.
- **Memoria constante** — como consecuencia, **la RAM no crece con el tamaño del archivo**: da igual
  10 MB o 10 GB, el consumo se mantiene bajo y estable.

**Por qué importa:**
- Es una app de **distribución general**: no sabes cómo de grandes serán los archivos del usuario.
- Cargarlo todo reventaría la RAM con archivos grandes (peor con varios abiertos). Diseñar para el
  **peor caso** es lo robusto.

**Cómo se aplica, en concreto:**
- **Al abrir un ZIP** — el fichero se **mapea** (*memory-mapping*: el sistema te deja acceder al
  fichero del disco como si fuera memoria, **sin copiarlo** a RAM) y se lee **solo la cola + el
  índice**. El contenido se queda en disco hasta que hace falta.
- **Al comprimir / extraer** — un bucle con un **buffer pequeño y fijo**: lee un trozo, lo
  comprime/descomprime/cifra, escribe el resultado, sigue.
- **Al guardar** — los bytes van **directos a disco**, con barra de progreso; nunca a un buffer
  gigante en memoria.

**El caso difícil (luce en una defensa) — el `.tar.gz`:**
- gzip/xz/bz2 **no permiten acceso aleatorio**: para llegar al fichero N hay que descomprimir todo
  lo anterior (0…N). No hay solución perfecta.
- Solo hay **tres palancas**: gastar **RAM/disco** (guardar lo descomprimido), gastar **CPU**
  (re-descomprimir cada vez) o **limitar el acceso**.
- **Decisión:** al abrir, **indexar** (recorrer una vez y guardar *dónde* empieza cada fichero,
  **no su contenido**); para «extraer todo», **una sola pasada** ordenada por posición.
- **Resultado:** RAM mínima y el flujo común cuesta **un único recorrido**. Un **compromiso
  consciente y documentado**, no una bala de plata.

---

## 9 · Decisión de diseño — Cifrado interoperable

**La decisión:** implementar los **estándares de cifrado del propio formato ZIP**, para que los
archivos cifrados **se abran en cualquier herramienta** (no un cifrado propietario).

**Los dos modos (y su compromiso):**
- **ZipCrypto** — el cifrado clásico del ZIP. **Universal** pero **inseguro** (roto hace años). Se
  ofrece por compatibilidad y se **marca explícitamente como débil**.
- **AES-256 (WinZip AE-2)** — el estándar **moderno y seguro**. El recomendado.

**Qué significan las piezas del AES-256 (conciso):**
- **AES-256** — cifrado simétrico fuerte (la misma contraseña cifra y descifra).
- **La clave se deriva de la contraseña con PBKDF2** — forma estándar de convertir una contraseña
  en una clave, **deliberadamente lenta** para dificultar la fuerza bruta.
- **Autenticado con HMAC** — además de cifrar, verifica que **los datos no se han manipulado** y que
  **la contraseña es correcta**.

**Lo difícil no es cifrar — es ser interoperable:**
- Que se abra en Finder/WinZip/7-Zip (y al revés) exige clavar **cada detalle del formato byte a
  byte**. Ejemplo: WinZip usa AES en **modo CTR con un contador propio** (empieza en 1, en
  *little-endian*), distinto del CTR «de manual». Si no lo replicas exacto, **no abre en otras apps**.

**La parte «bien hecha» — interoperabilidad demostrada, no supuesta:**
- Cubierta por **pruebas automáticas**, en **ambos sentidos**:
  - **ZipCrypto** ↔ contra el `zip`/`unzip` del sistema.
  - **AES-256** ↔ contra **`pyzipper`** (Python): lo que cifra FilePackr lo abre pyzipper, y
    viceversa.
- **Si se rompe la compatibilidad, un test se pone en rojo.**

---

## 10 · Calidad, ingeniería y seguridad

Un proyecto de este tamaño (~8.000 líneas de Swift) no se sostiene sin **red de seguridad** ni sin
cuidar la **seguridad frente a archivos maliciosos**.

### Calidad e ingeniería
- **Pruebas automatizadas** — cerca de **200 tests** (≈143 del motor + ≈57 del modelo), con un solo
  `swift test`. Cubren lo delicado: formatos, cifrado, edición del árbol.
- **Integración continua (GitHub Actions)** — en **cada cambio** se ejecutan **todas las pruebas** y
  se **compila la app**. Si algo se rompe, el cambio **queda en rojo** antes de entrar en `main`.
- **Auditorías de arquitectura** — revisiones periódicas (clases que crecen de más, código
  muerto…) que **guían refactors**. La calidad se mantiene a propósito.

### Seguridad
- **Extracción segura — defensa contra *Zip-Slip* (path traversal).** Un archivo malicioso puede
  incluir una entrada con ruta tipo `../../algo` para que, al extraerla, **escriba fuera de la
  carpeta destino**. Defensa: se valida que **cada entrada aterrice dentro del destino** — con
  **dos comprobaciones** y un **test de regresión**.
- **Defensa contra *bombas de descompresión* (*zip bombs*).** Un archivo **diminuto** que al
  descomprimirse se **hincha a gigas** (ratios de 10⁵–10⁹:1, como `42.zip` ≈ 10⁹:1) para agotar RAM
  o llenar el disco. Defensa en **dos capas**:
  1. **Por declaración (ZIP)** — el tamaño que **anuncia la cabecera** se valida contra el máximo
     físicamente posible de DEFLATE (~1032:1); si «miente», se **rechaza** antes de reservar memoria.
  2. **En streaming (gzip/xz/bzip2)** — como no traen tamaño previo, se vigila la **salida
     acumulada**: si supera `entrada × 10.000 + 64 MiB`, la descompresión **aborta**. Holgado para
     datos legítimos muy comprimibles, pero corta las bombas reales.
- **Manejo de contraseñas** — la clave se mantiene **solo en memoria** mientras el archivo está
  abierto y **no se persiste**: al cerrar y reabrir, se vuelve a pedir.
- **Cifrado fuerte por defecto** — se ofrece **AES-256** como opción segura y el ZipCrypto clásico
  se **marca como inseguro** para que el usuario elija con conocimiento.
- **Pensada para archivos no confiables** — el motor asume que puede abrir archivos de **origen
  desconocido** sin comprometer el sistema.
- **Endurecimiento del binario (*hardened runtime*)** — protección de macOS que **blinda el
  proceso**: bloquea la **inyección de código**, impide el **secuestro de librerías**, restringe la
  memoria escribible-y-ejecutable, e impide que un depurador se enganche sin permiso. Es **requisito
  de Apple para notarizar**.

---

## 11 · Distribución

*(Siendo una app de escritorio, su «despliegue» es distinto al de una web.)*
- **Empaquetado en `.dmg`** — con un **script de release reproducible** (mismo resultado cada vez).
- **Dos vías de firma:**
  - **Gratuita** — firma *ad-hoc*, sin coste; el usuario la autoriza la primera vez (Gatekeeper).
  - **Notarizada** — firma **Developer ID** + **notarización** de Apple → doble clic sin avisos
    (requiere el Apple Developer Program de pago).
- **Endurecimiento** — *hardened runtime* activado y pipeline **listo para firmar y notarizar**.
- **Distribución directa** — fuera de la Mac App Store; y al ser **open source**, cualquiera puede
  **compilarla desde el código**.
- **Publicación** — la versión final se ofrece como un **GitHub Release descargable** (el
  equivalente al «despliegue en funcionamiento» que pide el TFM para una app de escritorio).

---

## 12 · Retos y aprendizajes

**Retos técnicos:**
- **Formatos binarios byte a byte** — en el cifrado interoperable y en ZIP64, **un byte mal puesto**
  no da error claro: el archivo **no abre en otra app**. Exige precisión y verificación contra
  herramientas reales.
- **Streaming con acceso aleatorio** — conciliar «memoria constante» con saltar a cualquier entrada
  de un `.tar.gz` (el caso difícil): no hay solución perfecta, hay que elegir un compromiso.
- **Anticipar entradas maliciosas** — diseñar la extracción asumiendo que el archivo puede ser
  hostil (Zip-Slip, bombas), no solo que «vendrá bien formado».
- **Integrar AppKit dentro de SwiftUI** — el navegador (`NSOutlineView`), Quick Look y el
  arrastrar-y-soltar del sistema son de AppKit y hay que **encajarlos en una app SwiftUI**.

**Aprendizajes (a futuros proyectos):**
- **Diseñar para lo desconocido** — asumir el **peor caso** (tamaños de archivo) evita sorpresas.
- **Verificar contra el mundo real, no contra uno mismo** — probar la interoperabilidad frente a
  `zip`/`unzip` y `pyzipper` atrapa fallos que probar «contra tu propia app» jamás vería.
- **Separar lógica de interfaz paga** — testear el motor sin abrir la app acelera y da confianza.
- **Saber cuándo implementar y cuándo delegar** — motor propio (ZIP) vs. `libarchive` (formatos
  exóticos) fue una decisión de ingeniería consciente.

---

## 13 · Futuro

- **Cifrado al escribir en más formatos** — hoy **solo el ZIP cifra** al guardar; el 7z se puede
  **abrir cifrado** pero su escritor guarda en claro. Extenderlo es la mejora más natural.
- **Rendimiento del cifrado** — optimizar las rutas que hoy trabajan byte a byte (punto ya
  identificado en las auditorías).
- **Más formatos y motores** — aprovechando la abstracción por formato (añadir uno es «un caso + su
  codec + su detección»).
- **Distribución sin fricción** — completar la **notarización** con una cuenta del Apple Developer
  Program, para que el `.dmg` abra con doble clic sin aviso de Gatekeeper.
- **Pulido de integración con el sistema** — afinar detalles finos del arrastre y de los Servicios
  del Finder.

**Idea de cierre:** el diseño (abstracción por formato + arquitectura en capas) hace que estas
mejoras sean **incrementales**, no reescrituras — señal de que las decisiones de fondo fueron
acertadas.

---

## 14 · Cierre

**Recapitulación (una frase):**
> FilePackr es una **utilidad real y nativa de macOS** en la que se aplican de forma tangible los
> pilares del máster: **arquitectura** (capas separadas, motor propio), **diseño** (abstracción por
> formato, memoria constante), **seguridad** (extracción segura, cifrado interoperable) y
> **calidad** (≈200 tests, CI).

**Enlaces (para la diapositiva y el formulario Fundae):**
- **Código** — `github.com/kiko-lin/FilePackr`
- **Descarga** — el GitHub Release con el `.dmg`
- **Presentación** — estas slides
- **Documentación** — el `README` y `docs/` del repositorio

**Gracias.**

---

## Apéndice · Notas de producción del vídeo

- **Captura de pantalla obligatoria** (Fundae): graba la pantalla durante toda la explicación.
  Mostrar tu cara con la webcam es **opcional**.
- Ten listos de antemano: un `.zip` grande de demo, ficheros sueltos para arrastrar y una contraseña
  de ejemplo. Ensaya el paso de **exportar a 7z + AES-256** para que salga fluido.
- Reparto orientativo: ~40 % recorrido/demo, ~50 % arquitectura y decisiones, ~10 % calidad/cierre.
- Si te alargas, lo más recortable es parte de **11 (Distribución)** y **13 (Futuro)**.
- Grabación en macOS: **QuickTime Player** (Archivo → Nueva grabación de pantalla) o `⇧⌘5`.
