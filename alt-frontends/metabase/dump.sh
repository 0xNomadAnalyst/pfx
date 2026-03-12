#!/usr/bin/env bash
# =============================================================================
# Metabase State Dump (Backup)
# =============================================================================
# Creates a timestamped snapshot of the Metabase H2 application database.
# This captures all dashboards, questions, collections, settings, and users.
#
# If Metabase is running, the script will:
#   1. Gracefully stop the Metabase process
#   2. Copy the H2 database file
#   3. Restart Metabase automatically (unless --no-restart)
#
# Usage:
#   ./dump.sh                    # Auto-named: backups/metabase_YYYYMMDD_HHMMSS/
#   ./dump.sh my-checkpoint      # Named: backups/my-checkpoint/
#   ./dump.sh --no-restart name  # Don't restart Metabase after dump
#
# Backups are stored in: pfx/metabase/backups/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="$SCRIPT_DIR/backups"
DB_FILE="$SCRIPT_DIR/metabase.db.mv.db"
PORT="${MB_JETTY_PORT:-3000}"
BASE_URL="http://localhost:$PORT"
AUTO_RESTART=true

# --- Parse args ---
BACKUP_NAME=""
for arg in "$@"; do
    if [ "$arg" = "--no-restart" ]; then
        AUTO_RESTART=false
    else
        BACKUP_NAME="$arg"
    fi
done

if [ -z "$BACKUP_NAME" ]; then
    BACKUP_NAME="metabase_$(date +%Y%m%d_%H%M%S)"
fi

# --- Validate DB exists ---
if [ ! -f "$DB_FILE" ]; then
    echo "ERROR: No Metabase database found at:"
    echo "  $DB_FILE"
    echo ""
    echo "Have you started Metabase at least once? Run ./start.sh first."
    exit 1
fi

# --- Create backup directory ---
mkdir -p "$BACKUP_DIR"

BACKUP_FILE_DIR="$BACKUP_DIR/$BACKUP_NAME"

if [ -d "$BACKUP_FILE_DIR" ]; then
    echo "ERROR: Backup '$BACKUP_NAME' already exists."
    echo "  $BACKUP_FILE_DIR"
    exit 1
fi

mkdir -p "$BACKUP_FILE_DIR"

# --- Check if Metabase is running ---
METABASE_RUNNING=false
METABASE_PID=""
if curl -s --max-time 3 "$BASE_URL/api/health" &>/dev/null; then
    METABASE_RUNNING=true
    # Find PID listening on the Metabase port
    METABASE_PID=$(MSYS_NO_PATHCONV=1 netstat.exe -ano 2>/dev/null \
        | grep ":${PORT}.*LISTENING" | head -1 | awk '{print $NF}' || true)
fi

if [ "$METABASE_RUNNING" = true ]; then
    echo "Metabase is running (port $PORT, PID $METABASE_PID)."
    echo "Will stop -> backup -> restart."
    echo ""

    # --- Stop Metabase ---
    echo "[1/3] Stopping Metabase..."
    if [ -n "$METABASE_PID" ] && [ "$METABASE_PID" != "0" ]; then
        MSYS_NO_PATHCONV=1 taskkill.exe /PID "$METABASE_PID" /F /T >/dev/null 2>&1 || true

        # Wait for process to fully exit and release file locks
        for i in $(seq 1 15); do
            if ! MSYS_NO_PATHCONV=1 netstat.exe -ano 2>/dev/null | grep -q ":${PORT}.*LISTENING"; then
                break
            fi
            sleep 1
        done
        sleep 2  # Extra time for file lock release
    else
        echo "  Could not find Metabase PID."
        echo "  Stop it manually (Ctrl+C), then run: ./dump.sh $BACKUP_NAME"
        rm -rf "$BACKUP_FILE_DIR"
        exit 1
    fi

    # Verify it's stopped
    if curl -s --max-time 2 "$BASE_URL/api/health" &>/dev/null; then
        echo "  ERROR: Metabase is still running. Stop it manually and retry."
        rm -rf "$BACKUP_FILE_DIR"
        exit 1
    fi
    echo "  Metabase stopped."
    echo ""
else
    echo "Metabase is not running. Performing direct backup."
    echo ""
fi

# --- Copy database files ---
echo "[2/3] Copying database..."
cp "$DB_FILE" "$BACKUP_FILE_DIR/metabase.db.mv.db" || {
    echo "ERROR: Failed to copy database file."
    echo "Make sure Metabase is fully stopped."
    rm -rf "$BACKUP_FILE_DIR"
    exit 1
}

TRACE_FILE="$SCRIPT_DIR/metabase.db.trace.db"
if [ -f "$TRACE_FILE" ]; then
    cp "$TRACE_FILE" "$BACKUP_FILE_DIR/metabase.db.trace.db" 2>/dev/null || true
fi

# --- Report ---
BACKUP_TOTAL=$(du -sh "$BACKUP_FILE_DIR" | cut -f1)
echo ""
echo "Backup complete!"
echo "  Name:     $BACKUP_NAME"
echo "  Location: $BACKUP_FILE_DIR/"
echo "  Size:     $BACKUP_TOTAL"
echo ""

# List all backups
echo "All backups:"
for d in "$BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    NAME="$(basename "$d")"
    SIZE="$(du -sh "$d" | cut -f1)"
    echo "  $NAME  ($SIZE)"
done

# --- Restart if needed ---
if [ "$METABASE_RUNNING" = true ] && [ "$AUTO_RESTART" = true ]; then
    echo ""
    echo "[3/3] Restarting Metabase on port $PORT..."
    echo "  (Metabase will start in this terminal. Press Ctrl+C to stop it later.)"
    echo ""
    exec bash "$SCRIPT_DIR/start.sh" "$PORT"
fi
