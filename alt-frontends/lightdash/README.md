# Lightdash Local Instance

## Quick Reference

All commands run from `pfx/lightdash/`.

### Start

```bash
docker compose up
```

### Stop (preserves data)

```bash
docker compose down
```

### Restart Lightdash only (after config/dbt changes)

```bash
docker restart lightdash-lightdash-1
```

### Access

- Lightdash: http://localhost:8080
- MinIO Console: http://localhost:9001 (user: `minioadmin` / pw: `minioadmin`)
- Postgres: `localhost:5433` (user: `postgres` / pw: `lightdash_local_pw` / db: `lightdash`)

### Config & Environment

Edit `.env` for Lightdash settings, then restart. The dbt project is bind-mounted from `./dbt_project` — edits there are reflected immediately (re-sync in the Lightdash UI).

## Data Persistence

Two named volumes keep your data safe across `docker compose down` / `up` cycles:

| Volume | Mounted to | Stores |
|---|---|---|
| `db-data` | Postgres `/var/lib/postgresql/data` | Users, projects, dashboards, saved charts, spaces |
| `minio-data` | MinIO `/data` | Query result cache, exported files |

The `./dbt_project` directory is a bind mount — it lives on your host filesystem and is never affected by Docker commands.

## Destructive Commands (will delete saved data)

```bash
# DO NOT run unless you want a full reset
docker compose down -v
```

The `-v` flag removes named volumes (`db-data`, `minio-data`) — all Lightdash users, dashboards, saved charts, and cached results will be lost. Your dbt project files on the host are not affected.
