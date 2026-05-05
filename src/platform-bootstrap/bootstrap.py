import hashlib
import io
import logging
import os
import sys
from typing import Any

import pandas as pd
from google.cloud import storage
from openai import OpenAI
from pydantic import ValidationError
from supabase import create_client

from profile_schema import ColumnProfile, DatasetProfile

logging.basicConfig(
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}',
    level=logging.INFO,
)
logger = logging.getLogger("platform-bootstrap")

DATASETS_BUCKET = os.environ["DATASETS_BUCKET"]
SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]

DATASET_CONFIGS: list[dict[str, str]] = [
    {
        "dataset_id": "california-housing",
        "csv_filename": "california-housing-prices.csv",
        "archetype": "regression",
    },
    {
        "dataset_id": "online-retail-ii",
        "csv_filename": "online_retail_II.csv",
        "archetype": "time-series",
    },
    {
        "dataset_id": "spotify-tracks",
        "csv_filename": "spotify-tracks.csv",
        "archetype": "exploratory",
    },
]


def download_csv(gcs_client: storage.Client, bucket_name: str, filename: str) -> bytes:
    bucket = gcs_client.bucket(bucket_name)
    blob = bucket.blob(filename)
    return blob.download_as_bytes()


def compute_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _safe_dtype(dtype: Any) -> str:
    dtype_str = str(dtype)
    mapping = {
        "int64": "int64",
        "float64": "float64",
        "object": "object",
        "bool": "bool",
        "category": "category",
    }
    if dtype_str in mapping:
        return mapping[dtype_str]
    if "datetime" in dtype_str:
        return "datetime64[ns]"
    if "int" in dtype_str:
        return "int64"
    if "float" in dtype_str:
        return "float64"
    return "object"


def profile_dataframe(df: pd.DataFrame) -> list[ColumnProfile]:
    columns = []
    for col in df.columns:
        series = df[col]
        null_rate = float(series.isna().mean())
        n_unique = int(series.nunique(dropna=True))
        sample_values = [str(v) for v in series.dropna().unique()[:10]]
        dtype = _safe_dtype(series.dtype)

        col_min: float | None = None
        col_max: float | None = None
        col_mean: float | None = None
        if pd.api.types.is_numeric_dtype(series):
            col_min = float(series.min()) if not series.isna().all() else None
            col_max = float(series.max()) if not series.isna().all() else None
            col_mean = float(series.mean()) if not series.isna().all() else None

        columns.append(
            ColumnProfile(
                name=col,
                dtype=dtype,
                null_rate=null_rate,
                n_unique=n_unique,
                sample_values=sample_values,
                min=col_min,
                max=col_max,
                mean=col_mean,
            )
        )
    return columns


def generate_description(profile: dict, openai_client: OpenAI) -> str:
    prompt = f"""
You are a data analyst. Write a 2-3 sentence description of this dataset for a RAG search index.
Include: what the dataset contains, key columns, rough shape, and what questions it can answer.

Dataset: {profile['dataset_id']}
Archetype: {profile['archetype']}
Rows: {profile['n_rows']:,}
Columns: {profile['n_cols']}
Column names: {[c['name'] for c in profile['columns']]}
"""
    response = openai_client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
        max_tokens=200,
        temperature=0.3,
    )
    return response.choices[0].message.content or ""


def embed_description(description: str, openai_client: OpenAI) -> list[float]:
    response = openai_client.embeddings.create(
        model="text-embedding-3-small",
        input=description,
    )
    return response.data[0].embedding


def check_existing(supabase_client: Any, dataset_id: str, source_hash: str) -> bool:
    result = (
        supabase_client.table("dataset_profiles")
        .select("source_hash")
        .eq("dataset_id", dataset_id)
        .execute()
    )
    rows = result.data or []
    return any(r.get("source_hash") == source_hash for r in rows)


def upsert_profile(supabase_client: Any, profile: DatasetProfile, embedding: list[float]) -> None:
    payload = {
        "dataset_id": profile.dataset_id,
        "csv_filename": profile.csv_filename,
        "n_rows": profile.n_rows,
        "n_cols": profile.n_cols,
        "archetype": profile.archetype,
        "description": profile.description,
        "source_hash": profile.source_hash,
        "columns": [c.model_dump() for c in profile.columns],
        "embedding": embedding,
    }
    supabase_client.table("dataset_profiles").upsert(
        payload, on_conflict="dataset_id"
    ).execute()


def process_dataset(config: dict, gcs_client: storage.Client, openai_client: OpenAI, supabase_client: Any) -> None:
    dataset_id = config["dataset_id"]
    csv_filename = config["csv_filename"]
    archetype = config["archetype"]

    logger.info("Processing dataset: %s", dataset_id)

    csv_bytes = download_csv(gcs_client, DATASETS_BUCKET, csv_filename)
    source_hash = compute_hash(csv_bytes)

    if check_existing(supabase_client, dataset_id, source_hash):
        logger.info("Dataset %s already profiled with same hash; skipping", dataset_id)
        return

    df = pd.read_csv(io.BytesIO(csv_bytes), low_memory=False)
    columns = profile_dataframe(df)

    partial_profile = {
        "dataset_id": dataset_id,
        "archetype": archetype,
        "n_rows": len(df),
        "n_cols": len(df.columns),
        "columns": [c.model_dump() for c in columns],
    }

    description = generate_description(partial_profile, openai_client)
    embedding = embed_description(description, openai_client)

    profile = DatasetProfile(
        dataset_id=dataset_id,
        csv_filename=csv_filename,
        n_rows=len(df),
        n_cols=len(df.columns),
        columns=columns,
        archetype=archetype,
        description=description,
        source_hash=source_hash,
    )

    upsert_profile(supabase_client, profile, embedding)
    logger.info("Upserted profile for %s (%d rows, %d cols)", dataset_id, profile.n_rows, profile.n_cols)


def main() -> None:
    gcs_client = storage.Client()
    openai_client = OpenAI(api_key=OPENAI_API_KEY)
    supabase_client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

    errors: list[str] = []
    for config in DATASET_CONFIGS:
        try:
            process_dataset(config, gcs_client, openai_client, supabase_client)
        except ValidationError as exc:
            logger.error("Profile validation error for %s: %s", config["dataset_id"], exc)
            errors.append(config["dataset_id"])
        except Exception as exc:
            logger.error("Failed to process %s: %s", config["dataset_id"], exc, exc_info=True)
            errors.append(config["dataset_id"])

    if errors:
        logger.error("Bootstrap completed with errors for: %s", errors)
        sys.exit(1)

    logger.info("Bootstrap complete. All datasets profiled successfully.")


if __name__ == "__main__":
    main()
