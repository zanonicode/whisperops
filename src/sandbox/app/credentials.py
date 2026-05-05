import base64
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def scoped_credentials(sa_key_b64: str):
    tmp_file = tempfile.NamedTemporaryFile(mode="wb", suffix=".json", delete=False)  # noqa: SIM115
    tmp_path = Path(tmp_file.name)
    try:
        tmp_file.write(base64.b64decode(sa_key_b64))
        tmp_file.close()
        os.chmod(tmp_path, 0o600)
        yield str(tmp_path)
    finally:
        tmp_path.unlink(missing_ok=True)
