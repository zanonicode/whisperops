"""MCP server for the sandbox — exposes execute_python over streamable-HTTP.

The sandbox runs **per agent** (one Deployment in each `agent-{name}`
namespace). At startup it downloads its single configured dataset from
the shared `whisperops-datasets` GCS bucket using the agent's mounted
service-account key. Any chart the user code saves gets uploaded to the
agent's own GCS bucket and surfaced as a markdown image in the tool
response.

Configuration (env, set on the Deployment):
  - DATASET_ID         e.g. "california-housing"   (the only dataset this
                                                    sandbox will load)
  - AGENT_BUCKET       e.g. "agent-housing-demo"   (per-agent output bucket)
  - DATASETS_BUCKET    default "whisperops-datasets"
  - GOOGLE_APPLICATION_CREDENTIALS  path to mounted SA key JSON
                                    (default /var/run/gcp/credentials.json)
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import uuid
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .observability import logger, tracer

EXECUTION_TIMEOUT_S = int(os.getenv("EXECUTION_TIMEOUT_S", "60"))

DATASET_ID = os.getenv("DATASET_ID", "california-housing")
AGENT_BUCKET = os.getenv("AGENT_BUCKET", "")
DATASETS_BUCKET = os.getenv("DATASETS_BUCKET", "whisperops-datasets")

DATASET_LOCAL_PATH = Path(f"/tmp/dataset-{DATASET_ID}.csv")

GOOGLE_CREDS = os.getenv(
    "GOOGLE_APPLICATION_CREDENTIALS", "/var/run/gcp/credentials.json"
)

_TRANSPORT = TransportSecuritySettings(enable_dns_rebinding_protection=False)
mcp = FastMCP("sandbox", streamable_http_path="/", transport_security=_TRANSPORT)

# kagent's tool registry has a UNIQUE constraint on tool.name globally
# (not scoped per-ToolServer). Multiple agents each exposing `execute_python`
# from their own sandbox MCP would collide on the second registration.
# Namespace the tool name per agent so all N agents can register concurrently.
# AGENT_NAME is injected by sandbox.yaml.njk via the Backstage scaffolder.
# Hyphens become underscores since some MCP/kagent paths reject them.
_AGENT_NAME = os.getenv("AGENT_NAME", "default").replace("-", "_")
_TOOL_NAME = f"execute_python_{_AGENT_NAME}"


_PRELUDE = """
import json, sys, os
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
df = pd.read_csv({path!r})
OUT_DIR = {out_dir!r}
"""


def _ensure_dataset() -> Path:
    """Download the configured dataset from GCS once, then cache locally."""
    if DATASET_LOCAL_PATH.exists() and DATASET_LOCAL_PATH.stat().st_size > 0:
        return DATASET_LOCAL_PATH

    if not Path(GOOGLE_CREDS).exists():
        raise RuntimeError(
            f"GOOGLE_APPLICATION_CREDENTIALS={GOOGLE_CREDS} missing; "
            "cannot fetch dataset from GCS"
        )

    from google.cloud import storage

    client = storage.Client.from_service_account_json(GOOGLE_CREDS)
    bucket = client.bucket(DATASETS_BUCKET)
    # Datasets bucket convention: "{dataset_id}.csv".
    blob = bucket.blob(f"{DATASET_ID}.csv")
    if not blob.exists():
        raise FileNotFoundError(
            f"dataset blob '{DATASET_ID}.csv' not found in gs://{DATASETS_BUCKET}/"
        )

    DATASET_LOCAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    logger.info("Downloading dataset gs://%s/%s -> %s", DATASETS_BUCKET, blob.name, DATASET_LOCAL_PATH)
    blob.download_to_filename(str(DATASET_LOCAL_PATH))
    return DATASET_LOCAL_PATH


def _upload_pngs(tmp_dir: Path) -> list[str]:
    """Upload every *.png under tmp_dir to gs://AGENT_BUCKET/charts/.
    Return signed URLs so the LLM can embed them in the response."""
    pngs = sorted(tmp_dir.glob("*.png"))
    if not pngs or not AGENT_BUCKET:
        return []
    if not Path(GOOGLE_CREDS).exists():
        logger.warning("GOOGLE_APPLICATION_CREDENTIALS missing, skipping chart upload")
        return []
    try:
        from google.cloud import storage
        client = storage.Client.from_service_account_json(GOOGLE_CREDS)
        bucket = client.bucket(AGENT_BUCKET)
        urls: list[str] = []
        for png in pngs:
            blob_name = f"charts/{uuid.uuid4().hex}-{png.name}"
            blob = bucket.blob(blob_name)
            blob.upload_from_filename(str(png), content_type="image/png")
            try:
                signed = blob.generate_signed_url(version="v4", expiration=3600)
                urls.append(signed)
            except Exception as exc:
                logger.warning("signed-URL failed (%s); falling back to gs:// path", exc)
                urls.append(f"gs://{AGENT_BUCKET}/{blob_name}")
        return urls
    except Exception:
        logger.exception("chart upload failed")
        return []


@mcp.tool(name=_TOOL_NAME)
def execute_python(code: str) -> str:
    """Run Python in a sandboxed subprocess against this agent's dataset.

    Pre-loaded names available in the user code:
      - `pd`, `np` — pandas/numpy
      - `plt` — matplotlib.pyplot (Agg backend; safe in headless env)
      - `df` — DataFrame from the configured dataset
      - `OUT_DIR` — string path; save matplotlib PNGs here. They get
        auto-uploaded to the agent's GCS bucket and the tool response
        includes a markdown image link for each.

    Use `print(...)` to return numerical results to the caller. Use
    `plt.savefig(os.path.join(OUT_DIR, "chart.png"))` to publish a chart.

    Args:
        code: Python source to run (str).

    Returns:
        A text block with STDOUT, STDERR, exit_code, plus markdown image
        links for any uploaded charts.
    """
    with tracer.start_as_current_span("sandbox.mcp.execute_python") as span:
        span.set_attribute("dataset.id", DATASET_ID)
        span.set_attribute("agent.bucket", AGENT_BUCKET)
        span.set_attribute("code.length", len(code))

        try:
            dataset_path = _ensure_dataset()
        except Exception as exc:  # noqa: BLE001
            logger.exception("dataset fetch failed")
            return f"ERROR: cannot load dataset {DATASET_ID!r}: {exc}"

        with tempfile.TemporaryDirectory(prefix="exec-") as tmp:
            tmp_path = Path(tmp)
            full_code = (
                _PRELUDE.format(path=str(dataset_path), out_dir=str(tmp_path))
                + "\n"
                + code
            )
            try:
                proc = subprocess.run(
                    ["python", "-c", full_code],
                    cwd=tmp,
                    env={
                        "PATH": "/usr/local/bin:/usr/bin:/bin",
                        "HOME": "/tmp",
                        "MPLBACKEND": "Agg",
                    },
                    capture_output=True,
                    text=True,
                    timeout=EXECUTION_TIMEOUT_S,
                )
            except subprocess.TimeoutExpired:
                span.set_attribute("execution.error", "timeout")
                return _format_result("", "", -1, error="timeout", chart_urls=[])
            except Exception as exc:  # noqa: BLE001
                span.set_attribute("execution.error", "execution_error")
                logger.exception("execute_python crashed")
                return _format_result(
                    "", str(exc), -1, error="execution_error", chart_urls=[]
                )

            chart_urls: list[str] = []
            if proc.returncode == 0:
                chart_urls = _upload_pngs(tmp_path)
                span.set_attribute("charts.uploaded", len(chart_urls))

            span.set_attribute("execution.exit_code", proc.returncode)
            return _format_result(
                proc.stdout, proc.stderr, proc.returncode, error=None, chart_urls=chart_urls
            )


def _format_result(
    stdout: str, stderr: str, exit_code: int, error: str | None, chart_urls: list[str]
) -> str:
    parts: list[str] = []
    if stdout:
        parts.append(f"STDOUT:\n{stdout.rstrip()}")
    if stderr:
        parts.append(f"STDERR:\n{stderr.rstrip()}")
    if error:
        parts.append(f"ERROR: {error}")
    parts.append(f"exit_code: {exit_code}")
    if chart_urls:
        md = "\n".join(f"![chart {i+1}]({u})" for i, u in enumerate(chart_urls))
        parts.append(f"CHARTS:\n{md}")
    return "\n\n".join(parts)
