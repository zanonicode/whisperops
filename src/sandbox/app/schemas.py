from typing import Literal

from pydantic import BaseModel, Field


class ExecuteRequest(BaseModel):
    code: str = Field(description="Python code to execute in the sandbox")
    dataset_id: Literal["california-housing", "online-retail-ii", "spotify-tracks"] = Field(
        description="Dataset identifier — maps to a CSV file in the shared GCS bucket"
    )
    sa_key_b64: str = Field(description="Base64-encoded GCP service account JSON key")
    agent_id: str = Field(description="Agent identifier for tracing and artifact isolation")
    agent_bucket: str = Field(description="Per-agent GCS bucket name for artifact upload")
    dataset_signed_url: str = Field(description="Signed URL to read the dataset CSV")


class ExecuteResponse(BaseModel):
    stdout: str = Field(default="", description="Captured standard output from the execution")
    stderr: str = Field(default="", description="Captured standard error from the execution")
    exit_code: int = Field(description="Subprocess exit code (0 = success)")
    chart_url: str | None = Field(
        default=None, description="Signed URL to the uploaded chart artifact, if any"
    )
    error: str | None = Field(
        default=None,
        description="High-level error type if execution failed: 'timeout' | 'memory limit exceeded' | None",
    )
