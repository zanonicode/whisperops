# Error Handling Discipline

> **Purpose**: A discipline for **where** errors are caught, validated, and surfaced. The rule: validate at system boundaries; trust internal code and framework guarantees; don't add fallbacks for impossible cases. Streaming generators have one extra rule: emit at least one error event before any first-yield path can fail.
> **Confidence**: 0.95
> **MCP Validated**: 2026-04-27

## Overview

Two failure modes dominate error-handling bugs:
1. **Over-validation in the interior**: every function re-checks invariants the boundary already enforced. The result is dead code that looks defensive but isn't, and that lies about what shapes can occur.
2. **Under-validation at the edges**: parsing a request body inline, scattered across handlers. The result is inconsistent error shapes and silent acceptance of malformed inputs.

The discipline collapses these into one rule: **validate exactly once, exactly at the boundary**. Inside, trust types.

## The Rule

```text
                  +--------------------------+
external          |        BOUNDARY          |
input  -------->  |  Pydantic / JSON schema  |  ---> trusted internal calls (no re-validation)
                  |  middleware              |
                  +--------------------------+
```

What counts as a boundary:
- HTTP request bodies (Pydantic / FastAPI)
- CLI argv (argparse / typer)
- Environment variables (pydantic-settings)
- Files read from disk (schema validate at read time, not at every use)
- External API responses (validate at the http client wrapper, not at every consumer)

What does **not** count as a boundary:
- A function called from another function in the same module
- A method on an already-validated Pydantic model
- A handler invoked by FastAPI after dependency injection succeeded

## Anti-Pattern: Over-Validation in the Interior

```python
# Smell — Pydantic already validated; we re-check anyway
async def render_postmortem(req: PostmortemRequest) -> str:
    if not isinstance(req, PostmortemRequest):
        raise TypeError("expected PostmortemRequest")
    if req.incident_id is None:
        raise ValueError("incident_id required")
    if not isinstance(req.incident_id, str):
        raise TypeError("incident_id must be str")
    ...
```

Every line of this is a lie. Pydantic enforced the type, the required-ness, and the string-ness before `render_postmortem` was ever called. The checks add noise, mislead future readers about what inputs are possible, and produce error messages that no caller can produce.

```python
# Clean
async def render_postmortem(req: PostmortemRequest) -> str:
    # Pydantic guarantees req.incident_id is a non-empty str.
    incident = await fetch_incident(req.incident_id)
    return _format(incident)
```

## Anti-Pattern: Defensive Fallbacks for Impossible Cases

```python
# Smell — a fallback that fires only if the type system is broken
def get_log_payload(gt: GroundTruth) -> str:
    payload = gt.log_payload
    if payload is None:
        return ""                       # GroundTruth.log_payload: str — never None
    return payload
```

If `log_payload` is typed `str`, the `is None` branch is dead. Worse: if you make it `Optional[str]` "to be safe," you're forcing every caller to handle None, propagating optionality outward. **Make the type honest, then trust it.**

The legitimate cousin is the **migration fallback** — see [../patterns/structured-fallback.md](../patterns/structured-fallback.md). That has a dated comment and a planned removal.

## The SSE/Streaming First-Yield Rule

This is the one place where simple boundary validation is **not enough**. FastAPI's `StreamingResponse` writes `200 OK` headers as soon as the generator is constructed. If the generator raises before its first `yield`, the client sees a 200 with an open connection that produces nothing. Most clients will hang until their socket timeout (often minutes).

The pattern (commit b695a32 — the `postmortem.py` TypeError):

```python
# Before — TypeError in fetch_incident propagates after headers are sent
async def stream_postmortem(incident_id: str) -> AsyncIterator[str]:
    incident = await fetch_incident(incident_id)     # may raise
    yield f"event: ready\ndata: {json.dumps({'id': incident.id})}\n\n"
    async for chunk in render(incident):
        yield f"event: chunk\ndata: {json.dumps({'text': chunk})}\n\n"
    yield "event: done\ndata: {}\n\n"
```

The fix: the generator's **first** statement must be `yield`-or-error. Wrap any failable preflight in a try/except that yields a sentinel error event:

```python
# After
async def stream_postmortem(incident_id: str) -> AsyncIterator[str]:
    try:
        incident = await fetch_incident(incident_id)
    except Exception as e:
        # Emit a structured error before the client times out.
        yield f"event: error\ndata: {json.dumps({'msg': str(e), 'kind': type(e).__name__})}\n\n"
        return
    yield f"event: ready\ndata: {json.dumps({'id': incident.id})}\n\n"
    try:
        async for chunk in render(incident):
            yield f"event: chunk\ndata: {json.dumps({'text': chunk})}\n\n"
    except Exception as e:
        yield f"event: error\ndata: {json.dumps({'msg': str(e), 'kind': type(e).__name__})}\n\n"
        return
    yield "event: done\ndata: {}\n\n"
```

Two invariants:
1. **No I/O before the first `yield`** that isn't wrapped in a try/except yielding an error.
2. **Every error path yields, then returns** — never raises through the generator boundary.

A test that exercises this:

```python
@pytest.mark.asyncio
async def test_stream_emits_error_when_fetch_fails(monkeypatch):
    async def boom(_):
        raise TypeError("incident shape changed")
    monkeypatch.setattr("app.fetch_incident", boom)
    chunks = [c async for c in stream_postmortem("INC-1")]
    assert chunks[0].startswith("event: error\n")
    assert "TypeError" in chunks[0]
```

## Quick Reference

| Where | What |
|-------|------|
| HTTP body | Pydantic model, validate once |
| CLI args | argparse/typer, validate once |
| Env vars | pydantic-settings at startup |
| Internal call | Trust types; no re-validation |
| Streaming generator | Yield error sentinel before any failable line |
| External API response | Validate at the client wrapper |

## Common Mistakes

### Wrong: catching everything to "make it robust"

```python
try:
    incident = await fetch_incident(incident_id)
except Exception:
    incident = None         # now every downstream caller has to handle None
```

Catching `Exception` upstream forces optionality everywhere downstream. Let it raise; handle at the boundary (FastAPI exception handler that maps to JSON error response).

### Wrong: validating in middleware AND endpoint

```python
@app.middleware("http")
async def auth_mw(req, call_next):
    if not req.headers.get("authorization"):
        return JSONResponse(401, ...)
    ...

@app.post("/postmortem")
async def postmortem(req: Request, body: PostmortemRequest):
    if not req.headers.get("authorization"):    # already enforced
        raise HTTPException(401)
    ...
```

One layer. The boundary owns auth.

### Correct: trust the boundary, fail loud beyond it

```python
@app.post("/postmortem")
async def postmortem(
    body: PostmortemRequest,                  # boundary
    user: User = Depends(get_current_user),   # boundary
) -> PostmortemResponse:
    incident = await fetch_incident(body.incident_id)   # may raise; FastAPI handler maps to 5xx
    return PostmortemResponse(text=_format(incident))
```

## Related

- [spotting-complexity.md](spotting-complexity.md)
- [landmines.md](landmines.md)
- [../patterns/structured-fallback.md](../patterns/structured-fallback.md)
- [../patterns/fail-loud-not-silent.md](../patterns/fail-loud-not-silent.md)
- [../index.md](../index.md)
