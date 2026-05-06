# Build context: repository root.
# Build command: `docker buildx build -f src/sandbox/Dockerfile -t <tag> --platform=linux/amd64 .`
FROM python:3.12-slim AS builder

WORKDIR /build

RUN pip install --upgrade pip hatchling

COPY src/sandbox/pyproject.toml .
RUN pip install --no-cache-dir \
    fastapi==0.115.5 \
    uvicorn[standard]==0.32.1 \
    "pydantic>=2.11.0,<3" \
    google-cloud-storage==2.18.2 \
    opentelemetry-api==1.28.2 \
    opentelemetry-sdk==1.28.2 \
    opentelemetry-instrumentation-fastapi==0.49b2 \
    opentelemetry-exporter-otlp-proto-grpc==1.28.2 \
    mcp==1.27.0

RUN pip install --no-cache-dir \
    pandas==2.2.3 \
    numpy==2.1.3 \
    scipy==1.14.1 \
    scikit-learn==1.5.2 \
    matplotlib==3.9.3 \
    seaborn==0.13.2 \
    plotly==5.24.1

FROM python:3.12-slim AS runtime

RUN groupadd -r sandbox && useradd -r -g sandbox sandbox

WORKDIR /app

COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin/uvicorn /usr/local/bin/uvicorn

RUN find /usr/local/lib/python3.12/site-packages -name "pip" -type d -exec rm -rf {} + 2>/dev/null || true
RUN find /usr/local/lib/python3.12/site-packages -name "pip*" -delete 2>/dev/null || true

COPY src/sandbox/app/ ./app/

# Demo dataset baked into the image (1.4 MB). Replaced by per-agent
# bucket-mounted CSV in a future revision; sufficient for MVP.
COPY datasets/california-housing-prices.csv /app/datasets/california-housing-prices.csv

USER sandbox

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "info"]
