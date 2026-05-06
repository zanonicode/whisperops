from contextlib import asynccontextmanager

from fastapi import FastAPI
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from .mcp_server import mcp
from .observability import logger


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Wire the MCP session manager's lifespan into FastAPI's.

    Without this, Starlette's app.mount() drops the inner app's lifespan
    events and the MCP server crashes per-request with
    "Task group is not initialized".
    """
    async with mcp.session_manager.run():
        yield


app = FastAPI(title="Sandbox", version="0.2.0", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

app.mount("/mcp", mcp.streamable_http_app())


@app.get("/healthz")
async def healthz() -> dict:
    logger.debug("healthz called")
    return {"status": "ok"}
