# syntax=docker/dockerfile:1.4
# ONyc Daily Brief — web viewer image.
# Build context is the parent pfx/ directory so the design-system tokens can be
# copied alongside the app:
#   docker build -f taq-hackathon/app/Dockerfile -t onyc-brief .

FROM python:3.11-slim AS runtime

WORKDIR /app

COPY taq-hackathon/app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY taq-hackathon/app ./app

# Design-system token and theme files (the app imports from app/static/css/)
COPY design-system-260422/colors_and_type.css              ./app/static/css/colors_and_type.css
COPY design-system-260422/htmx/app/static/css/theme.css    ./app/static/css/theme.css

ENV PORT=8003
EXPOSE 8003

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8003"]
