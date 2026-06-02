#!/usr/bin/env bash
# run.sh — dev loop: build + bundle + open dell'app.
# Usa la config debug e il bundle id .debug → non collide con una release installata.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

CLBAR_CONFIG="${CLBAR_CONFIG:-debug}" "$ROOT/Scripts/bundle.sh"

DISPLAY_NAME="${CLBAR_DISPLAY_NAME:-ClaudeBar}"
APP="$ROOT/$DISPLAY_NAME.app"

echo "==> Termino istanze precedenti…"
pkill -f "$DISPLAY_NAME.app/Contents/MacOS" 2>/dev/null || true

echo "==> Avvio ${APP}…"
open "$APP"
