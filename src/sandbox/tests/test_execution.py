import tempfile
import time

from app.execution import run_in_subprocess


def test_successful_execution():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        f.write(b'{"type": "service_account"}')
        cred_path = f.name

    result = run_in_subprocess(
        code="print('hello world')",
        cred_path=cred_path,
        dataset_signed_url="https://example.com/dataset.csv",
        timeout_s=10,
        memory_bytes=512 * 1024 * 1024,
    )
    assert result.exit_code == 0
    assert "hello world" in result.stdout
    assert result.error is None


def test_timeout_enforcement():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        f.write(b'{"type": "service_account"}')
        cred_path = f.name

    start = time.monotonic()
    result = run_in_subprocess(
        code="import time; time.sleep(30)",
        cred_path=cred_path,
        dataset_signed_url="https://example.com/dataset.csv",
        timeout_s=2,
        memory_bytes=512 * 1024 * 1024,
    )
    elapsed = time.monotonic() - start

    assert result.exit_code == -1
    assert result.error == "timeout"
    assert elapsed < 5


def test_nonzero_exit_code_on_syntax_error():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        f.write(b'{"type": "service_account"}')
        cred_path = f.name

    result = run_in_subprocess(
        code="this is not valid python !!!",
        cred_path=cred_path,
        dataset_signed_url="https://example.com/dataset.csv",
        timeout_s=10,
        memory_bytes=512 * 1024 * 1024,
    )
    assert result.exit_code != 0
    assert result.error is None


def test_tmp_dir_is_created():
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        f.write(b'{"type": "service_account"}')
        cred_path = f.name

    result = run_in_subprocess(
        code="import os; print(os.environ.get('OUT_DIR', 'missing'))",
        cred_path=cred_path,
        dataset_signed_url="https://example.com/dataset.csv",
        timeout_s=10,
        memory_bytes=512 * 1024 * 1024,
    )
    assert result.exit_code == 0
    assert result.tmp_dir in result.stdout or result.stdout.strip() != "missing"
