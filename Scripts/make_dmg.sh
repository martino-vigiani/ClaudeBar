#!/usr/bin/env bash
# make_dmg.sh — costruisce un .dmg distribuibile di ClaudeBar.
#
# 1) build release + bundle .app (via bundle.sh)
# 2) staging con .app + symlink /Applications + volume icon
# 3) DMG compresso (UDZO) con icona di volume custom
#
# Uso: Scripts/make_dmg.sh
# Override: CLBAR_VERSION, CLBAR_DISPLAY_NAME (ereditati da bundle.sh).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DISPLAY_NAME="${CLBAR_DISPLAY_NAME:-ClaudeBar}"
VERSION="${CLBAR_VERSION:-0.1.0}"
APP="$ROOT/$DISPLAY_NAME.app"
ICON="$ROOT/Sources/ClaudeBarApp/Resources/AppIcon.icns"
DMG_FINAL="$ROOT/$DISPLAY_NAME-$VERSION.dmg"

echo "==> Build release + bundle…"
CLBAR_CONFIG=release "$ROOT/Scripts/bundle.sh" >/dev/null
[[ -d "$APP" ]] || { echo "ERRORE: $APP non trovato." >&2; exit 1; }

echo "==> Staging…"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[[ -f "$ICON" ]] && cp "$ICON" "$STAGE/.VolumeIcon.icns"

echo "==> Creo DMG read-write temporaneo…"
TMP_DMG=$(mktemp -u).dmg
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP_DMG" >/dev/null

# Monta, marca l'attributo "ha icona custom" sul volume, smonta.
MOUNT=$(hdiutil attach "$TMP_DMG" -nobrowse -noverify -noautoopen | grep -Eo '/Volumes/[^ ]+.*' | sed 's/[[:space:]]*$//' | head -1)
if [[ -n "${MOUNT:-}" && -f "$MOUNT/.VolumeIcon.icns" ]]; then
  SetFile -a C "$MOUNT" 2>/dev/null || true
fi
[[ -n "${MOUNT:-}" ]] && hdiutil detach "$MOUNT" >/dev/null || true

echo "==> Comprimo in ${DMG_FINAL} …"
rm -f "$DMG_FINAL"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_FINAL" >/dev/null
rm -f "$TMP_DMG"

echo "==> Creato $DMG_FINAL"
du -h "$DMG_FINAL" | awk '{print "    size: "$1}'
