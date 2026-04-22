#!/usr/bin/env bash
# Thin wrapper around `python -m app.generator.run_brief` using the project's
# local .venv python. Accepts all of run_brief.py's flags (--date, --dry-run).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"

if   [ -x "$ROOT_DIR/.venv/Scripts/python.exe" ]; then VENV_PY="$ROOT_DIR/.venv/Scripts/python.exe"
elif [ -x "$ROOT_DIR/.venv/bin/python"         ]; then VENV_PY="$ROOT_DIR/.venv/bin/python"
else
    echo "ERROR: no venv found at $ROOT_DIR/.venv" >&2
    echo "Run: bash $ROOT_DIR/bootstrap.sh" >&2
    exit 2
fi

cd "$ROOT_DIR"
exec "$VENV_PY" -m app.generator.run_brief "$@"
