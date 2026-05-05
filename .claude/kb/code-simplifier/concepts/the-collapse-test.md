# The Collapse Test

> **Purpose**: Decide when two functions, two Make targets, two abstractions, or two code paths should become one — and when they should stay separate.
> **Confidence**: 0.95
> **MCP Validated**: 2026-04-27

## Overview

When you find two of anything in the codebase that mostly do the same thing, you have a choice: **collapse** them into one, or **separate** them more loudly. The collapse test is a short series of questions that decides which.

The principle that drives the test is simple: **if the fast path silently fails often enough that users need to know about a slow path, collapse them and just always run the slow path.** Cognitive cost > runtime cost, almost always.

## The Test

Apply in order. The first **yes** wins.

1. **Same intent, same blast radius?** If both paths are doing the same thing for the same caller, collapse.
2. **Does using the wrong one fail silently?** If picking the fast path can leave the system in a bad state without a loud error, collapse.
3. **Is the fast path a strict subset of the slow path?** If the slow path is "do everything the fast path does, plus extra cleanup," collapse to the slow path.
4. **Different blast radius (production vs sandbox, namespace vs cluster)?** **Keep separate.** Make the names dramatize the difference.
5. **Different intent (deploy vs roll-back)?** **Keep separate.** These should be loud, not collapsed.

## Worked Example: `make dashboards` + `make dashboards-reset`

This repo had two Make targets:

```makefile
# Before (commit 31c6a0c lineage)
dashboards:
	kubectl apply -f charts/grafana-dashboards/templates/

dashboards-reset:
	kubectl delete configmap -l grafana_dashboard=1 --ignore-not-found
	kubectl apply -f charts/grafana-dashboards/templates/
```

The fast path (`dashboards`) failed silently when:
- A ConfigMap's label set changed (the old labels stayed; Grafana sidecar saw two copies).
- A panel was renamed (the old configmap still served the old name).
- A dashboard was deleted from source — its configmap lingered forever.

Users were told "if it acts weird, run `make dashboards-reset`." That's the smell. Run the test:

| Question | Answer |
|----------|--------|
| Same intent? | Yes — apply current dashboards. |
| Does fast path fail silently? | Yes — orphan configmaps, label drift. |
| Is fast a subset of slow? | Yes — slow does everything fast does, plus cleanup. |

Collapse. Commit a27f67f deleted `dashboards-reset` and folded the cleanup into `dashboards`:

```makefile
# After (commit a27f67f)
dashboards:  ## apply the dashboards (always cleans drift first)
	kubectl delete configmap -l grafana_dashboard=1 --ignore-not-found
	kubectl apply -f charts/grafana-dashboards/templates/
```

Cost: an extra ~200 ms per invocation. Benefit: zero cognitive burden, zero "did you run dashboards-reset?" Slack threads.

## The Inverse: When NOT to Collapse

Two examples from this repo where the test correctly says **keep separate**.

### `make demo` vs `make demo-canary`

```makefile
demo:           ## install full stack, run smoke tests, no canary
	helmfile sync
	./scripts/smoke.sh

demo-canary:    ## same stack but enable Argo Rollouts canary on backend
	helmfile sync --set useArgoRollouts=true
	./scripts/smoke.sh
	./scripts/canary-walk.sh
```

| Question | Answer |
|----------|--------|
| Same intent? | No — one demonstrates baseline; the other demonstrates progressive delivery. |
| Different blast radius? | Yes — `demo-canary` exercises traffic-shifting, an aborter, an analysis controller. |

Collapsing would force every demo run to spin up the canary machinery. Keep separate; rename if not loud enough.

### `kubectl apply` vs `kubectl delete + apply`

These are not collapsible at the framework level — `apply` is a 3-way merge, `delete + apply` is a hard reset. Different blast radius (`delete` will recreate, dropping fields managed by other field-managers). Keep separate; collapse only at the **target** level when the larger flow tolerates the cost (the `dashboards` case).

## Quick Reference

| Situation | Action |
|-----------|--------|
| Fast path silently fails -> users learn the slow path | Collapse to slow |
| Slow path is a superset of fast path | Collapse to slow |
| Two paths differ only by a flag flip | Collapse, expose the flag |
| Different intent (deploy / rollback / debug) | Keep separate; make names loud |
| Different blast radius (prod / sandbox) | Keep separate; environment in name |
| Two code paths with truly different semantics | Keep separate; document why at the top |

## Common Mistakes

### Wrong: keeping both because "users might want the fast one"

If users need to *know* about the fast one, the fast one is leaking complexity. The "wins time" argument is usually < 1 s vs cognitive cost over months.

### Wrong: collapsing different-intent paths

```makefile
# Don't do this
deploy:                        ## could be apply, could be rollback
	./scripts/deploy.sh "$(MODE)"   # MODE=apply or MODE=rollback
```

Now every operator types `MODE=` for every action. The collapse hides the loud thing (rollback) inside the quiet thing (deploy). Separate, name them, scare the operator into thinking before typing.

### Correct: collapsing redundant subsets

```makefile
# Slow path always; cost is acceptable; cognitive load is gone
dashboards:
	kubectl delete configmap -l grafana_dashboard=1 --ignore-not-found
	kubectl apply -f charts/grafana-dashboards/templates/
```

## Related

- [spotting-complexity.md](spotting-complexity.md)
- [the-yagni-test.md](the-yagni-test.md)
- [../patterns/idempotent-make-targets.md](../patterns/idempotent-make-targets.md)
- [../index.md](../index.md)
