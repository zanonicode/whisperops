from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ExecuteRequest(BaseModel):
    code: str = Field(description="Python code to execute in the sandbox")


class ExecuteResponse(BaseModel):
    stdout: str = Field(default="", description="Captured standard output from the execution")
    stderr: str = Field(default="", description="Captured standard error from the execution")
    exit_code: int = Field(description="Subprocess exit code (0 = success)")
    chart_url: str | None = Field(
        default=None, description="Signed URL to the uploaded chart artifact, if any"
    )
    chart_urls: list[str] = Field(
        default_factory=list,
        description="Signed URLs for all uploaded chart artifacts (multi-chart support)",
    )
    chart_kind: Literal["png", "json", "mixed"] | None = Field(
        default=None,
        description="Kind of chart artifacts produced: png, json, or mixed",
    )
    error: str | None = Field(
        default=None,
        description="High-level error type if execution failed: 'timeout' | 'memory limit exceeded' | None",
    )
