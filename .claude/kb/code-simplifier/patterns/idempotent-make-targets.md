# Idempotent Make Targets

> **Purpose**: Make recipes that succeed when re-run, regardless of partial prior state. The operator should never have to "clean up before retrying."
> **MCP Validated**: 2026-04-27

## When to Use

- Any Make target a human will run more than once (every meaningful target).
- CI deploy steps that may be retried after a flaky network failure.
- Local-dev "bring up the stack" targets (`make demo`, `make seed-models`).
- Targets that create directories, kubectl resources, or pulled artifacts.

## When NOT to Use

- One-shot destructive operations (`make nuke-cluster`) — these should refuse to be idempotent and fail loudly if state is unexpected.
- Targets explicitly modeling "first-time setup" semantics (`make init` that should fail if already initialized).

## The Patterns

### 1. `mkdir -p` — never `mkdir`

```makefile
# Smell — fails on second run
build:
	mkdir build
	go build -o build/app ./cmd/app

# Loud
build:
	mkdir -p build
	go build -o build/app ./cmd/app
```

The `-p` flag makes `mkdir` succeed when the directory already exists, and creates intermediate directories. There is no good reason to omit it in a Make recipe.

### 2. `kubectl create --dry-run=client -o yaml | kubectl apply -f -`

```makefile
# Smell — `create` fails on re-run with "already exists"
seed-secret:
	kubectl create secret generic api-key --from-literal=key=$(API_KEY)

# Loud — render then apply; idempotent
seed-secret:
	kubectl create secret generic api-key \
	  --from-literal=key=$(API_KEY) \
	  --dry-run=client -o yaml \
	  | kubectl apply -f -
```

`apply` is idempotent (3-way merge); `create` is not. The dry-run pipe gives you the convenience of `create` (literal flags) with the idempotence of `apply`.

### 3. Retry loops for flaky pulls

This repo's `seed-models` target pulls Ollama models from a registry that occasionally times out. Retrying manually is annoying; baking the retry in is one line:

```makefile
# Smell — first flake fails the whole demo
seed-models:
	ollama pull llama3.1:8b
	ollama pull mistral:7b

# Loud — retry until success; sleep avoids hammering
seed-models:
	until ollama pull llama3.1:8b; do sleep 5; done
	until ollama pull mistral:7b;   do sleep 5; done
```

Add a max-retry count if the operation can fail permanently:

```makefile
seed-models:
	@n=0; until ollama pull llama3.1:8b; do \
	  n=$$((n+1)); \
	  if [ $$n -ge 10 ]; then echo "giving up after 10 attempts"; exit 1; fi; \
	  echo "pull failed, retry $$n/10 in 5s..."; sleep 5; \
	done
```

### 4. Marker files for expensive one-shot work

```makefile
.venv/.installed: requirements.txt
	python -m venv .venv
	./.venv/bin/pip install -r requirements.txt
	touch $@

install: .venv/.installed   ## install Python deps (skipped if up-to-date)

.PHONY: install
```

The marker file (`.venv/.installed`) declares the work done. Re-running `make install` is a no-op until `requirements.txt` changes. This gives you idempotence *and* incremental builds.

### 5. `--ignore-not-found` for cleanups

```makefile
# Smell — fails the second time (resource already gone)
clean:
	kubectl delete configmap dashboards
	kubectl delete deployment backend

# Loud
clean:
	kubectl delete configmap dashboards --ignore-not-found
	kubectl delete deployment backend   --ignore-not-found
```

Cleanups that fail when the thing was already gone are operator-hostile.

### 6. Quoting and `set -e` in shell sub-recipes

```makefile
# Smell — recipe loses errors mid-pipeline
deploy:
	helmfile sync
	./scripts/smoke.sh

# Loud — explicit shell, set -euo pipefail, errors surface
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

deploy:
	helmfile sync
	./scripts/smoke.sh
```

Without `set -euo pipefail`, a `command1 | command2` recipe with a failing `command1` and successful `command2` returns 0 and the target appears to succeed.

## Configuration

| Lever | Default | When to use |
|-------|---------|-------------|
| `mkdir -p` | (`-p` not implied) | Always |
| `--dry-run=client \| apply` | `kubectl create` | Always for re-runnable targets |
| `until ...; do sleep 5; done` | no retry | Flaky network ops |
| Marker file via `touch $@` | none | Expensive setup steps |
| `--ignore-not-found` | not set | Cleanup targets |
| `SHELL := /bin/bash` + `-euo pipefail` | `/bin/sh`, no flags | Always for non-trivial recipes |

## Example Usage

```makefile
# A complete, idempotent demo target from this repo's style
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

.PHONY: demo
demo: install seed-models dashboards    ## bring up the full local demo
	helmfile sync
	./scripts/smoke.sh
	@echo "Demo ready at http://localhost:3000"

.PHONY: seed-models
seed-models:                            ## pull required ollama models (retries flakes)
	@for model in llama3.1:8b mistral:7b; do \
	  echo "pulling $$model..."; \
	  until ollama pull $$model; do sleep 5; done; \
	done

.PHONY: dashboards
dashboards: regen-configmaps             ## render and apply dashboards (cleans drift)
	kubectl delete configmap -l grafana_dashboard=1 --ignore-not-found
	kubectl apply -f charts/grafana-dashboards/templates/

.PHONY: regen-configmaps
regen-configmaps:                        ## regenerate ConfigMaps from JSON
	mkdir -p charts/grafana-dashboards/templates/
	python scripts/regen-configmaps.py

.PHONY: clean
clean:                                   ## remove demo resources (idempotent)
	kubectl delete -f charts/grafana-dashboards/templates/ --ignore-not-found
	kubectl delete configmap -l grafana_dashboard=1 --ignore-not-found
	rm -rf .venv/.installed

install: .venv/.installed
.venv/.installed: requirements.txt
	python -m venv .venv
	./.venv/bin/pip install -r requirements.txt
	touch $@
```

## Anti-Pattern

### Recipe that requires manual cleanup before re-run

```makefile
demo:
	mkdir build                              # fails second run
	kubectl create secret ...                # fails second run
	ollama pull mymodel                      # fails on flake
	kubectl apply -f .
```

Operator hits any step's failure, types `make demo` again, hits `mkdir: build: File exists`, types `rm -rf build && make demo`, hits `secrets "..." already exists`, gives up.

### Marker file without input dependency

```makefile
# Smell — never re-runs even when requirements.txt changes
.venv/.installed:
	python -m venv .venv && ./.venv/bin/pip install -r requirements.txt
	touch $@
```

The marker must depend on the input (`requirements.txt`). Otherwise the target is permanent.

### Bare `&&` chains hiding failures

```makefile
# Smell — without set -euo pipefail, partial failures pass
deploy:
	helmfile sync && ./scripts/smoke.sh && echo "ok"
```

The `&&` chain is correct in a regular shell, but Make's default `/bin/sh` plus the way recipes are line-by-line means each line is a separate shell. Use `SHELL := /bin/bash` + `.SHELLFLAGS := -euo pipefail -c` once at the top of the Makefile.

## See Also

- [single-source-of-truth.md](single-source-of-truth.md)
- [append-not-replace.md](append-not-replace.md)
- [../concepts/the-collapse-test.md](../concepts/the-collapse-test.md)
- [../concepts/spotting-complexity.md](../concepts/spotting-complexity.md)
- [../index.md](../index.md)
