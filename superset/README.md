# Superset Local Instance

## Quick Reference

All commands run from `pfx/superset/superset-repo/`.

### Start

```bash
docker compose -f docker-compose-image-tag.yml up
```

### Stop (preserves data)

```bash
docker compose -f docker-compose-image-tag.yml down
```

### Restart app only (after config changes)

```bash
docker restart superset_app superset_worker superset_worker_beat
```

### Access

- URL: http://localhost:8088
- Username: `admin`
- Password: `admin`

### Config overrides

Edit `docker/pythonpath_dev/superset_config.py` then restart the app containers.

Do **not** edit `superset/config.py` — that file is baked into the image and not mounted.

## Destructive Commands (will delete saved data)

```bash
# DO NOT run unless you want a full reset
docker compose -f docker-compose-image-tag.yml down -v
```

The `-v` flag removes volumes (Postgres database, Redis cache, Superset home) — all dashboards, charts, datasets, and saved queries will be lost.
