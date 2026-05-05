# SQLite FTS5 Knowledge Base

> **Purpose**: Full-text search over Markdown content (Azure DevOps Wiki + MediaWiki + Discourse) using SQLite FTS5 from Python 3.12 stdlib `sqlite3`. Target runtime: AWS Lambda.
> **MCP Validated**: 2026-04-23

## Why FTS5

- **Zero deps** — ships with Python 3.12 `sqlite3`
- **Lambda-friendly** — single file DB on `/tmp` (512 MB default, up to 10 GB)
- **Fast enough** — BM25 ranking, `snippet()` / `highlight()` built-in, sub-50 ms queries on <100k docs
- **Keyword-only** — exactly what the federated search spec requires

## Quick Navigation

### Concepts (< 150 lines each)

| File | Purpose |
|------|---------|
| [concepts/virtual-tables.md](concepts/virtual-tables.md) | FTS5 virtual tables + external-content tables for storage efficiency |
| [concepts/tokenizers.md](concepts/tokenizers.md) | `unicode61` vs `porter` vs `trigram` — which fits Markdown |
| [concepts/bm25-ranking.md](concepts/bm25-ranking.md) | BM25 scoring and weighting via `bm25(fts, w1, w2)` |

### Patterns (< 200 lines each)

| File | Purpose |
|------|---------|
| [patterns/index-markdown.md](patterns/index-markdown.md) | Walk `.md` files and build an FTS5 index (stdlib only) |
| [patterns/snippets-highlighting.md](patterns/snippets-highlighting.md) | `snippet()` + `highlight()` for result previews |
| [patterns/lambda-persistence.md](patterns/lambda-persistence.md) | `/tmp` warm cache + S3 tarball cold-start rebuild |

### Quick Reference

- [quick-reference.md](quick-reference.md) — one-page cheat sheet

---

## Key Concepts

| Concept | Description |
|---------|-------------|
| **Virtual Table** | `CREATE VIRTUAL TABLE ... USING fts5(...)` |
| **External Content** | FTS5 stores only tokens; source rows live in a regular table |
| **Tokenizer** | How text is split (`unicode61` default, `porter` for stemming, `trigram` for substring) |
| **BM25** | Default rank function; **more negative = better match** |
| **snippet()** | Short excerpt containing matches |
| **highlight()** | Wraps matched terms with markers |

---

## Agent Usage

| Agent | Files | Use Case |
|-------|-------|----------|
| `search-indexer-specialist` | all concepts + patterns | Index design |
| `python-lambda-developer` | patterns/lambda-persistence.md | Cold-start strategy |
