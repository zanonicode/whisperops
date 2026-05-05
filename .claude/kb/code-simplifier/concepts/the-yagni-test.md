# The YAGNI Test

> **Purpose**: Decide whether to keep or delete a feature, flag, branch, or option. YAGNI ("you ain't gonna need it") sounds glib; this concept makes it operational with a small set of questions and three real deletion case studies from this repo.
> **Confidence**: 0.95
> **MCP Validated**: 2026-04-27

## Overview

Every line of code is a liability. Optionality has a carrying cost: docs to write, tests to maintain, branches that drift, surface area for new bugs. The YAGNI test is the framework for deciding when the cost has overtaken the benefit.

The test is intentionally biased toward **delete**. The default in mature codebases should be: when in doubt, remove. Re-adding a feature is cheap (the diff is in git); maintaining a dead one is forever.

## The Test

Apply in order. Any **yes** before question 5 means delete.

1. **Has anyone used this in the last 6 months?** Check git log on the relevant file/flag. If no callers exercised this path, no commits modified it for a real reason, and no support thread referenced it — delete.
2. **Is the only documentation a code comment?** If the feature exists but is undocumented in the user-facing README/runbook, it isn't supported. Delete.
3. **Does keeping it require maintaining a parallel code path?** If the option introduces a fork (`if dry_run: ... else: ...`) that doubles the test matrix — delete the dry-run path or promote it to the only path.
4. **Is it covered by a test?** No test = nobody depends on it = delete.
5. **Would re-adding it cost more than 1 hour from git history?** If yes, **keep**. Some features are expensive to reconstruct; deletion isn't free in those cases.

## Case Study 1: Removing the canary moment from `make demo` (commit ab3422b)

The original `make demo` walked the user through:
1. Apply baseline backend.
2. Trigger a canary release.
3. Pause for input.
4. Promote.

Steps 2–4 had no test, drifted whenever the rollout strategy changed, and were never run by anyone except in live demos. Worse, the pause-for-input made the target unusable in CI.

| Question | Answer |
|----------|--------|
| Used in 6 months? | Only in 2 live demos. |
| Documented? | Comment-only. |
| Parallel code path? | Yes — non-canary `demo` and canary `demo` both existed. |
| Tested? | No. |

Delete. Commit ab3422b removed the canary moment; the canary flow lives in the standalone `make demo-canary` target where it is the *whole* point of the target — not a vestigial branch.

## Case Study 2: Folding `dashboards-reset` into `dashboards` (commit a27f67f)

Covered in detail in [the-collapse-test.md](the-collapse-test.md), but worth reframing through YAGNI: `dashboards-reset` was a workaround for `dashboards` failing silently. The "feature" being preserved was *the option to skip the cleanup step*. Nobody benefits from skipping the cleanup; it costs ~200 ms.

| Question | Answer |
|----------|--------|
| Used in 6 months? | Yes — but only because `dashboards` was broken. |
| Documented? | Yes — `## reset and reapply dashboards`. |
| Parallel code path? | Yes. |
| Tested? | No. |

Delete. The comment-documented use case is itself an indictment: documentation existed only because users hit the bug.

## Case Study 3: Removing the orphan AnalysisTemplate (commit c97741e)

A `deploy/rollouts/analysis-templates/error-rate.yaml` shipped in the tree, referenced by nothing. New operators copied it as a starter and got confused when their copy didn't apply.

| Question | Answer |
|----------|--------|
| Used in 6 months? | Imported zero times. |
| Documented? | No. |
| Parallel code path? | The "real" templates live inside the chart. |
| Tested? | No. |

Delete. If the example is genuinely useful, it belongs in `examples/` with a README, not in `deploy/` where it implies "this ships."

## When NOT to Delete

The test is biased toward delete, but some signals say **keep**:

- **Regulatory/compliance hooks**: SOX-required audit toggles even if rarely exercised.
- **Disaster recovery paths**: code that runs in scenarios you hope never happen, but loses years of work if absent. Test it instead of deleting.
- **Public API contract**: if external users depend on the surface, deletion is a breaking change. Deprecate explicitly.
- **The 1-hour reconstruction rule (Q5)**: features built on deep historical context that would be expensive to recreate from git.

## Quick Reference

| Signal | Action |
|--------|--------|
| Untouched for 6+ months, no users | Delete |
| Comment-only documentation | Delete |
| Parallel code path doubling tests | Delete one branch |
| No test coverage | Delete |
| External API contract | Deprecate, don't delete |
| Disaster recovery | Test, don't delete |
| Reconstruction cost > 1h | Keep |

## Common Mistakes

### Wrong: keeping "for future flexibility"

```python
def render(template: str, *, dry_run: bool = False, verbose: bool = False, debug: bool = False):
    # last call site that set any of these to True: 14 months ago
    ...
```

The future caller is hypothetical. The current cost is real (test matrix, doc burden).

### Wrong: deleting without checking external surface

```python
# v1 of the public client
def get_postmortem(incident_id: str, *, format: str = "markdown") -> str: ...

# Internal usage only ever passes 'markdown'.
# But the package is on PyPI; external users may pass format="json".
# Don't silently drop the parameter.
```

Use deprecation warnings; remove in a major version bump with changelog notes.

### Correct: delete with a tombstone commit message

```text
git commit -m "remove dashboards-reset (folded into dashboards in a27f67f)"
```

The tombstone makes the deletion easy to find in `git log --all -- dashboards-reset` if it needs to come back.

## Related

- [the-collapse-test.md](the-collapse-test.md)
- [spotting-complexity.md](spotting-complexity.md)
- [landmines.md](landmines.md)
- [../index.md](../index.md)
