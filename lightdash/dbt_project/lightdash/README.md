# Lightdash Content (Charts & Dashboards)

This directory contains chart and dashboard definitions managed as YAML via the Lightdash CLI.

## Directory structure

```
lightdash/
├── charts/          # Chart YAML files (downloaded from Lightdash)
├── dashboards/      # Dashboard YAML files
└── references/      # Lightdash skill docs & JSON schemas (not deployed)
```

## Downloading content

```bash
# Download all dashboards (includes dashboard-linked charts)
lightdash download --dashboards defi-ecosystem-dashboard

# Download standalone charts
lightdash download --charts <chart-slug>
```

Dashboard-linked charts only download when you use `--dashboards`; they won't appear with `--charts` alone.

## Editing and uploading

1. Edit the YAML files locally
2. Upload changes:

```bash
lightdash upload --charts <chart-slug>
lightdash upload --dashboards <dashboard-slug>
lightdash upload --force          # ignore timestamp checks
```

## Deploying the semantic layer (models, dimensions, metrics)

Semantic layer changes live in `../models/` (dbt YAML). Deploy with:

```bash
lightdash deploy                   # compile dbt + sync to Lightdash
lightdash deploy --ignore-errors   # skip staging model warnings
```

## Useful commands

| Command | Purpose |
|---------|---------|
| `lightdash config get-project` | Show active project |
| `lightdash config set-project --name "risk_dash"` | Switch project |
| `lightdash lint --path ./lightdash` | Validate YAML locally |
| `lightdash preview --name "test"` | Spin up a temporary preview project |
| `lightdash sql "SELECT ..." -o out.csv` | Run SQL against the warehouse |
