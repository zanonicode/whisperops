"""MCP server layer wrapping the sandbox's Python execution.

Exposes a single tool `execute_python` over the MCP streamable-HTTP transport,
which is what kagent ToolServer (`spec.config.streamableHttp.url`) expects.

Design notes
------------
- This is a deliberately *simplified* surface vs. the FastAPI `/execute` route.
  The LLM (which supplies tool arguments) cannot reasonably know SA keys,
  signed URLs, or per-agent bucket names — those would have to come from
  server-side context or session metadata. Per-agent isolation is a real
  concern but separable from making the tool callable at all; first we
  prove the pipe works, then we layer auth in.
- For the demo, the sandbox process reads the dataset from a CSV baked
  into the image at `/app/datasets/`. Multi-dataset support and per-agent
  bucket writes can come later.
- `mcp.server.fastmcp.FastMCP` is mounted on the existing FastAPI app so
  one container serves both `/healthz` and `/mcp`. `streamable_http_path`
  is set to `/` because the outer FastAPI mount already adds `/mcp`.
"""

from __future__ import annotations

import os
import subprocess
import tempfile

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .observability import logger, tracer

DATASET_PATH = os.getenv(
    "SANDBOX_DATASET_PATH", "/app/datasets/california-housing-prices.csv"
)
EXECUTION_TIMEOUT_S = int(os.getenv("EXECUTION_TIMEOUT_S", "60"))

# DNS rebinding protection: kagent reaches us via cluster DNS like
# `sandbox.sandbox.svc.cluster.local`. FastMCP's default allow-list is
# localhost-only, which would reject those calls with HTTP 421.
# We turn the protection off rather than maintain a per-cluster host list —
# this service is only reachable from inside the cluster (NetworkPolicy
# limits ingress to `kagent-system`), so DNS rebinding is moot.
_TRANSPORT = TransportSecuritySettings(enable_dns_rebinding_protection=False)

# streamable_http_path="/" means the MCP endpoint is at the mount root;
# the outer FastAPI mount adds the "/mcp" prefix.
mcp = FastMCP(
    "sandbox",
    streamable_http_path="/",
    transport_security=_TRANSPORT,
)


_PRELUDE = """
import json, sys
import pandas as pd
import numpy as np
df = pd.read_csv({path!r})
"""


@mcp.tool()
def execute_python(code: str) -> str:
    """Execute Python code in a sandboxed subprocess.

    The code runs with these names pre-defined in scope:
      - `pd` — pandas
      - `np` — numpy
      - `df` — pandas DataFrame loaded from the configured CSV
      - `json`, `sys` — stdlib

    The subprocess is wall-clock-limited and stdout-captured. To return a
    result, `print()` it (or `print(json.dumps(...))` for structured output).

    Args:
        code: Python source to execute. Will be appended to the prelude that
            sets up `pd`, `np`, `df`.

    Returns:
        A combined string with STDOUT, STDERR, and any error reason.
    """
    with tracer.start_as_current_span("sandbox.mcp.execute_python") as span:
        span.set_attribute("dataset.path", DATASET_PATH)
        span.set_attribute("code.length", len(code))

        full_code = _PRELUDE.format(path=DATASET_PATH) + "\n" + code

        with tempfile.TemporaryDirectory(prefix="exec-") as tmp:
            try:
                proc = subprocess.run(
                    ["python", "-c", full_code],
                    cwd=tmp,
                    env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp"},
                    capture_output=True,
                    text=True,
                    timeout=EXECUTION_TIMEOUT_S,
                )
                logger.info(
                    "MCP execute_python finished",
                    extra={"exit_code": proc.returncode, "stdout_len": len(proc.stdout)},
                )
                span.set_attribute("execution.exit_code", proc.returncode)
                return _format_result(proc.stdout, proc.stderr, proc.returncode, error=None)
            except subprocess.TimeoutExpired:
                span.set_attribute("execution.error", "timeout")
                return _format_result("", "", -1, error="timeout")
            except Exception as exc:  # noqa: BLE001
                span.set_attribute("execution.error", "execution_error")
                logger.exception("MCP execute_python failed")
                return _format_result("", str(exc), -1, error="execution_error")


def _format_result(stdout: str, stderr: str, exit_code: int, error: str | None) -> str:
    parts = []
    if stdout:
        parts.append(f"STDOUT:\n{stdout.rstrip()}")
    if stderr:
        parts.append(f"STDERR:\n{stderr.rstrip()}")
    if error:
        parts.append(f"ERROR: {error}")
    parts.append(f"exit_code: {exit_code}")
    return "\n\n".join(parts)
