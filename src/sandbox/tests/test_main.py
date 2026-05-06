from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_mcp_endpoint_exists():
    response = client.get("/mcp/")
    assert response.status_code in (200, 405, 406)
