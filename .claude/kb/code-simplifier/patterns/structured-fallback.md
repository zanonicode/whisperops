# Structured Fallback

> **Purpose**: During a schema migration, accept multiple field names with a deliberate, dated, time-boxed fallback. Distinguish this from the **anti-pattern** of permanent defensive defaults that hide drift.
> **MCP Validated**: 2026-04-27

## When to Use

- A field is being renamed in a Pydantic/JSON schema; producers will be updated over weeks, not in a single deploy.
- A reader must accept both old and new payload shapes during the transition.
- The migration has an end date and an owner. Without those, this becomes the anti-pattern.

## When NOT to Use

- The field is genuinely optional with no migration in flight (just type it `Optional[T] = None` and handle absence honestly).
- The fallback is masking a bug (the producer is broken, fix the producer instead of fanning out tolerance).
- You're starting a new feature — pick one schema, pin to it.

## The Pattern

```python
from datetime import date

# MIGRATION: rename log_snippet -> log_payload (commit a247ebc, 2026-04-15).
# Producer rollout target: 2026-05-15. Remove this fallback then.
# Owner: @sre-copilot-team.
def get_log_text(gt: dict) -> str:
    return gt.get("log_payload") or gt.get("log_snippet", "")
```

Three required ingredients:
1. **Comment naming the migration** (which fields, why, when started).
2. **End date** — when the fallback can be deleted.
3. **Owner** — who removes it.

Without all three, this is permanent technical debt.

### Pydantic version

```python
from datetime import date
from typing import Optional
from pydantic import BaseModel, Field, model_validator

class GroundTruth(BaseModel):
    """Ground-truth row.

    MIGRATION (started 2026-04-15, ends 2026-05-15): renamed
    `log_snippet` -> `log_payload`. Until end date, accept both;
    after end date, delete `log_snippet` and the validator below.
    Owner: @sre-copilot-team.
    """
    log_payload: Optional[str] = None
    # Legacy: accepted during migration window only.
    log_snippet: Optional[str] = Field(default=None, deprecated=True)

    @model_validator(mode="after")
    def _coalesce_log_text(self) -> "GroundTruth":
        if self.log_payload is None and self.log_snippet is not None:
            self.log_payload = self.log_snippet
        return self

    def text(self) -> str:
        return self.log_payload or ""
```

After the migration end date, the file collapses to:

```python
class GroundTruth(BaseModel):
    log_payload: str
    def text(self) -> str:
        return self.log_payload
```

The diff is mechanically obvious in code review: the migration comment, the legacy field, the validator — all delete cleanly together.

## Configuration

| Element | Required | Notes |
|---------|----------|-------|
| Migration comment | yes | Names old field, new field, start date |
| End date | yes | Calendar date, not "soon" |
| Owner | yes | Team handle or person |
| Tracking ticket | optional | Recommended for non-trivial migrations |
| `deprecated=True` on Pydantic field | recommended | Surfaces deprecation warnings to producers |

## Example Usage

### Reader (commit a247ebc)

```python
# scripts/build_eval.py
def collect_log_text(rows: list[dict]) -> list[str]:
    """Extract log text from each row.

    Tolerates both `log_payload` (new) and `log_snippet` (legacy) per
    the schema migration (a247ebc -> 2026-05-15).
    """
    out = []
    for row in rows:
        text = row.get("log_payload") or row.get("log_snippet", "")
        out.append(text)
    return out
```

### Producer-side cleanup

```python
# scripts/regen_ground_truth.py — produces only the new field.
def write_row(incident_id: str, log_text: str) -> dict:
    return {
        "incident_id": incident_id,
        "log_payload": log_text,           # new name only
        # "log_snippet": log_text,         # removed 2026-04-20
    }
```

The producer is updated **first**, then producers are rolled out, then the reader's fallback is removed. Reader-first, producer-second is the wrong order — readers will see the new field absent during the producer rollout.

## Anti-Pattern

### Permanent fallback without a sunset

```python
# Smell — no migration comment, no end date, no owner.
def get_log_text(gt: dict) -> str:
    return gt.get("log_payload") or gt.get("log_snippet") or gt.get("snippet") or gt.get("text") or ""
```

This isn't a fallback — it's archeology. Each `or` clause is a fossil from a producer that nobody remembers. Each is now a permanent commitment to accept that field name forever, because removing it might break unknown consumers.

### Defensive default for "impossible" cases

```python
# Smell — log_payload is typed str (non-Optional). The fallback covers nothing real.
def get_log_text(gt: GroundTruth) -> str:
    return gt.log_payload or "no payload"     # gt.log_payload: str — never falsy in practice
```

Either the type is honest and the fallback is dead, or the type is a lie. Pick one. See [../concepts/error-handling-discipline.md](../concepts/error-handling-discipline.md).

### Shipping the fallback without telling the producers

```python
# Reader silently accepts both names; producer team never told to migrate.
# Result: producers keep emitting the old field forever.
```

The fallback isn't doing its job unless someone is actively migrating producers. A fallback no one is racing against is just permanent dual support.

## See Also

- [fail-loud-not-silent.md](fail-loud-not-silent.md)
- [single-source-of-truth.md](single-source-of-truth.md)
- [../concepts/error-handling-discipline.md](../concepts/error-handling-discipline.md)
- [../concepts/landmines.md](../concepts/landmines.md)
- [../index.md](../index.md)
