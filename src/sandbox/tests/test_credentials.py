import base64
from pathlib import Path

import pytest

from app.credentials import scoped_credentials


def test_credential_file_created_during_context():
    sa_key_b64 = base64.b64encode(b'{"type": "service_account", "key": "test"}').decode()
    with scoped_credentials(sa_key_b64) as cred_path:
        assert Path(cred_path).exists()
        assert Path(cred_path).stat().st_size > 0
        assert oct(Path(cred_path).stat().st_mode)[-3:] == "600"


def test_credential_file_deleted_after_context():
    sa_key_b64 = base64.b64encode(b'{"type": "service_account", "key": "test"}').decode()
    captured_path: str | None = None
    with scoped_credentials(sa_key_b64) as cred_path:
        captured_path = cred_path

    assert captured_path is not None
    assert not Path(captured_path).exists()


def test_credential_file_deleted_on_exception():
    sa_key_b64 = base64.b64encode(b'{"type": "service_account", "key": "test"}').decode()
    captured_path: str | None = None

    with pytest.raises(ValueError), scoped_credentials(sa_key_b64) as cred_path:
        captured_path = cred_path
        raise ValueError("simulated error")

    assert captured_path is not None
    assert not Path(captured_path).exists()


def test_credential_file_contains_decoded_data():
    original = b'{"type": "service_account", "project_id": "test-project"}'
    sa_key_b64 = base64.b64encode(original).decode()
    with scoped_credentials(sa_key_b64) as cred_path:
        content = Path(cred_path).read_bytes()
        assert content == original
