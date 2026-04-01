FROM python:3.12-slim

WORKDIR /app

# Safe runtime defaults; all values remain overridable at deploy time.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    API_PORT=8001 \
    PORT=8002 \
    DASH_REFRESH_INTERVAL_SECONDS=30 \
    HTMX_CACHE_MODE=balanced \
    API_CACHE_MODE=speed \
    DB_POOL_MIN=2 \
    DB_POOL_MAX=12 \
    API_PREWARM_GLOBAL_HOTSPOTS_ENABLED=1 \
    GE_HOTSPOT_WIDGET_TTL_SECONDS=180 \
    API_TELEMETRY_ENABLED=0 \
    CORS_ALLOWED_ORIGINS=

# Install API dependencies
COPY api-w-caching/requirements.txt api-requirements.txt
RUN pip install --no-cache-dir -r api-requirements.txt

# Install UI dependencies
COPY htmx/requirements.txt htmx-requirements.txt
RUN pip install --no-cache-dir -r htmx-requirements.txt

# Copy source trees
COPY api-w-caching/ api-w-caching/
COPY htmx/ htmx/

# Production launch script
COPY start-prod.sh start-prod.sh
RUN chmod +x start-prod.sh

# Public UI port and internal API port.
EXPOSE 8001 8002

CMD ["./start-prod.sh"]
