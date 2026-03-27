#!/usr/bin/env bash
# Production launcher: starts the API backend then the HTMX UI frontend.
# Railway sets PORT for the public-facing service; the API runs on API_PORT
# (default 8001) and is only reachable inside the container.
set -euo pipefail

API_PORT="${API_PORT:-8001}"
UI_PORT="${PORT:-8002}"
export DASH_REFRESH_INTERVAL_SECONDS="${DASH_REFRESH_INTERVAL_SECONDS:-30}"
export API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:${API_PORT}}"

# ---------------------------------------------------------------------------
# Pipeline switcher — write the two credential files that pipeline_config.py
# looks up at runtime.  In the container the resolved paths are:
#   solstice  →  /.env.prod.core          (project_root.parent from /app/)
#   onyc      →  /app/.env.pfx.core       (project_root from /app/)
#
# Set SOLSTICE_DB_* and ONYC_DB_* in Railway's Variables tab.
# ENABLE_PIPELINE_SWITCHER must also be set to "1" to activate the UI toggle.
# ---------------------------------------------------------------------------
write_pipeline_env() {
  local dest="$1" prefix="$2"
  local host port name user pass sslmode
  host="$(eval echo "\${${prefix}_DB_HOST:-}")"
  [ -z "$host" ] && return 0   # skip if not configured
  port="$(eval echo "\${${prefix}_DB_PORT:-5432}")"
  name="$(eval echo "\${${prefix}_DB_NAME:-}")"
  user="$(eval echo "\${${prefix}_DB_USER:-}")"
  pass="$(eval echo "\${${prefix}_DB_PASSWORD:-}")"
  sslmode="$(eval echo "\${${prefix}_DB_SSLMODE:-require}")"
  printf 'DB_HOST=%s\nDB_PORT=%s\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\nDB_SSLMODE=%s\n' \
    "$host" "$port" "$name" "$user" "$pass" "$sslmode" > "$dest"
  echo "Pipeline env written: $dest (host=$host)"
}

write_pipeline_env "/.env.prod.core"   "SOLSTICE"
write_pipeline_env "/app/.env.pfx.core" "ONYC"

# Export the startup-active DB credentials into the process environment so
# the API's _validate_env() / load_dotenv path sees them on first boot.
# ONYC is the default; if DB_HOST is already set (e.g. overridden in Railway
# Variables) those values take precedence.
export DB_HOST="${DB_HOST:-${ONYC_DB_HOST:-}}"
export DB_PORT="${DB_PORT:-${ONYC_DB_PORT:-5432}}"
export DB_NAME="${DB_NAME:-${ONYC_DB_NAME:-}}"
export DB_USER="${DB_USER:-${ONYC_DB_USER:-}}"
export DB_PASSWORD="${DB_PASSWORD:-${ONYC_DB_PASSWORD:-}}"
export DB_SSLMODE="${DB_SSLMODE:-${ONYC_DB_SSLMODE:-require}}"

cleanup() {
  echo "Shutting down..."
  kill "${API_PID:-}" "${UI_PID:-}" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Starting API on port ${API_PORT} ..."
(
  cd /app/api-w-caching
  export PYTHONPATH=/app/api-w-caching
  exec python -m uvicorn app.main:app --host 0.0.0.0 --port "${API_PORT}"
) &
API_PID=$!

# Give the API a moment to initialise before the UI starts sending requests.
sleep 3

echo "Starting UI on port ${UI_PORT} ..."
(
  cd /app/htmx
  export PYTHONPATH=/app/htmx
  exec python -m uvicorn app.main:app --host 0.0.0.0 --port "${UI_PORT}"
) &
UI_PID=$!

echo "API : http://0.0.0.0:${API_PORT}"
echo "UI  : http://0.0.0.0:${UI_PORT}"

# If either process exits, the trap will kill the other and the container stops.
wait -n "${API_PID}" "${UI_PID}"
