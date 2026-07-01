#!/usr/bin/env bash
#
# release.sh — Empaqueta FilePackr en un .dmg. Tiene DOS modos:
#
#   scripts/release.sh              MODO NOTARIZADO (distribución pública sin fricción).
#                                    Requiere Apple Developer Program (99 USD/año):
#                                    certificado "Developer ID Application" + perfil notarytool.
#                                    Flujo: archive → export (Developer ID + hardened runtime) →
#                                    notarizar app → grapar → .dmg → notarizar .dmg → grapar →
#                                    validar con spctl. Resultado apto para cualquier Mac.
#
#   scripts/release.sh --unsigned   MODO GRATUITO (firma ad-hoc, sin notarizar).
#                                    No requiere pagar nada ni certificado. El .dmg funciona,
#                                    pero al descargarlo Gatekeeper pedirá autorizarlo la 1ª vez
#                                    (Ajustes del Sistema → Privacidad y seguridad → "Abrir
#                                    igualmente"). Ideal para GitHub Releases de un proyecto
#                                    open source. Ver docs/distribution.md.
#
# Variables de entorno (modo notarizado): SCHEME, CONFIG, TEAM_ID, NOTARY_PROFILE,
#   SKIP_NOTARIZE=1 (firma Developer ID pero NO notariza — prueba local, sin red).
#
set -euo pipefail

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- Modo -------------------------------------------------------------------
UNSIGNED=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "Argumento desconocido: $arg (usa --unsigned, o sin argumentos para notarizar)" ;;
  esac
done

# --- Config (sobrescribible por entorno) ------------------------------------
SCHEME="${SCHEME:-FilePackr}"
CONFIG="${CONFIG:-Release}"
TEAM_ID="${TEAM_ID:-969HQC97L9}"
NOTARY_PROFILE="${NOTARY_PROFILE:-FilePackr}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT/App/FilePackr.xcodeproj"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
BUILD_DIR="$ROOT/build/release"

command -v xcodebuild >/dev/null || fail "xcodebuild no encontrado (instala Xcode)."

# --- make_dmg <app> <dmg> : empaqueta la app + enlace a /Applications --------
make_dmg() {
  local app="$1" dmg="$2" staging
  staging="$(mktemp -d)"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "FilePackr" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$staging"
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ============================================================================
# MODO GRATUITO — firma ad-hoc, sin notarizar
# ============================================================================
if [ "$UNSIGNED" = "1" ]; then
  log "MODO GRATUITO (firma ad-hoc, sin notarizar)."
  DERIVED="$BUILD_DIR/dd"

  log "1/2  Compilando ($CONFIG, firma ad-hoc)…"
  xcodebuild build \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    | grep -E '^(===|▸|\*\*|error:|warning:)' || true

  APP="$DERIVED/Build/Products/$CONFIG/FilePackr.app"
  [ -d "$APP" ] || fail "No se generó la app en $APP"

  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
  DMG="$BUILD_DIR/FilePackr-$VERSION-unsigned.dmg"

  log "2/2  Construyendo ${DMG}…"
  make_dmg "$APP" "$DMG"

  log "✓ Listo (SIN notarizar): $DMG"
  cat <<'EOF'

  Este .dmg NO está notarizado. Al descargarlo, cada usuario debe autorizarlo
  la primera vez: Ajustes del Sistema → Privacidad y seguridad → "Abrir igualmente",
  o en Terminal:  xattr -d com.apple.quarantine /Applications/FilePackr.app
  Añade estas instrucciones a las notas de la release. Ver docs/distribution.md.
EOF
  exit 0
fi

# ============================================================================
# MODO NOTARIZADO — Developer ID + notarización
# ============================================================================
log "MODO NOTARIZADO (Developer ID). Para el modo gratuito: scripts/release.sh --unsigned"

ARCHIVE="$BUILD_DIR/FilePackr.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/FilePackr.app"
[ -f "$EXPORT_OPTIONS" ] || fail "Falta $EXPORT_OPTIONS"

if [ "$SKIP_NOTARIZE" != "1" ]; then
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "No hay certificado 'Developer ID Application' en el llavero. Requiere Apple Developer Program. Ver docs/distribution.md (o usa --unsigned para una release gratuita)."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "Perfil de notarización '$NOTARY_PROFILE' no configurado. Ejecuta 'xcrun notarytool store-credentials'. Ver docs/distribution.md."
fi

# --- 1. Archive -------------------------------------------------------------
log "1/7  Archivando ($CONFIG)…"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  | grep -E '^(===|▸|\*\*|error:|warning:)' || true
[ -d "$ARCHIVE" ] || fail "No se generó el archive."

# --- 2. Export (firma Developer ID + hardened runtime) ----------------------
log "2/7  Exportando .app firmada (Developer ID)…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  | grep -E '^(===|▸|\*\*|error:|warning:)' || true
[ -d "$APP" ] || fail "No se exportó FilePackr.app."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG="$BUILD_DIR/FilePackr-$VERSION.dmg"

log "    Verificando la firma…"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "Firma inválida."
codesign -dvv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|Runtime' || true

if [ "$SKIP_NOTARIZE" = "1" ]; then
  log "SKIP_NOTARIZE=1 → me salto la notarización. El .dmg NO será distribuible."
else
  # --- 3. Notarizar la app --------------------------------------------------
  log "3/7  Notarizando la app (sube a Apple y espera)…"
  APP_ZIP="$BUILD_DIR/FilePackr-app.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    || fail "Notarización de la app rechazada. Log: 'xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE'."
  rm -f "$APP_ZIP"

  # --- 4. Grapar el ticket a la app ----------------------------------------
  log "4/7  Grapando el ticket a la app…"
  xcrun stapler staple "$APP"
fi

# --- 5. Construir el .dmg ---------------------------------------------------
log "5/7  Construyendo ${DMG}…"
make_dmg "$APP" "$DMG"

if [ "$SKIP_NOTARIZE" != "1" ]; then
  # --- 6. Notarizar el .dmg -------------------------------------------------
  log "6/7  Notarizando el .dmg…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    || fail "Notarización del .dmg rechazada."

  # --- 7. Grapar el ticket al .dmg -----------------------------------------
  log "7/7  Grapando el ticket al .dmg…"
  xcrun stapler staple "$DMG"

  log "    Validando con Gatekeeper (spctl)…"
  spctl -a -vvv --type install "$DMG" 2>&1 || true
fi

log "✓ Listo: $DMG"
