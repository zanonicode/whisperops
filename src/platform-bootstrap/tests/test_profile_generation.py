from unittest.mock import MagicMock

import pandas as pd
import pytest

from profile_schema import ColumnProfile, DatasetProfile


def make_sample_df() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "longitude": [-122.23, -122.22, -122.24, -122.25, -122.26],
            "latitude": [37.88, 37.86, 37.85, 37.85, 37.85],
            "housing_median_age": [41.0, 21.0, 52.0, 52.0, 52.0],
            "total_rooms": [880.0, 7099.0, 1467.0, 1274.0, 1627.0],
            "ocean_proximity": ["NEAR BAY", "NEAR BAY", "NEAR BAY", "NEAR BAY", "NEAR BAY"],
            "median_house_value": [452600.0, 358500.0, 352100.0, 341300.0, 342200.0],
        }
    )


def test_column_profile_numeric():
    df = make_sample_df()
    from bootstrap import profile_dataframe

    columns = profile_dataframe(df)
    longitude_col = next(c for c in columns if c.name == "longitude")

    assert longitude_col.dtype == "float64"
    assert longitude_col.null_rate == 0.0
    assert longitude_col.min is not None
    assert longitude_col.max is not None
    assert longitude_col.mean is not None


def test_column_profile_categorical():
    df = make_sample_df()
    from bootstrap import profile_dataframe

    columns = profile_dataframe(df)
    ocean_col = next(c for c in columns if c.name == "ocean_proximity")

    assert ocean_col.dtype == "object"
    assert ocean_col.null_rate == 0.0
    assert ocean_col.min is None
    assert ocean_col.max is None
    assert len(ocean_col.sample_values) <= 10


def test_null_rate_calculation():
    df = pd.DataFrame({"col_a": [1.0, None, 3.0, None, 5.0]})
    from bootstrap import profile_dataframe

    columns = profile_dataframe(df)
    assert columns[0].null_rate == pytest.approx(0.4)


def test_source_hash_deterministic():
    from bootstrap import compute_hash

    data = b"some csv content"
    h1 = compute_hash(data)
    h2 = compute_hash(data)
    assert h1 == h2
    assert len(h1) == 64


def test_dataset_profile_schema_validates():
    profile = DatasetProfile(
        dataset_id="california-housing",
        csv_filename="california-housing-prices.csv",
        n_rows=20640,
        n_cols=9,
        columns=[
            ColumnProfile(
                name="median_house_value",
                dtype="float64",
                null_rate=0.0,
                n_unique=17606,
                sample_values=["452600.0", "358500.0"],
                min=14999.0,
                max=500001.0,
                mean=206855.8,
            )
        ],
        archetype="regression",
        description="California housing dataset with 20,640 rows.",
        source_hash="abc123" * 10 + "abcd",
    )
    assert profile.dataset_id == "california-housing"
    assert profile.csv_filename == "california-housing-prices.csv"
    assert profile.archetype == "regression"


def test_profile_schema_rejects_invalid_archetype():
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        DatasetProfile(
            dataset_id="california-housing",
            csv_filename="california-housing-prices.csv",
            n_rows=1000,
            n_cols=5,
            columns=[],
            archetype="invalid-type",
            description="test",
            source_hash="abc",
        )


def test_check_existing_skips_on_same_hash():
    from bootstrap import check_existing

    mock_supabase = MagicMock()
    mock_result = MagicMock()
    mock_result.data = [{"source_hash": "matching-hash-123"}]
    mock_supabase.table.return_value.select.return_value.eq.return_value.execute.return_value = mock_result

    assert check_existing(mock_supabase, "california-housing", "matching-hash-123") is True


def test_check_existing_returns_false_on_different_hash():
    from bootstrap import check_existing

    mock_supabase = MagicMock()
    mock_result = MagicMock()
    mock_result.data = [{"source_hash": "old-hash-456"}]
    mock_supabase.table.return_value.select.return_value.eq.return_value.execute.return_value = mock_result

    assert check_existing(mock_supabase, "california-housing", "new-hash-789") is False
