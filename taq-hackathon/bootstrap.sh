#!/usr/bin/env bash
# Bootstrap the hackathon project's local virtualenv at pfx/taq-hackathon/.venv
# and install the full dependency set (app + db-sql). Idempotent: re-running
# refreshes dependencies against whatever is in the two requirements.txt files.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$ROOT_DIR/.venv"

# Find a Python to create the venv with. Prefer `python3`, then `python`.
PY_BIN="${PYTHON:-}"
if [ -z "$PY_BIN" ]; then
    if command -v python3 >/dev/null 2>&1; then PY_BIN="python3"
    elif command -v python  >/dev/null 2>&1; then PY_BIN="python"
    else
        echo "ERROR: no python3 or python on PATH. Install Python 3.11+ and retry." >&2
        exit 2
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "creating $VENV_DIR using $PY_BIN ..."
    "$PY_BIN" -m venv "$VENV_DIR"
else
    echo "venv already present at $VENV_DIR"
fi

# Resolve the venv python for the platform
if   [ -x "$VENV_DIR/Scripts/python.exe" ]; then VENV_PY="$VENV_DIR/Scripts/python.exe"
elif [ -x "$VENV_DIR/bin/python"         ]; then VENV_PY="$VENV_DIR/bin/python"
else
    echo "ERROR: venv created but no python found under $VENV_DIR" >&2
    exit 2
fi

echo "upgrading pip ..."
"$VENV_PY" -m pip install --upgrade pip --quiet

echo "installing app requirements ..."
"$VENV_PY" -m pip install -r "$ROOT_DIR/app/requirements.txt" --quiet

echo "installing db-sql requirements ..."
"$VENV_PY" -m pip install -r "$ROOT_DIR/db-sql/requirements.txt" --quiet

echo ""
echo "bootstrap complete."
echo "  venv:         $VENV_DIR"
echo "  interpreter:  $VENV_PY"
echo ""
echo "next:"
echo "  bash db-sql/deploy.sh --apply --reset --yes    # apply DDL"
echo "  bash app/run_brief.sh                          # generate today's brief"
echo "  bash app/start.sh                              # serve http://localhost:8003"
