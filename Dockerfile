FROM python:3.12-slim

WORKDIR /app

# Install API dependencies
COPY api-w-caching/requirements.txt api-requirements.txt
RUN pip install --no-cache-dir -r api-requirements.txt

# Install UI dependencies (python-dotenv not yet in htmx/requirements.txt)
COPY htmx/requirements.txt htmx-requirements.txt
RUN pip install --no-cache-dir -r htmx-requirements.txt python-dotenv

# Copy source trees
COPY api-w-caching/ api-w-caching/
COPY htmx/ htmx/

# Production launch script
COPY start-prod.sh start-prod.sh
RUN chmod +x start-prod.sh

# Railway injects PORT at runtime; document the default UI port.
EXPOSE 8002

CMD ["./start-prod.sh"]
