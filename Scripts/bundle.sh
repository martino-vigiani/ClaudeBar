#!/usr/bin/env bash
# bundle.sh — impacchetta `swift build` in ClaudeBar.app (menu bar agent, LSUIElement).
#
# SPM produce un eseguibile, non un .app. Questo script crea la struttura
# ClaudeBar.app/Contents/{MacOS,Resources} + Info.plist e ci copia il binario ClaudeBarApp.
# Zero dipendenze esterne, niente signing (uso personale; ad-hoc opzionale via env).
#
# Override via env (rebrand / debug a costo zero):
#   CLBAR_CONFIG        release | debug          (default: release)
#   CLBAR_BUNDLE_ID     bundle identifier        (default: com.subralabs.claudebar[.debug])
#   CLBAR_DISPLAY_NAME  CFBundleDisplayName       (default: ClaudeBar)
#   CLBAR_PRODUCT_NAME  CFBundleName / eseguibile (default: ClaudeBar)
#   CLBAR_VERSION       CFBundleShortVersionString(default: 0.1.0)
#   CLBAR_BUILD         CFBundleVersion           (default: short git sha o 1)
#   CLBAR_SIGN          1 → firma ad-hoc (codesign -s -)  (default: 0)
#
# Uso: Scripts/bundle.sh            → release
#      CLBAR_CONFIG=debug Scripts/bundle.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CONFIG="${CLBAR_CONFIG:-release}"
DISPLAY_NAME="${CLBAR_DISPLAY_NAME:-ClaudeBar}"
PRODUCT_NAME="${CLBAR_PRODUCT_NAME:-ClaudeBar}"
VERSION="${CLBAR_VERSION:-0.1.0}"
BUILD_NUMBER="${CLBAR_BUILD:-$(git rev-parse --short HEAD 2>/dev/null || echo 1)}"

# Bundle id: default release, .debug per la config debug → istanza separata.
if [[ -n "${CLBAR_BUNDLE_ID:-}" ]]; then
  BUNDLE_ID="$CLBAR_BUNDLE_ID"
elif [[ "$CONFIG" == "debug" ]]; then
  BUNDLE_ID="com.subralabs.claudebar.debug"
else
  BUNDLE_ID="com.subralabs.claudebar"
fi

echo "==> Building ClaudeBarApp ($CONFIG)…"
swift build -c "$CONFIG" --product ClaudeBarApp

# Risolve il path del binario chiedendolo a SwiftPM (autorevole per qualunque build system:
# il layout legacy .build/<arch>-apple-macosx/<conf>/ e quello swiftbuild .build/out/Products/
# divergono, e un fallback hardcoded rischia di pescare un binario STALE di una build vecchia).
BIN_DIR=$(swift build -c "$CONFIG" --product ClaudeBarApp --show-bin-path)
BIN="$BIN_DIR/ClaudeBarApp"
if [[ ! -f "$BIN" ]]; then
  echo "ERRORE: binario ClaudeBarApp non trovato in $BIN_DIR dopo la build." >&2
  exit 1
fi
# Guardia anti-stale: il binario deve essere più recente di qualunque sorgente.
NEWEST_SRC=$(find Sources -name '*.swift' -newer "$BIN" | head -1)
if [[ -n "$NEWEST_SRC" ]]; then
  echo "ERRORE: binario più vecchio di $NEWEST_SRC — build stale, non bundlo." >&2
  exit 1
fi

APP="$ROOT/$DISPLAY_NAME.app"
echo "==> Assemblo ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$PRODUCT_NAME"
chmod +x "$APP/Contents/MacOS/$PRODUCT_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${PRODUCT_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>it</string></array>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${PRODUCT_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Subra Labs.</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Copia eventuali risorse dell'app (icone, asset) se presenti.
APP_RESOURCES="$ROOT/Sources/ClaudeBarApp/Resources"
if [[ -d "$APP_RESOURCES" ]]; then
  cp -R "$APP_RESOURCES/." "$APP/Contents/Resources/" 2>/dev/null || true
fi

# Pulizia attributi estesi (evita ._* e sealing rotto), poi firma.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true

# Firma — priorità:
#   1. CLBAR_IDENTITY="<nome o SHA-1>"  → firma con identità STABILE (consigliato). La firma
#      non cambia tra le ricompilazioni → il permesso "Always Allow" del Keychain per
#      "Claude Code-credentials" PERSISTE: niente prompt password a ogni rilancio.
#   2. CLBAR_SIGN=1                     → firma ad-hoc (cambia a ogni build → il Keychain ri-chiede).
#   3. default                          → nessuna ri-firma (resta l'ad-hoc del linker).
SIGN_IDENTITY="${CLBAR_IDENTITY:-}"
# Default: se non forzato ad-hoc e nessuna identità data, usa la PRIMA identità di firma
# valida (esclude quelle revocate). Firma stabile = "Always Allow" del Keychain persiste.
if [[ -z "$SIGN_IDENTITY" && "${CLBAR_SIGN:-0}" != "1" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -Ev 'CSSMERR|REVOKED' \
    | awk 'match($0, /[0-9A-F]{40}/) { print substr($0, RSTART, 40); exit }')
fi

# `SIGN_MODE` riassume cosa è stato fatto, così il riepilogo finale dice ESPLICITAMENTE se la
# build è firmata stabile o ad-hoc — è la terza causa dei ri-prompt del Keychain ("Always Allow"
# non persiste con firma instabile). Se l'utente vede ri-prompt continui, qui capisce il perché.
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Firma con identità stabile: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  SIGN_MODE="stabile ($SIGN_IDENTITY) → 'Always Allow' del Keychain PERSISTE"
elif [[ "${CLBAR_SIGN:-0}" == "1" ]]; then
  echo "==> Firma ad-hoc (cambia a ogni build → il Keychain richiederà la password ogni volta)…"
  codesign --force --deep --sign - "$APP"
  SIGN_MODE="ad-hoc (CLBAR_SIGN=1) → cambia a OGNI build, il Keychain RI-CHIEDE la password"
else
  SIGN_MODE="nessuna ri-firma (firma ad-hoc del linker) → instabile, il Keychain può RI-CHIEDERE"
fi

echo "==> Creato $APP"
echo "    bundle id : $BUNDLE_ID"
echo "    versione  : $VERSION ($BUILD_NUMBER)"
echo "    config    : $CONFIG"
echo "    firma     : $SIGN_MODE"
