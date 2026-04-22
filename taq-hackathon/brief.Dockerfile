# syntax=docker/dockerfile:1.4
# =============================================================================
# ONyc Daily Brief — Railway deployment image
# =============================================================================
# Build context: pfx/taq-hackathon/
# Self-contained: design-system CSS tokens are bundled into app/static/css/
# so the build context does NOT need to reach outside this directory.
# Keep the CSS in sync with pfx/design-system-260422/ via app/start.sh during
# local dev — it copies fresh files each time. On Railway, whatever is
# committed under app/static/css/ at build time is what the container serves.
# =============================================================================

FROM python:3.11-slim AS runtime

WORKDIR /app

# Dependencies first so layer caching survives app code changes.
COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY app/ ./app

# Railway injects its own PORT; shell form expands ${PORT} at container start.
# Fallback to 8003 for local `docker run` without a PORT set.
ENV PORT=8003
EXPOSE 8003

CMD ["sh", "-c", "python -m uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
