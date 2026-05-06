import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from .artifact_upload import upload_artifacts
from .credentials import scoped_credentials
from .execution import run_in_subprocess
from .mcp_server import mcp
from .observability import logger, tracer
from .schemas import ExecuteRequest, ExecuteResponse


# Wire the MCP session manager's lifespan into FastAPI's. Without this,
# Starlette's app.mount() drops the inner app's lifespan events and the
# MCP server crashes per-request with "Task group is not initialized".
@asynccontextmanager
async def lifespan(_app: FastAPI):
    async with mcp.session_manager.run():
        yield


app = FastAPI(title="Sandbox", version="0.1.0", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

# Mount the MCP streamable-HTTP server at /mcp.
# kagent ToolServer.spec.config.streamableHttp.url points here.
app.mount("/mcp", mcp.streamable_http_app())


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}


@app.post("/execute", response_model=ExecuteResponse)
async def execute(req: ExecuteRequest) -> ExecuteResponse:
    with tracer.start_as_current_span("sandbox.execute") as span:
        span.set_attribute("agent.id", req.agent_id)
        span.set_attribute("dataset.id", req.dataset_id)
        logger.info("Executing code", extra={"agent_id": req.agent_id, "dataset_id": req.dataset_id})

        memory_bytes = int(os.getenv("MEMORY_LIMIT_BYTES", str(3 * 1024**3)))
        timeout_s = int(os.getenv("EXECUTION_TIMEOUT_S", "60"))

        with scoped_credentials(req.sa_key_b64) as cred_path:
            result = run_in_subprocess(
                code=req.code,
                cred_path=cred_path,
                dataset_signed_url=req.dataset_signed_url,
                timeout_s=timeout_s,
                memory_bytes=memory_bytes,
            )
            span.set_attribute("execution.exit_code", result.exit_code)
            span.set_attribute("execution.error", result.error or "none")

            chart_url: str | None = None
            if result.exit_code == 0:
                try:
                    chart_url = upload_artifacts(
                        tmp_dir=result.tmp_dir,
                        bucket=req.agent_bucket,
                        cred_path=cred_path,
                    )
                except Exception as exc:
                    logger.warning("Artifact upload failed: %s", exc)

            return ExecuteResponse(
                stdout=result.stdout,
                stderr=result.stderr,
                exit_code=result.exit_code,
                chart_url=chart_url,
                error=result.error,
            )
