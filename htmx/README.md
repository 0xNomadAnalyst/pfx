# HTMX Dashboard (Functional Parity Build)

This app renders the dashboard UI with Jinja templates and refreshes widget data via HTMX calls to the API service.

## Run

1. Copy `.env.example` to `.env`.
2. Set `API_BASE_URL` to your API service URL (default `http://localhost:8001`).
3. Install dependencies:
   - `pip install -r requirements.txt`
4. Start UI:
   - `python -m app.main`

Default URL: `http://localhost:8002/playbook-liquidity`

## Notes

- The UI does not query SQL directly.
- Each widget pulls JSON from `/api/v1/playbook-liquidity/{widget}`.
- Theme toggle is persisted in `localStorage`.
- Soft-nav test and telemetry docs: `docs/soft-nav-testing-and-telemetry.md`.
- 2026-03-27 loading assessment report: `docs/loading-speed-assessment-2026-03-27.md`.
- 2026-03-27 Wave 2 run report: `docs/performance-wave-2-run-report-2026-03-27.md`.
- 2026-03-26 Wave 3 run report: `docs/performance-wave-3-run-report-2026-03-26.md`.
- 2026-03-27 Wave 4 run report: `docs/performance-wave-4-run-report-2026-03-27.md`.
- 2026-03-26 Wave 5 run report: `docs/performance-wave-5-run-report-2026-03-26.md`.
