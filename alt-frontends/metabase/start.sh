#!/usr/bin/env bash
# =============================================================================
# Metabase Startup Script
# =============================================================================
# Starts Metabase with local H2 application database for portable state.
#
# Usage:
#   ./start.sh              # Start on default port 3000
#   ./start.sh 3001         # Start on custom port
#
# The H2 app database (metabase.db.mv.db) stores all dashboards, questions,
# collections, and settings. Back it up with ./dump.sh to preserve state.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${1:-3000}"

# --- Locate Java ---
# Try PATH first, then common Windows install locations
if command -v java &>/dev/null; then
    JAVA_BIN="java"
elif [ -d "/c/Program Files/Eclipse Adoptium" ]; then
    # Find the most recent Temurin JRE
    JAVA_BIN="$(find "/c/Program Files/Eclipse Adoptium" -name "java.exe" -path "*/bin/*" 2>/dev/null | head -1)"
    if [ -z "$JAVA_BIN" ]; then
        echo "ERROR: Found Eclipse Adoptium directory but no java.exe inside it."
        exit 1
    fi
else
    echo "ERROR: Java not found. Install Eclipse Temurin JRE 21:"
    echo "  winget install EclipseAdoptium.Temurin.21.JRE"
    exit 1
fi

echo "Using Java: $("$JAVA_BIN" -version 2>&1 | head -1)"
echo "Metabase JAR: $SCRIPT_DIR/metabase.jar"
echo "App database: $SCRIPT_DIR/metabase.db.mv.db"
echo "Port: $PORT"
echo ""

# --- Metabase Configuration ---
# H2 app database is stored locally in this directory (default behavior).
# MB_DB_FILE controls where the H2 database is written.
export MB_DB_FILE="$SCRIPT_DIR/metabase.db"
export MB_JETTY_PORT="$PORT"

# Disable anonymous usage tracking
export MB_ANON_TRACKING_ENABLED="false"

# Disable Metabase update check notifications
export MB_CHECK_FOR_UPDATES="false"

echo "============================================="
echo "  Starting Metabase on http://localhost:$PORT"
echo "  Press Ctrl+C to stop"
echo "============================================="
echo ""

"$JAVA_BIN" --add-opens java.base/java.nio=ALL-UNNAMED -jar "$SCRIPT_DIR/metabase.jar"
