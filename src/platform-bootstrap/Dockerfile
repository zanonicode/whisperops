FROM python:3.12-slim

RUN groupadd -r bootstrap && useradd -r -g bootstrap bootstrap

WORKDIR /app

RUN pip install --upgrade pip

COPY pyproject.toml .
RUN pip install --no-cache-dir \
    anthropic==0.40.0 \
    openai==1.57.4 \
    supabase==2.10.0 \
    google-cloud-storage==2.18.2 \
    pandas==2.2.3 \
    numpy==2.1.3 \
    pydantic==2.10.3

COPY bootstrap.py profile_schema.py ./

USER bootstrap

CMD ["python", "bootstrap.py"]
