FROM python:3.12-slim

RUN groupadd -r controller && useradd -r -g controller controller

WORKDIR /app

RUN pip install --upgrade pip

COPY pyproject.toml .
RUN pip install --no-cache-dir \
    kubernetes==31.0.0 \
    httpx==0.28.1 \
    pydantic==2.10.3 \
    opentelemetry-api==1.28.4 \
    opentelemetry-sdk==1.28.4 \
    opentelemetry-exporter-otlp-proto-grpc==1.28.4

COPY main.py ./

USER controller

CMD ["python", "main.py"]
