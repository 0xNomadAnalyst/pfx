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
