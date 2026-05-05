import base64
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _make_request_payload(**overrides) -> dict:
    sa_key_b64 = base64.b64encode(b'{"type": "service_account"}').decode()
    base = {
        "code": "print('hello')",
        "dataset_id": "california-housing",
        "sa_key_b64": sa_key_b64,
        "agent_id": "test-agent-abc1",
        "agent_bucket": "agent-test-abc1",
        "dataset_signed_url": "https://storage.googleapis.com/example/dataset.csv",
    }
    base.update(overrides)
    return base


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


@patch("app.main.upload_artifacts", return_value=None)
@patch("app.main.run_in_subprocess")
def test_execute_happy_path(mock_run, mock_upload):
    mock_run.return_value = MagicMock(
        stdout="42\n",
        stderr="",
        exit_code=0,
        tmp_dir="/tmp/exec-test",
        error=None,
    )

    response = client.post("/execute", json=_make_request_payload())
    assert response.status_code == 200
    data = response.json()
    assert data["exit_code"] == 0
    assert data["stdout"] == "42\n"
    assert data["error"] is None


@patch("app.main.upload_artifacts", return_value="https://storage.googleapis.com/signed/chart.png")
@patch("app.main.run_in_subprocess")
def test_execute_returns_chart_url(mock_run, mock_upload):
    mock_run.return_value = MagicMock(
        stdout="done\n",
        stderr="",
        exit_code=0,
        tmp_dir="/tmp/exec-test",
        error=None,
    )

    response = client.post("/execute", json=_make_request_payload())
    assert response.status_code == 200
    data = response.json()
    assert data["chart_url"] == "https://storage.googleapis.com/signed/chart.png"


@patch("app.main.run_in_subprocess")
def test_execute_timeout(mock_run):
    mock_run.return_value = MagicMock(
        stdout="",
        stderr="",
        exit_code=-1,
        tmp_dir="/tmp/exec-test",
        error="timeout",
    )

    response = client.post("/execute", json=_make_request_payload(code="import time; time.sleep(100)"))
    assert response.status_code == 200
    data = response.json()
    assert data["exit_code"] == -1
    assert data["error"] == "timeout"
    assert data["chart_url"] is None


def test_execute_missing_required_field():
    payload = _make_request_payload()
    del payload["code"]
    response = client.post("/execute", json=payload)
    assert response.status_code == 422


def test_execute_invalid_dataset_id():
    response = client.post("/execute", json=_make_request_payload(dataset_id="invalid-dataset"))
    assert response.status_code == 422
