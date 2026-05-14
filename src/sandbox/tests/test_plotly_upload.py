"""Tests for _upload_charts — verifies PNG+JSON dispatch and content-type mapping."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from app.mcp_server import _upload_charts


def _make_artifacts(tmp_path: Path, kinds: list[str]) -> None:
    for kind in kinds:
        if kind == "png":
            (tmp_path / "chart.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        elif kind == "json":
            (tmp_path / "chart.json").write_text(json.dumps({"data": []}))


@pytest.fixture
def mock_gcs():
    blob = MagicMock()
    blob.generate_signed_url.return_value = "https://storage.googleapis.com/signed"
    bucket = MagicMock()
    bucket.blob.return_value = blob
    client = MagicMock()
    client.bucket.return_value = bucket

    with (
        patch("app.mcp_server.AGENT_BUCKET", "test-bucket"),
        patch("app.mcp_server.GOOGLE_CREDS", "/fake/creds.json"),
        patch("pathlib.Path.exists", return_value=True),
        patch("google.cloud.storage.Client.from_service_account_json", return_value=client),
    ):
        yield client, bucket, blob


def test_returns_empty_when_no_agent_bucket():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        _make_artifacts(tmp_path, ["png"])
        with patch("app.mcp_server.AGENT_BUCKET", ""):
            result = _upload_charts(tmp_path)
    assert result == []


def test_returns_empty_when_no_artifacts():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        with patch("app.mcp_server.AGENT_BUCKET", "test-bucket"):
            result = _upload_charts(tmp_path)
    assert result == []


def test_uploads_png_with_correct_content_type(mock_gcs):
    client, bucket, blob = mock_gcs
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        _make_artifacts(tmp_path, ["png"])
        result = _upload_charts(tmp_path)
    assert len(result) == 1
    call_args = blob.upload_from_filename.call_args
    assert call_args.kwargs.get("content_type") == "image/png"


def test_uploads_json_with_correct_content_type(mock_gcs):
    client, bucket, blob = mock_gcs
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        _make_artifacts(tmp_path, ["json"])
        result = _upload_charts(tmp_path)
    assert len(result) == 1
    call_args = blob.upload_from_filename.call_args
    assert call_args.kwargs.get("content_type") == "application/json"


def test_uploads_both_png_and_json(mock_gcs):
    client, bucket, blob = mock_gcs
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        _make_artifacts(tmp_path, ["png", "json"])
        result = _upload_charts(tmp_path)
    assert len(result) == 2
