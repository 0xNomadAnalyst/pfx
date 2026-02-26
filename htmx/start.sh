#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$(cd "$SCRIPT_DIR/../api-w-caching" && pwd)"
UI_DIR="$SCRIPT_DIR"

activate_venv_if_present() {
  if [[ -f ".venv/Scripts/activate" ]]; then
    # Git Bash on Windows
    # shellcheck disable=SC1091
    source ".venv/Scripts/activate"
  elif [[ -f ".venv/bin/activate" ]]; then
    # Linux/macOS
    # shellcheck disable=SC1091
    source ".venv/bin/activate"
  fi
}

run_api() {
  (
    cd "$API_DIR"
    activate_venv_if_present
    if ! command -v python >/dev/null 2>&1; then
      echo "Error: python is not available on PATH (API)." >&2
      exit 1
    fi
    echo "Starting API at http://127.0.0.1:${API_PORT:-8001}"
    exec python -m app.main
  )
}

run_ui() {
  (
    cd "$UI_DIR"
    activate_venv_if_present
    if ! command -v python >/dev/null 2>&1; then
      echo "Error: python is not available on PATH (UI)." >&2
      exit 1
    fi
    echo "Starting UI at http://127.0.0.1:${UI_PORT:-8002}/playbook-liquidity"
    exec python -m app.main
  )
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ -n "${api_pid:-}" ]] && kill -0 "$api_pid" 2>/dev/null; then
    kill "$api_pid" 2>/dev/null || true
  fi
  if [[ -n "${ui_pid:-}" ]] && kill -0 "$ui_pid" 2>/dev/null; then
    kill "$ui_pid" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  exit "$exit_code"
}

trap cleanup EXIT INT TERM

run_api &
api_pid=$!

# Let API start first to reduce initial UI request failures.
sleep 1

run_ui &
ui_pid=$!

echo "Both services launched."
echo "API: http://127.0.0.1:${API_PORT:-8001}"
echo "UI : http://127.0.0.1:${UI_PORT:-8002}/playbook-liquidity"

# If either exits, tear down both.
wait -n "$api_pid" "$ui_pid"
