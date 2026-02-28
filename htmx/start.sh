#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$(cd "$SCRIPT_DIR/../api-w-caching" && pwd)"
UI_DIR="$SCRIPT_DIR"

is_windows_shell() {
  [[ "${OS:-}" == "Windows_NT" ]]
}

windows_listening_pid_count() {
  local port="$1"
  powershell -NoProfile -Command '$port = '"$port"'; $count = (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count; Write-Output $count; exit 0'
}

windows_kill_listeners_on_port() {
  local port="$1"
  powershell -NoProfile -Command '
    $port = '"$port"'
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) { exit 0 }
    $pids = $conns | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique
    foreach ($p in $pids) {
      # taskkill /T kills the whole process tree (parent + reload workers)
      taskkill /F /T /PID $p 2>&1 | Out-Null
      # Fallback: also kill by process name variants the tree might leave behind
      $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
      if ($proc) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
    # Also kill any orphaned python3.12 / python processes still holding this port
    Start-Sleep -Milliseconds 500
    $stale = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($stale) {
      $stalePids = $stale | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique
      foreach ($sp in $stalePids) {
        taskkill /F /T /PID $sp 2>&1 | Out-Null
        # Last resort: find the real process behind Windows Store app aliases
        Get-Process -Id $sp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      }
    }
    exit 0
  '
}

windows_report_port_listeners() {
  local port="$1"
  powershell -NoProfile -Command '$port = '"$port"'; $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue; if (-not $conns) { Write-Output "<none>"; exit 0 }; foreach ($conn in $conns) { Write-Output ("PID=" + $conn.OwningProcess + " LocalAddress=" + $conn.LocalAddress + ":" + $conn.LocalPort) }'
}

wait_for_port_to_clear() {
  local port="$1"
  local retries=40
  local i
  for ((i = 0; i < retries; i++)); do
    if is_windows_shell; then
      local count
      count="$(windows_listening_pid_count "$port" 2>/dev/null | tr -d '\r' || true)"
      if [[ -z "${count:-}" ]]; then
        count="0"
      fi
      if [[ "${count:-0}" == "0" ]]; then
        return 0
      fi
    else
      if ! netstat -an 2>/dev/null | awk -v target=":$port" '/LISTEN/ && $0 ~ target { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
      fi
    fi
    sleep 0.3
  done
  return 1
}

kill_listeners_on_port() {
  local port="$1"
  if is_windows_shell; then
    windows_kill_listeners_on_port "$port" || true
    if ! wait_for_port_to_clear "$port"; then
      echo "Error: port $port is still in use after cleanup." >&2
      echo "Remaining listeners:" >&2
      windows_report_port_listeners "$port" >&2 || true
      return 1
    fi
    return 0
  fi

  local pids
  pids="$(netstat -ano 2>/dev/null | awk -v target=":$port" '/LISTENING/ && $0 ~ target {gsub(/\r/, "", $5); print $5}' | sort -u)"
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -TERM "$pid" >/dev/null 2>&1 || true
    done <<<"$pids"
  fi
  if ! wait_for_port_to_clear "$port"; then
    echo "Error: port $port is still in use after cleanup." >&2
    netstat -an 2>/dev/null | awk -v target=":$port" '/LISTEN/ && $0 ~ target { print }' >&2 || true
    return 1
  fi
}

activate_venv_if_present() {
  local venv
  for venv in ".venv" "$SCRIPT_DIR/../.venv"; do
    if [[ -f "$venv/Scripts/activate" ]]; then
      # Git Bash on Windows
      # shellcheck disable=SC1091
      source "$venv/Scripts/activate"
      return
    elif [[ -f "$venv/bin/activate" ]]; then
      # Linux/macOS
      # shellcheck disable=SC1091
      source "$venv/bin/activate"
      return
    fi
  done
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
    export PYTHONPATH="$API_DIR"
    exec python -m uvicorn app.main:app --host 0.0.0.0 --port "${API_PORT:-8001}" --reload
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
    echo "Starting UI at http://127.0.0.1:${UI_PORT:-8002}/dex-liquidity"
    export API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:${API_PORT:-8001}}"
    export PYTHONPATH="$UI_DIR"
    exec python -m uvicorn app.main:app --host 0.0.0.0 --port "${UI_PORT:-8002}" --reload
  )
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if is_windows_shell; then
    # Kill process trees for both services; also re-clear ports in case
    # orphaned reload-workers outlived the parent.
    for pid_var in api_pid ui_pid; do
      local pid="${!pid_var:-}"
      if [[ -n "$pid" ]]; then
        taskkill //PID "$pid" //T //F >/dev/null 2>&1 || true
      fi
    done
    for port in "${API_PORT:-8001}" "${UI_PORT:-8002}"; do
      windows_kill_listeners_on_port "$port" 2>/dev/null || true
    done
  else
    for pid_var in api_pid ui_pid; do
      local pid="${!pid_var:-}"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done
  fi
  wait 2>/dev/null || true
  exit "$exit_code"
}

trap cleanup EXIT INT TERM

kill_listeners_on_port "${API_PORT:-8001}"
kill_listeners_on_port "${UI_PORT:-8002}"

run_api &
api_pid=$!

# Let API start first to reduce initial UI request failures.
sleep 1

run_ui &
ui_pid=$!

echo "Both services launched."
echo "API: http://127.0.0.1:${API_PORT:-8001}"
echo "UI : http://127.0.0.1:${UI_PORT:-8002}/dex-liquidity"

# If either exits, tear down both.
wait -n "$api_pid" "$ui_pid"
