# Distribución

FilePackr se distribuye de forma **directa** (fuera de la Mac App Store). Hay dos vías,
según tengas o no el **Apple Developer Program** (99 USD/año):

| Vía | Coste | Fricción para el usuario | Cómo |
|---|---|---|---|
| **Gratuita** (ad-hoc, sin notarizar) | 0 € | Debe autorizar la app la 1ª vez | `scripts/release.sh --unsigned` |
| **Notarizada** (Developer ID) | 99 USD/año | Ninguna (doble clic y listo) | `scripts/release.sh` |

También, al ser **open source (GPL-3.0)**, cualquiera puede **compilar la app desde el
código** (abrir `App/FilePackr.xcodeproj` en Xcode y ⌘R); una app compilada por el propio
usuario corre sin avisos.

---

## Vía gratuita (sin pagar): `.dmg` ad-hoc

```bash
scripts/release.sh --unsigned
```

Genera `build/release/FilePackr-<versión>-unsigned.dmg` con la app firmada **ad-hoc**
(la firma mínima que exige Apple Silicon; no requiere certificado ni cuenta de pago).

**El binario funciona**, pero como no está notarizado, al descargarlo macOS lo pone en
cuarentena y Gatekeeper lo bloquea la primera vez. Incluye **estas instrucciones** en las
notas de la release para tus usuarios:

> **Cómo abrir FilePackr la primera vez** (aparece un aviso de "desarrollador no
> verificado" porque la app es gratuita y no está notarizada por Apple):
> 1. Arrastra FilePackr a la carpeta *Aplicaciones*.
> 2. Intenta abrirla (doble clic). Saldrá un aviso; ciérralo.
> 3. Ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el aviso sobre
>    FilePackr y pulsa **"Abrir igualmente"**. Confirma.
>
> Alternativa por Terminal (quita la marca de cuarentena de golpe):
> ```bash
> xattr -d com.apple.quarantine /Applications/FilePackr.app
> ```

> En macOS 15 (Sequoia) Apple retiró el atajo de Control-clic → Abrir; ahora hay que
> pasar sí o sí por *Ajustes del Sistema → Privacidad y seguridad*.

---

## Vía notarizada (con Apple Developer Program): `.dmg` sin fricción

Un `.dmg` firmado con **Developer ID Application** y **notarizado** por Apple, de modo que
Gatekeeper lo acepta en cualquier Mac sin avisos.

> La Mac App Store queda descartada a propósito: la app usa la licencia **GPL-3.0**,
> incompatible en la práctica con los términos de la App Store, y el sandbox de la
> Store exigiría re-cablear el acceso a ficheros (security-scoped bookmarks). Ver el
> punto «Distribución» en [`../AGENTS.md`](../AGENTS.md).

## Qué ya está hecho en el repo

- **Hardened Runtime** activado en el target (`ENABLE_HARDENED_RUNTIME = YES`),
  requisito de la notarización. La app no necesita *entitlements* de excepción:
  no lanza subprocesos, no hace `dlopen` ni JIT, y solo enlaza librerías del
  **sistema** (`libarchive`, `libz`, `libbz2`, `liblzma`), que el runtime endurecido
  permite sin excepciones. Por eso **no hay fichero `.entitlements`** (no hace falta).
- **App Sandbox desactivado** (`ENABLE_APP_SANDBOX = NO`): correcto para distribución
  directa. Solo haría falta reactivarlo para la App Store.
- **Copyright** en el «Acerca de» (`INFOPLIST_KEY_NSHumanReadableCopyright`).
- Script de release: [`../scripts/release.sh`](../scripts/release.sh) +
  [`../scripts/ExportOptions.plist`](../scripts/ExportOptions.plist).

## Prerrequisitos (una sola vez)

1. **Membresía del Apple Developer Program** (99 USD/año). Sin ella no se puede emitir
   el certificado Developer ID ni notarizar.

2. **Certificado «Developer ID Application»** en el llavero. Desde Xcode:
   *Settings → Accounts → (tu cuenta) → Manage Certificates → `+` → Developer ID
   Application*. Comprueba que está:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. **Contraseña específica de app** para notarizar (no tu contraseña de Apple ID):
   créala en <https://appleid.apple.com> → *Iniciar sesión y seguridad → Contraseñas
   específicas de app*.

4. **Guardar el perfil de notarización** en el llavero (una vez); el script lo usa por
   nombre (`FilePackr` por defecto):

   ```bash
   xcrun notarytool store-credentials "FilePackr" \
     --apple-id "kikolincor@gmail.com" \
     --team-id 969HQC97L9 \
     --password "xxxx-xxxx-xxxx-xxxx"   # la contraseña específica de app
   ```

   > El Team ID `969HQC97L9` es el de la cuenta `kikolincor@gmail.com` (el que aparece
   > entre paréntesis en `security find-identity -v`). Si notarytool responde con un 403
   > *"Invalid or inaccessible developer team ID"*, es que ese Apple ID no está enrolado
   > en el **Apple Developer Program de pago** — sin él no se puede notarizar (usa la vía
   > gratuita `--unsigned`).

## Publicar una versión

1. **Sube la versión** si toca: `MARKETING_VERSION` (p. ej. `1.0` → `1.1`) y
   `CURRENT_PROJECT_VERSION` (número de build) en el target de Xcode.

2. **Ejecuta el script**:

   ```bash
   scripts/release.sh
   ```

   Hace, en orden: `archive` → `exportArchive` (firma Developer ID + hardened runtime)
   → notariza la `.app` → **grapa** el ticket a la app → construye el `.dmg` → notariza
   el `.dmg` → **grapa** el `.dmg` → valida con `spctl`. El resultado queda en
   `build/release/FilePackr-<versión>.dmg`.

3. **Prueba en frío** (idealmente en otro Mac o con una cuenta limpia): descarga el
   `.dmg`, ábrelo, arrastra FilePackr a *Aplicaciones* y lánzalo. No debe aparecer el
   aviso de «desarrollador no identificado».

### Variantes útiles

- `SKIP_NOTARIZE=1 scripts/release.sh` — firma y empaqueta **sin** notarizar (prueba
  local rápida, sin red). El `.dmg` resultante **no** es distribuible.
- `NOTARY_PROFILE=OtroNombre scripts/release.sh` — usa otro perfil de notarización.

## Publicar en GitHub Releases

Con el `.dmg` notarizado y grapado:

```bash
gh release create v<versión> build/release/FilePackr-<versión>.dmg \
  --title "FilePackr <versión>" --notes "…"
```

## Solución de problemas

- **La notarización se rechaza**: mira el detalle con
  `xcrun notarytool log <submission-id> --keychain-profile FilePackr`. Causas típicas:
  falta el hardened runtime (ya está puesto), un binario sin firmar, o un timestamp
  seguro ausente (xcodebuild lo añade solo).
- **`spctl` dice «rejected»**: normalmente el ticket no se grapó; reejecuta el script o
  `xcrun stapler staple build/release/FilePackr-<versión>.dmg`.
- **No aparece el certificado**: revisa que la cuenta del Apple Developer Program esté
  activa y el certificado descargado en *este* Mac (los certificados no se sincronizan
  entre máquinas salvo que exportes el `.p12`).
