# Data Link, Not URL String

> **Purpose**: When linking from one Grafana panel to another datasource (logs from a metric, traces from a log), use Grafana's **internal data link** spec — never hand-build `/explore?panes={...}` URLs. Generalizes to: prefer framework-provided URL construction over string concatenation.
> **MCP Validated**: 2026-04-27

## When to Use

- A Grafana metric panel that should drill into Loki logs for the same time window.
- A logs panel that should drill into Tempo traces by trace ID.
- Anywhere two datasources need to be linked with a click-through.
- Generally: any link whose schema is owned by a framework (OAuth callback, S3 presigned URL, JWT-bearing auth links).

## When NOT to Use

- The link is to an arbitrary external URL not produced by a framework (a runbook on Confluence; just hand-write the URL).
- You're integrating with a system that doesn't offer a typed URL builder. Then build the URL once, in a helper, with tests.

## The Pattern

Grafana's `internal` data link is a typed object that Grafana itself renders into a Explore URL at click time. The schema is enforced by the dashboard JSON validator and is forward-compatible — when Grafana renamed `queryType=traceId` semantics, hand-built URLs broke (commit 7fa5219), but `internal` links continued to work.

```json
{
  "fieldConfig": {
    "defaults": {
      "links": [
        {
          "title": "View logs for this service",
          "url": "",
          "internal": {
            "datasourceUid": "loki-uid",
            "datasourceName": "Loki",
            "query": {
              "expr": "{service=\"${__field.labels.service}\"}",
              "refId": "A"
            },
            "panelsState": {
              "logs": {
                "wrapLogMessage": true
              }
            }
          }
        }
      ]
    }
  }
}
```

For trace lookups:

```json
{
  "fieldConfig": {
    "defaults": {
      "links": [
        {
          "title": "View trace",
          "internal": {
            "datasourceUid": "tempo-uid",
            "datasourceName": "Tempo",
            "query": {
              "queryType": "traceql",
              "query": "${__value.raw}",
              "refId": "A"
            }
          }
        }
      ]
    }
  }
}
```

Note: `queryType: "traceql"` is part of the typed query body, not a URL query param. Grafana renders the right Explore URL for whatever its current routing is.

## Configuration

| Field | Required | Description |
|-------|----------|-------------|
| `internal.datasourceUid` | yes | UID of the target datasource |
| `internal.datasourceName` | yes | Human-readable name (used for fallback) |
| `internal.query` | yes | Datasource-specific query body (LogQL, TraceQL, PromQL) |
| `internal.panelsState` | no | Panel-specific viewport options |
| `url` | yes (empty string) | Must be present but empty when `internal` is set |

## Example Usage

### From a metric panel to Loki logs

```python
# scripts/build_dashboards.py — fragment
def metric_panel_with_log_drilldown(service: str) -> dict:
    return {
        "type": "timeseries",
        "title": f"Latency p99 — {service}",
        "targets": [{
            "expr": f'histogram_quantile(0.99, sum by(le) (rate(http_request_duration_seconds_bucket{{service="{service}"}}[5m])))',
            "refId": "A",
        }],
        "fieldConfig": {
            "defaults": {
                "unit": "s",
                "links": [{
                    "title": "Logs for this service",
                    "url": "",
                    "internal": {
                        "datasourceUid": "loki",
                        "datasourceName": "Loki",
                        "query": {"expr": f'{{service="{service}"}}', "refId": "A"},
                    },
                }],
            },
        },
    }
```

### Generalized: `urllib.parse` over string concatenation

When you really must build a URL by hand (no framework helper), use the standard library:

```python
# Smell
url = f"https://grafana.example.com/explore?panes={panes_json}&queryType=traceId"

# Loud (typed components, escaped values)
from urllib.parse import urlencode, urlunparse
qs = urlencode({"panes": panes_json})           # handles % escaping
url = urlunparse(("https", "grafana.example.com", "/explore", "", qs, ""))
```

The smell isn't merely escaping — it's that `queryType=traceId` is **silently ignored** by post-v10 Grafana (commit 7fa5219). The typed `internal` link wouldn't have that field; if you try to pass an unknown query param via the typed builder, the schema rejects it at dashboard save time, not at click time.

## Anti-Pattern

### Hand-built Explore URL with legacy params

```json
{
  "title": "View trace",
  "url": "/explore?left={\"datasource\":\"tempo\",\"queries\":[{\"query\":\"${__value.raw}\",\"queryType\":\"traceId\"}]}"
}
```

In Grafana 10+:
- `?left=` is the old API; `?panes=` is the current one.
- `queryType=traceId` was renamed/removed; the click opens Explore on Tempo's default view.
- The link "works" — surface validation (Grafana renders the click) succeeds; semantic intent (load the trace) silently dropped.

This is a textbook landmine ([../concepts/landmines.md](../concepts/landmines.md)).

### F-string URL construction with user input

```python
# Smell — XSS surface, no escaping
url = f"https://app.example.com/search?q={user_query}"
```

Use `urlencode({"q": user_query})`. Same principle, smaller blast radius.

## See Also

- [fail-loud-not-silent.md](fail-loud-not-silent.md)
- [structured-fallback.md](structured-fallback.md)
- [../concepts/landmines.md](../concepts/landmines.md)
- [../../otel-lgtm/index.md](../../otel-lgtm/index.md)
- [../index.md](../index.md)
