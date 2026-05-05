import resource
import subprocess
import tempfile
from dataclasses import dataclass


@dataclass
class ExecResult:
    stdout: str
    stderr: str
    exit_code: int
    tmp_dir: str
    error: str | None


def _setlimits(memory_bytes: int) -> None:
    resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
    resource.setrlimit(resource.RLIMIT_CPU, (60, 60))


def run_in_subprocess(
    code: str,
    cred_path: str,
    dataset_signed_url: str,
    timeout_s: int,
    memory_bytes: int,
) -> ExecResult:
    tmp = tempfile.mkdtemp(prefix="exec-")
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "GOOGLE_APPLICATION_CREDENTIALS": cred_path,
        "DATASET_URL": dataset_signed_url,
        "OUT_DIR": tmp,
        "HOME": "/tmp",
    }
    try:
        proc = subprocess.run(
            ["python", "-c", code],
            cwd=tmp,
            env=env,
            preexec_fn=lambda: _setlimits(memory_bytes),
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        return ExecResult(proc.stdout, proc.stderr, proc.returncode, tmp, None)
    except subprocess.TimeoutExpired:
        return ExecResult("", "", -1, tmp, "timeout")
    except MemoryError:
        return ExecResult("", "", -1, tmp, "memory limit exceeded")
    except Exception as exc:
        return ExecResult("", str(exc), -1, tmp, "execution error")
