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
  - AGENT_NAME         injected by sandbox.yaml.njk via Backstage scaffolder
  - POD_NAMESPACE      downward API (fieldRef spec.namespace)
"""

from __future__ import annotations

import mimetypes
import os
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .observability import (
    logger,
    sandbox_duration,
    sandbox_executions,
    sandbox_oom,
    sandbox_timeouts,
    tracer,
)

EXECUTION_TIMEOUT_S = int(os.getenv("EXECUTION_TIMEOUT_S", "60"))

DATASET_ID = os.getenv("DATASET_ID", "california-housing")
AGENT_BUCKET = os.getenv("AGENT_BUCKET", "")
DATASETS_BUCKET = os.getenv("DATASETS_BUCKET", "whisperops-datasets")

DATASET_LOCAL_PATH = Path(f"/tmp/dataset-{DATASET_ID}.csv")

GOOGLE_CREDS = os.getenv(
    "GOOGLE_APPLICATION_CREDENTIALS", "/var/run/gcp/credentials.json"
)

_AGENT_NAME = os.getenv("AGENT_NAME", "default").replace("-", "_")
AGENT_NAME_LABEL = os.getenv("AGENT_NAME", "default")
NAMESPACE = os.getenv("POD_NAMESPACE", AGENT_NAME_LABEL)

_TRANSPORT = TransportSecuritySettings(enable_dns_rebinding_protection=False)
mcp = FastMCP("sandbox", streamable_http_path="/", transport_security=_TRANSPORT)

# kagent's tool registry has a UNIQUE constraint on tool.name globally
# (not scoped per-ToolServer). Multiple agents each exposing `execute_python`
# from their own sandbox MCP would collide on the second registration.
# Namespace the tool name per agent so all N agents can register concurrently.
_TOOL_NAME = f"execute_python_{_AGENT_NAME}"


_PRELUDE = """
import json, sys, os
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import plotly.express as px
import plotly.graph_objects as go
import plotly.io as pio
pio.templates["whisperops_vercel"] = go.layout.Template(
    layout=go.Layout(
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        colorway=["#0070f3","#34d399","#a78bfa","#f97316","#ec4899","#facc15","#22d3ee","#f472b6"],
        font=dict(family="Geist Sans, ui-sans-serif, system-ui, sans-serif", color="#e4e4e7", size=13),
        title=dict(font=dict(family="Geist Sans, ui-sans-serif, system-ui, sans-serif", color="#f4f4f5", size=15), x=0.01, xanchor="left"),
        xaxis=dict(gridcolor="#333", linecolor="#444", tickcolor="#444", zerolinecolor="#444", tickfont=dict(color="#a1a1aa")),
        yaxis=dict(gridcolor="#333", linecolor="#444", tickcolor="#444", zerolinecolor="#444", tickfont=dict(color="#a1a1aa")),
        legend=dict(bgcolor="rgba(0,0,0,0)", bordercolor="#333", font=dict(color="#e4e4e7")),
        hoverlabel=dict(bgcolor="#18181b", bordercolor="#333", font=dict(color="#f4f4f5", family="Geist Sans, ui-sans-serif, system-ui, sans-serif")),
        margin=dict(l=48, r=24, t=48, b=48),
    )
)
pio.templates.default = "plotly_dark+whisperops_vercel"
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
    blob = bucket.blob(f"{DATASET_ID}.csv")
    if not blob.exists():
        raise FileNotFoundError(
            f"dataset blob '{DATASET_ID}.csv' not found in gs://{DATASETS_BUCKET}/"
        )

    DATASET_LOCAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    logger.info("Downloading dataset gs://%s/%s -> %s", DATASETS_BUCKET, blob.name, DATASET_LOCAL_PATH)
    blob.download_to_filename(str(DATASET_LOCAL_PATH))
    return DATASET_LOCAL_PATH


def _upload_charts(tmp_dir: Path) -> list[str]:
    """Upload every *.png AND *.json under tmp_dir to gs://AGENT_BUCKET/charts/.

    Returns signed URLs the LLM can embed via markdown image syntax.
    Content-type is set per extension: image/png or application/json.
    """
    if not AGENT_BUCKET:
        return []
    if not Path(GOOGLE_CREDS).exists():
        logger.warning("GOOGLE_APPLICATION_CREDENTIALS missing, skipping chart upload")
        return []

    artifacts = sorted([*tmp_dir.glob("*.png"), *tmp_dir.glob("*.json")])
    if not artifacts:
        return []

    try:
        from google.cloud import storage

        client = storage.Client.from_service_account_json(GOOGLE_CREDS)
        bucket = client.bucket(AGENT_BUCKET)
        urls: list[str] = []
        for art in artifacts:
            ext = art.suffix.lower()
            content_type = (
                "image/png"
                if ext == ".png"
                else "application/json"
                if ext == ".json"
                else mimetypes.guess_type(str(art))[0] or "application/octet-stream"
            )
            blob_name = f"charts/{uuid.uuid4().hex}-{art.name}"
            blob = bucket.blob(blob_name)
            blob.upload_from_filename(str(art), content_type=content_type)
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
      - `px`, `go` — plotly.express / plotly.graph_objects
      - `pio` — plotly.io (whisperops_vercel template already applied)
      - `df` — DataFrame from the configured dataset
      - `OUT_DIR` — string path; save charts here. Both *.png and *.json
        files are auto-uploaded to the agent's GCS bucket. The tool response
        includes a markdown image link for each chart URL.

    Preferred charting: ``fig.write_json(os.path.join(OUT_DIR, "chart.json"))``
    Fallback charting: ``plt.savefig(os.path.join(OUT_DIR, "chart.png"), dpi=150, bbox_inches="tight")``

    Use `print(...)` to return numerical results to the caller.

    Args:
        code: Python source to run (str).

    Returns:
        A text block with STDOUT, STDERR, exit_code, plus markdown image
        links for any uploaded charts.
    """
    attrs = {"agent_name": AGENT_NAME_LABEL, "namespace": NAMESPACE}

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
            t0 = time.monotonic()
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
                duration = time.monotonic() - t0
                span.set_attribute("execution.error", "timeout")
                sandbox_executions.add(1, {**attrs, "outcome": "error"})
                sandbox_timeouts.add(1, attrs)
                sandbox_duration.record(duration, attrs)
                return _format_result("", "", -1, error="timeout", chart_urls=[])
            except Exception as exc:  # noqa: BLE001
                duration = time.monotonic() - t0
                span.set_attribute("execution.error", "execution_error")
                logger.exception("execute_python crashed")
                sandbox_executions.add(1, {**attrs, "outcome": "error"})
                sandbox_duration.record(duration, attrs)
                return _format_result(
                    "", str(exc), -1, error="execution_error", chart_urls=[]
                )

            duration = time.monotonic() - t0
            span.set_attribute("execution.exit_code", proc.returncode)

            if proc.returncode in (137, -9):
                sandbox_oom.add(1, attrs)
                sandbox_executions.add(1, {**attrs, "outcome": "error"})
                sandbox_duration.record(duration, attrs)
            elif proc.returncode == 0:
                sandbox_executions.add(1, {**attrs, "outcome": "success"})
                sandbox_duration.record(duration, attrs)
            else:
                sandbox_executions.add(1, {**attrs, "outcome": "error"})
                sandbox_duration.record(duration, attrs)

            chart_urls: list[str] = []
            if proc.returncode == 0:
                chart_urls = _upload_charts(tmp_path)
                span.set_attribute("charts.uploaded", len(chart_urls))

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
