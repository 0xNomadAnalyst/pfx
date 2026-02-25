#!/usr/bin/env bash
# =============================================================================
# Metabase Stop Script
# =============================================================================
# Stops a running Metabase instance by finding and killing the process on its
# port. Alternative to Ctrl+C in the start terminal.
#
# Usage:
#   ./stop.sh         # stop instance on default port 3000
#   ./stop.sh 3001    # stop instance on custom port
# =============================================================================

set -euo pipefail

PORT="${1:-3000}"
BASE_URL="http://localhost:$PORT"

# --- Check if running ---
if ! curl -s --max-time 3 "$BASE_URL/api/health" &>/dev/null; then
    echo "Metabase is not running on port $PORT."
    exit 0
fi

# --- Find PID ---
METABASE_PID=$(MSYS_NO_PATHCONV=1 netstat.exe -ano 2>/dev/null \
    | grep ":${PORT}.*LISTENING" | head -1 | awk '{print $NF}' || true)

if [ -z "$METABASE_PID" ] || [ "$METABASE_PID" = "0" ]; then
    echo "ERROR: Metabase is responding on port $PORT but could not find its PID."
    echo "Stop it manually with Ctrl+C in the start terminal."
    exit 1
fi

# --- Kill ---
echo "Stopping Metabase (port $PORT, PID $METABASE_PID)..."
MSYS_NO_PATHCONV=1 taskkill.exe /PID "$METABASE_PID" /F /T >/dev/null 2>&1 || true

# --- Wait for exit ---
for i in $(seq 1 15); do
    if ! MSYS_NO_PATHCONV=1 netstat.exe -ano 2>/dev/null | grep -q ":${PORT}.*LISTENING"; then
        echo "Metabase stopped."
        exit 0
    fi
    sleep 1
done

echo "WARNING: Metabase may still be shutting down."
