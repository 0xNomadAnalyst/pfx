#!/usr/bin/env bash
# =============================================================================
# Metabase State Restore
# =============================================================================
# Restores the Metabase H2 application database from a previous backup.
# This restores all dashboards, questions, collections, settings, and users.
#
# IMPORTANT: Stop Metabase before running this.
#
# Usage:
#   ./restore.sh                          # Interactive: lists backups to choose from
#   ./restore.sh my-checkpoint            # Restore named backup
#   ./restore.sh metabase_20260210_143022 # Restore timestamped backup
#
# Backups are read from: pfx/metabase/backups/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="$SCRIPT_DIR/backups"
DB_FILE="$SCRIPT_DIR/metabase.db.mv.db"

# --- Validate backup directory exists ---
if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: No backups directory found at: $BACKUP_DIR"
    echo "Run ./dump.sh first to create a backup."
    exit 1
fi

# --- List or select backup ---
if [ -z "${1:-}" ]; then
    echo "Available backups:"
    echo ""

    BACKUPS=()
    i=1
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        NAME="$(basename "$d")"
        SIZE="$(du -sh "$d" | cut -f1)"
        # Get modification time of the mv.db file inside
        DB_INSIDE="$d/metabase.db.mv.db"
        if [ -f "$DB_INSIDE" ]; then
            MOD="$(date -r "$DB_INSIDE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$DB_INSIDE" 2>/dev/null | cut -d. -f1)"
        else
            MOD="(no db file)"
        fi
        echo "  [$i] $NAME  ($SIZE, $MOD)"
        BACKUPS+=("$NAME")
        ((i++))
    done < <(ls -dt "$BACKUP_DIR"/*/ 2>/dev/null)

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "  (none found)"
        echo ""
        echo "Run ./dump.sh first to create a backup."
        exit 1
    fi

    echo ""
    read -p "Enter number or name to restore (or 'q' to quit): " CHOICE

    if [ "$CHOICE" = "q" ] || [ "$CHOICE" = "Q" ]; then
        exit 0
    fi

    # Check if it's a number
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#BACKUPS[@]} ]; then
        BACKUP_NAME="${BACKUPS[$((CHOICE-1))]}"
    else
        BACKUP_NAME="$CHOICE"
    fi
else
    BACKUP_NAME="$1"
fi

BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

# --- Validate backup exists ---
if [ ! -d "$BACKUP_PATH" ] || [ ! -f "$BACKUP_PATH/metabase.db.mv.db" ]; then
    echo "ERROR: Backup not found: $BACKUP_PATH"
    echo ""
    echo "Available backups:"
    for d in "$BACKUP_DIR"/*/; do
        [ -d "$d" ] || continue
        echo "  $(basename "$d")"
    done
    exit 1
fi

# --- Safety: backup current state before overwriting ---
if [ -f "$DB_FILE" ]; then
    SAFETY_NAME="pre-restore_$(date +%Y%m%d_%H%M%S)"
    echo "Saving current state as safety backup: $SAFETY_NAME"
    SAFETY_DIR="$BACKUP_DIR/$SAFETY_NAME"
    mkdir -p "$SAFETY_DIR"
    cp "$DB_FILE" "$SAFETY_DIR/metabase.db.mv.db"
    TRACE_FILE="$SCRIPT_DIR/metabase.db.trace.db"
    if [ -f "$TRACE_FILE" ]; then
        cp "$TRACE_FILE" "$SAFETY_DIR/metabase.db.trace.db"
    fi
fi

# --- Restore ---
echo "Restoring from: $BACKUP_NAME"
cp "$BACKUP_PATH/metabase.db.mv.db" "$DB_FILE"

# Restore trace file if it exists in backup
TRACE_BACKUP="$BACKUP_PATH/metabase.db.trace.db"
TRACE_FILE="$SCRIPT_DIR/metabase.db.trace.db"
if [ -f "$TRACE_BACKUP" ]; then
    cp "$TRACE_BACKUP" "$TRACE_FILE"
elif [ -f "$TRACE_FILE" ]; then
    # Remove stale trace file if no trace in backup
    rm "$TRACE_FILE"
fi

echo ""
echo "Restore complete! Run ./start.sh to launch Metabase."
