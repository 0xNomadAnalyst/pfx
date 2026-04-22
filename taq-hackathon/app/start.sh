#!/usr/bin/env bash
# Start the ONyc Daily Brief web viewer, using the local .venv at the
# hackathon project root. Refreshes design-system tokens into
# app/static/css/ before launching.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"
DS_DIR="$ROOT_DIR/../design-system-260422"
STATIC_CSS="$APP_DIR/static/css"

# Resolve the venv python (Windows has Scripts/, Unix has bin/)
if   [ -x "$ROOT_DIR/.venv/Scripts/python.exe" ]; then VENV_PY="$ROOT_DIR/.venv/Scripts/python.exe"
elif [ -x "$ROOT_DIR/.venv/bin/python"         ]; then VENV_PY="$ROOT_DIR/.venv/bin/python"
else
    echo "ERROR: no venv found at $ROOT_DIR/.venv" >&2
    echo "Run: bash $ROOT_DIR/bootstrap.sh" >&2
    exit 2
fi

mkdir -p "$STATIC_CSS"
cp -u "$DS_DIR/colors_and_type.css"                 "$STATIC_CSS/colors_and_type.css"
cp -u "$DS_DIR/htmx/app/static/css/theme.css"       "$STATIC_CSS/theme.css"

cd "$ROOT_DIR"
exec "$VENV_PY" -m uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8003}"
