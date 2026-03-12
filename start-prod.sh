#!/usr/bin/env bash
# Production launcher: starts the API backend then the HTMX UI frontend.
# Railway sets PORT for the public-facing service; the API runs on API_PORT
# (default 8001) and is only reachable inside the container.
set -euo pipefail

API_PORT="${API_PORT:-8001}"
UI_PORT="${PORT:-8002}"
export API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:${API_PORT}}"

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
