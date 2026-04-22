#!/usr/bin/env bash
# Thin wrapper around deploy.py that uses the project's local .venv python.
# Accepts all of deploy.py's flags (--apply, --teardown, --reset, --yes).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"

if   [ -x "$ROOT_DIR/.venv/Scripts/python.exe" ]; then VENV_PY="$ROOT_DIR/.venv/Scripts/python.exe"
elif [ -x "$ROOT_DIR/.venv/bin/python"         ]; then VENV_PY="$ROOT_DIR/.venv/bin/python"
else
    echo "ERROR: no venv found at $ROOT_DIR/.venv" >&2
    echo "Run: bash $ROOT_DIR/bootstrap.sh" >&2
    exit 2
fi

cd "$HERE"
exec "$VENV_PY" deploy.py "$@"
