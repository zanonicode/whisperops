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
    error: str | None = Field(
        default=None,
        description="High-level error type if execution failed: 'timeout' | 'memory limit exceeded' | None",
    )
