from typing import Literal

from pydantic import BaseModel, Field


class ColumnProfile(BaseModel):
    name: str
    dtype: Literal["int64", "float64", "object", "datetime64[ns]", "bool", "category"]
    null_rate: float = Field(ge=0, le=1)
    n_unique: int
    sample_values: list[str] = Field(max_length=10)
    min: float | None = None
    max: float | None = None
    mean: float | None = None


class DatasetProfile(BaseModel):
    dataset_id: Literal["california-housing", "online-retail-ii", "spotify-tracks"]
    csv_filename: str = Field(
        description="Flat bucket key e.g. 'california-housing-prices.csv'"
    )
    n_rows: int
    n_cols: int
    columns: list[ColumnProfile]
    archetype: Literal["regression", "time-series", "exploratory"]
    description: str = Field(
        description="Human-readable summary embedded for pgvector similarity search"
    )
    source_hash: str = Field(
        description="SHA-256 of the CSV content used as idempotency key"
    )
