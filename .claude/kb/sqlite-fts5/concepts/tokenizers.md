# FTS5 Tokenizers

> **Purpose**: Choosing how FTS5 splits text into searchable tokens
> **Confidence**: HIGH
> **MCP Validated**: 2026-04-23

## Overview

A tokenizer decides what counts as a "word" and how it's normalized. FTS5 ships with three built-in tokenizers. For indexing Markdown documentation, `unicode61 remove_diacritics 2` is the pragmatic default; add `porter` on top if you want English stemming.

## The Pattern

```python
import sqlite3

db = sqlite3.connect(":memory:")

# Default: unicode61 with diacritic stripping — case-insensitive, splits on Unicode word boundaries
db.executescript("""
    CREATE VIRTUAL TABLE t USING fts5(
        body,
        tokenize = 'unicode61 remove_diacritics 2'
    );
""")
```

## The Three Built-in Tokenizers

| Tokenizer | Splits On | Case | Stemming | Good For |
|-----------|-----------|------|----------|----------|
| `ascii` | non-alphanumeric (ASCII) | case-fold | none | Legacy; avoid for international text |
| `unicode61` | Unicode word boundaries | case-fold + optional diacritic strip | none | **Default** for most uses |
| `porter` | (wraps another tokenizer) | + stems English | yes | Add on top of unicode61 for English docs |
| `trigram` | 3-char sliding windows | case-fold | — | Fuzzy / typo-tolerant; larger index |

## Stacking: `porter unicode61`

Porter is a **wrapping** tokenizer — it applies English stemming on top of whatever base tokenizer you specify. So `deploying`, `deployed`, `deploys` all become `deploy`:

```python
db.executescript("""
    CREATE VIRTUAL TABLE t USING fts5(
        body,
        tokenize = 'porter unicode61 remove_diacritics 2'
    );
""")
```

## Trigram for Fuzzy Matching

Trigram breaks tokens into 3-char windows, allowing matches even with typos:

```python
db.executescript("""
    CREATE VIRTUAL TABLE t USING fts5(
        body,
        tokenize = 'trigram'
    );
""")
# 'kubernetes' → tokens: 'kub', 'ube', 'ber', 'ern', 'rne', 'net', 'ete', 'tes'
# Query 'kubrnetes' (typo) still matches ~6 of 7 trigrams
```

**Trade-off:** ~3× larger index, slower writes.

## Decision Matrix

| Use Case | Tokenizer |
|----------|-----------|
| English docs, exact term match | `unicode61 remove_diacritics 2` |
| English docs, stemmed match | `porter unicode61 remove_diacritics 2` |
| Code / identifiers | `unicode61 tokenchars '_'` (keep underscores) |
| Fuzzy / typo-tolerant | `trigram` |
| Multilingual | `unicode61 remove_diacritics 2` (no stemming) |

## Common Mistakes

### Wrong

```python
# Forgetting to specify — defaults to ASCII-only, breaks for non-English
tokenize = 'ascii'
```

### Correct

```python
tokenize = 'unicode61 remove_diacritics 2'
```

## `remove_diacritics` Values

| Value | Effect |
|-------|--------|
| `0` | Keep diacritics (`café` ≠ `cafe`) |
| `1` | Legacy algorithm |
| `2` | Modern algorithm — **use this** |

## Related

- [virtual-tables](virtual-tables.md) — where `tokenize=` is declared
- [bm25-ranking](bm25-ranking.md) — scoring the tokenized matches
