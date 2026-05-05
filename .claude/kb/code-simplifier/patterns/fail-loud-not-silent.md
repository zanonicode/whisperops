# Fail Loud, Not Silent

> **Purpose**: Encode "zero" explicitly in PromQL ratios, divide-by-zero guards, and Grafana panel options so that "no series" doesn't render as "No data" — which operators read as broken monitoring.
> **MCP Validated**: 2026-04-27

## When to Use

- Any PromQL expression doing rate-of-rate, ratio, or percentage.
- Grafana stat panels showing counts, rates, or SLO compliance numbers.
- Loki/LogQL ratios.
- Anywhere "absence of series" semantically means "zero," not "broken pipeline."

## When NOT to Use

- The series legitimately *might* be missing because the target doesn't exist (e.g., a job that scrapes only when a sidecar is present). Then "No data" is correct; document the condition.
- You want absent-alerts to fire (`absent()`-based alerting). Don't mask absence with `or vector(0)`; it would silence the alert.

## The Patterns

### 1. `or vector(0)` for empty numerators

```promql
# Smell — empty numerator collapses the whole ratio
sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
sum(rate(http_requests_total[5m]))

# Loud — numerator returns 0 when no 5xx, denominator may still be present
(sum(rate(http_requests_total{status=~"5.."}[5m])) or vector(0))
  /
sum(rate(http_requests_total[5m]))
```

If no 5xx requests have happened in the window, the numerator returns no series and the whole division is empty. With `or vector(0)`, the numerator becomes the scalar 0 and the ratio is `0 / total`, which renders as 0% on the panel.

### 2. `clamp_min` for divide-by-zero on the denominator

```promql
# Smell — denominator zero -> +Inf or empty
sum(rate(cache_hits_total[5m]))
  /
sum(rate(cache_lookups_total[5m]))

# Loud — denominator is at least 1; ratio is bounded
sum(rate(cache_hits_total[5m]))
  /
clamp_min(sum(rate(cache_lookups_total[5m])), 1)
```

`clamp_min(x, 1)` lower-bounds the denominator at 1, turning `0/0` into `0/1 = 0`. Use only on denominators where 0 traffic legitimately means 0% hit rate.

### 3. `noValue: "0"` for stat panels

Grafana's stat panel renders "No data" when its query returns no series. For panels where the absence means zero (not broken):

```json
{
  "type": "stat",
  "title": "5xx in last 5m",
  "targets": [{
    "expr": "sum(increase(http_requests_total{status=~\"5..\"}[5m]))",
    "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "noValue": "0",
      "unit": "short",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "red",   "value": 1 }
        ]
      }
    }
  }
}
```

### 4. LogQL: same shape

```logql
# Smell
sum(rate({app="backend"} |= "ERROR" [5m]))
  /
sum(rate({app="backend"} [5m]))

# Loud
(sum(rate({app="backend"} |= "ERROR" [5m])) or vector(0))
  /
clamp_min(sum(rate({app="backend"} [5m])), 1)
```

### 5. The full SLO error budget panel

```promql
# 99.9% SLO error budget remaining over a 30-day window
1 - (
  (sum(increase(http_requests_total{status=~"5.."}[30d])) or vector(0))
    /
  clamp_min(sum(increase(http_requests_total[30d])), 1)
) / (1 - 0.999)
```

Without the loud encoding, every dashboard reload during an idle period would show "No data" and trigger "is monitoring broken?" pages.

## Configuration

| Lever | Default | When to use |
|-------|---------|-------------|
| `or vector(0)` on numerator | not applied | Always for "zero means good" series |
| `clamp_min(denom, 1)` | not applied | Always when denom can be empty/zero |
| `noValue: "0"` on stat panel | unset | Panels where absence = zero |
| `absent()` alert | not used | When absence itself is the alarm |

## Example Usage

```yaml
# A loud SLO panel embedded in a Grafana dashboard JSON
{
  "type": "timeseries",
  "title": "5xx rate (errors / total)",
  "targets": [{
    "expr": "(sum(rate(http_requests_total{status=~\"5..\"}[5m])) or vector(0)) / clamp_min(sum(rate(http_requests_total[5m])), 1)",
    "legendFormat": "5xx ratio"
  }],
  "fieldConfig": {
    "defaults": { "unit": "percentunit", "noValue": "0" }
  }
}
```

## Anti-Pattern

### Wrapping counters in `clamp_min`

```promql
# Wrong — counters never go negative; clamp_min on a counter hides bugs
clamp_min(rate(http_requests_total[5m]), 0)
```

If `rate()` returned negative, you have a counter reset followed by an integration window straddling the reset. `clamp_min(rate, 0)` papers over it. Either accept the dip (counters are eventually consistent) or use `increase()` with appropriate windowing.

### Hiding absence on alerts

```promql
# Wrong — "5xx > 0.05" with or vector(0) silently flattens missing data to 0
((sum(rate(http_requests_total{status=~"5.."}[5m])) or vector(0))
  / clamp_min(sum(rate(http_requests_total[5m])), 1)) > 0.05
```

This expression won't fire when the entire metric pipeline is broken (no series at all on either side); it'll always evaluate to 0. Pair with an `absent()` alert on `http_requests_total` itself.

### Using "No data" as a feature

```text
"It's fine that the panel shows No data; ops know that means idle."
```

They don't. Every new operator reads "No data" as "broken." The cost of teaching the lore is higher than the cost of the explicit zero.

## See Also

- [data-link-vs-url.md](data-link-vs-url.md)
- [structured-fallback.md](structured-fallback.md)
- [../concepts/landmines.md](../concepts/landmines.md)
- [../concepts/error-handling-discipline.md](../concepts/error-handling-discipline.md)
- [../../otel-lgtm/index.md](../../otel-lgtm/index.md)
- [../index.md](../index.md)
