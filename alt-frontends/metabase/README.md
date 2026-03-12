# Metabase (Self-Hosted)

Local Metabase instance using an embedded H2 database for portable state. No persistent service or external storage required.

## Quick Start

```bash
./start.sh          # start on port 3000
./start.sh 3001     # custom port
./stop.sh           # stop from any terminal (or Ctrl+C in start terminal)
```

First run opens setup at `http://localhost:3000/setup` -- create admin account and add your data source.

## State

All state (dashboards, questions, collections, settings, users) lives in a single file: `metabase.db.mv.db`. This file persists across stop/start cycles -- no restore needed for normal usage.

## Dump & Restore

For **checkpointing and rollback**, not normal stop/start.

```bash
# Checkpoint (works while running -- briefly stops and restarts Metabase)
./dump.sh                      # auto-timestamped
./dump.sh before-experiment    # named checkpoint
./dump.sh --no-restart name    # don't restart after dump

# Rollback (Metabase must be stopped)
./restore.sh                   # interactive picker
./restore.sh before-experiment # restore specific checkpoint
```

Backups are stored in `backups/`. Restore automatically creates a safety backup of current state before overwriting.

## Requirements

- Java 21 (Eclipse Temurin JRE): `winget install EclipseAdoptium.Temurin.21.JRE`
