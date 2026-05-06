import time

from app.execution import run_in_subprocess


def test_successful_execution():
    result = run_in_subprocess(
        code="print('hello world')",
        timeout_s=10,
        memory_bytes=512 * 1024 * 1024,
    )
    assert result.exit_code == 0
    assert "hello world" in result.stdout
    assert result.error is None


def test_timeout_enforcement():
    start = time.monotonic()
    result = run_in_subprocess(
        code="import time; time.sleep(30)",
        timeout_s=2,
        memory_bytes=512 * 1024 * 1024,
    )
    elapsed = time.monotonic() - start

    assert result.exit_code == -1
    assert result.error == "timeout"
    assert elapsed < 5


def test_nonzero_exit_code_on_syntax_error():
    result = run_in_subprocess(
        code="this is not valid python !!!",
        timeout_s=10,
        memory_bytes=512 * 1024 * 1024,
    )
    assert result.exit_code != 0
    assert result.error is None


def test_tmp_dir_is_created():
    result = run_in_subprocess(
        code="import os; print(os.environ.get('OUT_DIR', 'missing'))",
        timeout_s=10,
        memory_bytes=512 * 1024 * 1024,
    )
    assert result.exit_code == 0
    assert result.tmp_dir in result.stdout or result.stdout.strip() != "missing"
