# Secrets & SOPS — Operator Guide

This guide covers how to **bring your own credentials** to a fresh whisperops deploy. The repo ships with a SOPS-encrypted set under `secrets/` that only decrypts with the maintainer's `age.key`. To run the platform on your own GCP project + SaaS accounts, follow this guide end-to-end.

> Cross-references: [DESIGN §13 Security](../.claude/sdd/features/DESIGN_whisperops.md), [Makefile targets](../Makefile), [docs/OPERATIONS.md §1 — Stage 5 secret materialization](OPERATIONS.md).

---

## TL;DR — Operator checklist

```bash
# 1. Tools
brew install sops age yq jq                        # macOS

# 2. Generate your personal age key (keep age.key OFFLINE; commit nothing)
age-keygen -o age.key
PUB=$(age-keygen -y age.key)                       # age1...

# 3. Point the repo's .sops.yaml at your public key
sed -i.bak "s|^      age: .*|      age: >-\n      $PUB|" .sops.yaml

# 4. Re-encrypt every existing secret with your key
#    (you'll need the maintainer's key once to decrypt; alternatively
#     wipe secrets/ and re-create per the per-secret guides below)
for f in secrets/*.enc.yaml; do
  sops updatekeys -y "$f"
done

# 5. Confirm round-trip
make decrypt-secrets   # writes *.dec.yaml (gitignored), prints check marks
```

If you don't have access to the existing keys (the common case for a fork), skip step 4 and use the **per-secret recreation** sections below to build each `*.enc.yaml` from scratch with your own credentials.

---

## 1. Why SOPS + age?

| Choice | Why |
|---|---|
| **SOPS** (Mozilla) | encrypts only the **values** of YAML/JSON, leaving keys readable for diff/review. Works with KMS, age, GPG, etc. |
| **age** | modern, simple X25519-based encryption. No key servers, no web of trust. One file (`age.key`) holds the operator's identity. |
| **Per-environment key** | each operator/environment generates their own `age.key`. The `.sops.yaml` lists which public keys can decrypt. Adding a teammate = appending their pubkey. |

---

## 2. Generate your `age.key`

```bash
# Install age (one of):
brew install age            # macOS
apt-get install age          # Debian/Ubuntu
winget install age           # Windows

# Generate identity
age-keygen -o age.key
chmod 600 age.key

# Print the public key (this is what you put in .sops.yaml)
age-keygen -y age.key
# → age1abc123...xyz
```

**Critical hygiene:**
- `age.key` is **gitignored** in this repo (`/age.key` in `.gitignore`). Verify before any commit.
- Back it up to a password manager / encrypted volume. If you lose it, you cannot decrypt any `*.enc.yaml`.
- For a team, every operator generates their own `age.key`. The `.sops.yaml` lists every operator's **public** key.

---

## 3. Configure `.sops.yaml`

The repo's `.sops.yaml` is a single creation rule that targets `secrets/*.enc.yaml`:

```yaml
creation_rules:
  - path_regex: secrets/.*\.enc\.yaml$
    age: >-
      age1hyy9xutt6aa3y67hea47st085hmnry8wg4qq3rqu7h9nn046hutqnnxvpv
```

To use **your own** key, replace the `age: >-` value with your public key from §2. To support **multiple** operators, append more keys with newlines:

```yaml
creation_rules:
  - path_regex: secrets/.*\.enc\.yaml$
    age: >-
      age1abc...you,
      age1def...teammate1,
      age1ghi...teammate2
```

Then run `sops updatekeys secrets/*.enc.yaml` to add the new recipients to existing files.

---

## 4. The 5 secrets — what they hold and how to obtain each

Run `ls secrets/` to see the canonical set:

```
anthropic.enc.yaml             # Anthropic API key (Claude Sonnet 4.5)
crossplane-gcp-creds.enc.yaml  # GCP SA JSON for Crossplane provider
langfuse.enc.yaml              # Langfuse Cloud public + secret keys
openai.enc.yaml                # OpenAI API key (kagent's querydoc sidecar)
supabase.enc.yaml              # Supabase URL + service-role key (dataset profiles)
```

Each section below tells you **what credentials you need**, **where to get them**, and **the exact YAML to encrypt**.

### 4.1 `anthropic.enc.yaml` — Claude API key

**What it does:** powers the planner (Sonnet 4.5), analyst, and writer LLM calls. Mounted into the kagent `app` container as `ANTHROPIC_API_KEY` env var (DD-20). Same value backs the `ModelConfig` CRD via `apiKeySecretRef`.

**How to obtain:**
1. Go to https://console.anthropic.com/settings/keys
2. **Create Key** → give it a name (e.g. `whisperops-dev`) → copy the `sk-ant-api03-…` value
3. Verify your tier supports `claude-sonnet-4-5-20250929` and `claude-haiku-4-5-20251001` (see https://docs.claude.com/en/docs/about-claude/models). Tier 1 is sufficient.

**Plaintext shape:**
```yaml
ANTHROPIC_API_KEY: sk-ant-api03-...
```

**Encrypt:**
```bash
SOPS_AGE_KEY_FILE=age.key sops --encrypt \
  --age $(age-keygen -y age.key) \
  --input-type yaml --output-type yaml \
  /tmp/anthropic.plaintext.yaml > secrets/anthropic.enc.yaml
rm /tmp/anthropic.plaintext.yaml
```

(The `--age` flag is redundant when `.sops.yaml` already lists your key; included here for clarity.)

### 4.2 `openai.enc.yaml` — OpenAI API key

**What it does:** kagent ships a `querydoc` sidecar that uses OpenAI for retrieval-augmented kagent-doc lookups. Stored as Secret `kagent-openai` in `kagent-system` namespace.

**How to obtain:**
1. https://platform.openai.com/api-keys → **Create new secret key** → copy `sk-…`

**Plaintext shape:**
```yaml
OPENAI_API_KEY: sk-proj-...
```

### 4.3 `langfuse.enc.yaml` — Langfuse Cloud (DD-24 v1.6)

**What it does:** dual-export of OTel traces from `opentelemetry-collector` to Langfuse Cloud, AND Grafana Infinity datasource auth for live querying (`https://us.cloud.langfuse.com/api/public/observations`). Also drives `budget-controller` cost polling (DD-28).

**How to obtain:**
1. Sign up at https://us.cloud.langfuse.com (free tier = 50k events/month, sufficient for prototype)
2. Create a project → Settings → **API Keys** → **Create new API keys**
3. Copy both `pk-lf-…` (public) and `sk-lf-…` (secret) immediately — the secret key is shown only once.

**Plaintext shape:**
```yaml
LANGFUSE_PUBLIC_KEY: pk-lf-...
LANGFUSE_SECRET_KEY: sk-lf-...
LANGFUSE_HOST: https://us.cloud.langfuse.com
```

> If you sign up on the EU region instead, change `LANGFUSE_HOST` to `https://cloud.langfuse.com`. The `make langfuse-secret` target derives `LANGFUSE_OTLP_ENDPOINT` and `LANGFUSE_BASIC_AUTH` from these three values.

### 4.4 `crossplane-gcp-creds.enc.yaml` — GCP SA for Crossplane provider

**What it does:** Crossplane's `provider-gcp-{storage,iam,cloudplatform}` family uses this Service Account JSON to provision per-agent GCS buckets, GCP SAs, SA keys, and project IAM bindings.

**How to obtain:**
1. After `make tf-apply`, Terraform outputs the bootstrap SA email (`whisperops-bootstrap@<project>.iam.gserviceaccount.com`). It already has the right roles (DD-19: `storage.admin`, `iam.serviceAccountAdmin`, `iam.serviceAccountKeyAdmin`, `resourcemanager.projectIamAdmin` — all unconditional).
2. Mint a key:
   ```bash
   gcloud iam service-accounts keys create /tmp/sa-key.json \
     --iam-account=whisperops-bootstrap@<project>.iam.gserviceaccount.com
   ```
3. The JSON has literal newlines inside `private_key`. Crossplane requires a clean JSON string. Repair before encrypting:
   ```bash
   python3 -c "import json,sys; print(json.dumps(json.load(open('/tmp/sa-key.json'))))" > /tmp/sa-key.flat.json
   ```

**Plaintext shape:**
```yaml
gcp_service_account_key_json: |
  {"type": "service_account", "project_id": "...", "private_key": "-----BEGIN PRIVATE KEY-----\\n…", ...}
```

The pipe-string-with-`|` style is fine — but the value MUST be a single-line JSON (no real newlines inside the `private_key` field). When Crossplane reads this back, the `\\n` sequences become real newlines via JSON unmarshal.

**Quick command to assemble:**
```bash
{
  echo "gcp_service_account_key_json: |"
  cat /tmp/sa-key.flat.json | sed 's/^/  /'
} > /tmp/crossplane-gcp-creds.plaintext.yaml

SOPS_AGE_KEY_FILE=age.key sops --encrypt \
  --input-type yaml --output-type yaml \
  /tmp/crossplane-gcp-creds.plaintext.yaml > secrets/crossplane-gcp-creds.enc.yaml

rm /tmp/sa-key.json /tmp/sa-key.flat.json /tmp/crossplane-gcp-creds.plaintext.yaml
```

### 4.5 `supabase.enc.yaml` — dataset profile store

**What it does:** the platform-bootstrap Job uploads dataset profiles (column types, row counts, sample values) to a Supabase Postgres table. Read by Backstage at agent-creation time to populate the dataset dropdown metadata.

**How to obtain:**
1. https://supabase.com/dashboard → **New Project** (free tier OK)
2. Project Settings → **API** → copy:
   - Project URL (`https://<ref>.supabase.co`)
   - `service_role` key (starts with `eyJ…`, full RW)
   - `anon` key (read-only, used by the chat UI for unauth'd dataset enum lookup)

**Plaintext shape:**
```yaml
SUPABASE_URL: https://<ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY: eyJ...
SUPABASE_ANON_KEY: eyJ...
```

> If you don't want Supabase, the platform tolerates this Secret being absent at the cost of not surfacing dataset profiles in the Backstage form. Future work could swap to a self-hosted Postgres in cluster.

---

## 5. Encrypt + verify workflow

For each plaintext file you assembled in §4:

```bash
# Encrypt in place (or with explicit input)
SOPS_AGE_KEY_FILE=age.key sops --encrypt \
  --input-type yaml --output-type yaml \
  /tmp/<name>.plaintext.yaml > secrets/<name>.enc.yaml

# Wipe the plaintext (don't leave it on disk)
shred -u /tmp/<name>.plaintext.yaml 2>/dev/null || rm /tmp/<name>.plaintext.yaml

# Verify round-trip
SOPS_AGE_KEY_FILE=age.key sops --decrypt secrets/<name>.enc.yaml | head -3
```

The repo's `make decrypt-secrets` target does the round-trip for **all** files:

```bash
make decrypt-secrets    # writes secrets/*.dec.yaml (gitignored)
ls secrets/*.dec.yaml
rm secrets/*.dec.yaml   # or leave them — they're git-ignored
```

---

## 6. Editing an existing encrypted file

```bash
SOPS_AGE_KEY_FILE=age.key sops secrets/anthropic.enc.yaml
# opens $EDITOR with decrypted content; saves back encrypted
```

This is the canonical way to rotate a key — never decrypt-then-edit-then-re-encrypt manually.

---

## 7. Adding a teammate

1. Teammate generates their `age.key` (§2), shares the **public** key (`age1…`).
2. Add to `.sops.yaml`:
   ```yaml
   creation_rules:
     - path_regex: secrets/.*\.enc\.yaml$
       age: >-
         age1hyy9...your_existing_key,
         age1abc...new_teammate
   ```
3. Re-key existing files:
   ```bash
   sops updatekeys -y secrets/*.enc.yaml
   ```
4. Commit `.sops.yaml` + the re-keyed `*.enc.yaml` files.

---

## 8. Materializing secrets in the cluster

After the `*.enc.yaml` files are encrypted with your keys, the platform layer applies them as Kubernetes Secrets through:

| Secret | Target ns | Mechanism |
|---|---|---|
| `anthropic-api-key` | `kagent-system` | `kubectl create secret` from SOPS-decrypt (manual at deploy time) |
| `kagent-openai` | `kagent-system` | same |
| `langfuse-credentials` | `observability` | `make langfuse-secret` (DD-29) — derives 5 keys from the SOPS source |
| `gcp-bootstrap-sa-key` | `crossplane-system` | manual `kubectl apply` — see [docs/OPERATIONS.md §1 Stage 5](OPERATIONS.md#stage-5--secrets-materialization) for the JSON-newline-repair step |
| `supabase-credentials` | `whisperops-system` | platform-bootstrap Job reads via SOPS at runtime |

The end-to-end ordering matters — see [OPERATIONS.md §1 Stage 5](OPERATIONS.md) for the canonical sequence.

---

## 9. Common errors & fixes

| Symptom | Cause | Fix |
|---|---|---|
| `sops: failed to decrypt: no matching age recipient` | Your `age.key` public is not in `.sops.yaml` | Add your pubkey to `.sops.yaml` and run `sops updatekeys` (someone with an existing key must do this) |
| `MAC mismatch` on decrypt | File was edited outside `sops` (broke the integrity hash) | Re-encrypt from a clean plaintext copy |
| Crossplane provider reports `error unmarshaling credentials: invalid character '\n' in string literal` | `private_key` in the GCP SA JSON has real newlines, not `\\n` | Re-encrypt the file using the `python3 json.dumps()` flatten step in §4.4 |
| `SOPS_AGE_KEY_FILE` not set in shell | env var doesn't persist across Claude Code bash invocations and some CI runners | Always pass it inline: `SOPS_AGE_KEY_FILE=age.key sops ...` |
| Re-encrypting a file produces a huge diff | sops re-rolls the AES key on every write — this is normal. Do not optimize for "minimal diff" | Accept the diff; it's still secure |

---

## 10. Tear down

To wipe all secrets from a cluster (e.g. when rotating compromised credentials):

```bash
kubectl -n kagent-system delete secret anthropic-api-key kagent-openai
kubectl -n observability delete secret langfuse-credentials
kubectl -n whisperops-system delete secret langfuse-credentials supabase-credentials
kubectl -n crossplane-system delete secret gcp-bootstrap-sa-key
kubectl -n agent-* delete secret ar-pull-secret langfuse-credentials anthropic-api-key
```

Then re-run the materialization steps in §8 with fresh, rotated values.

---

## See also

- [docs/OPERATIONS.md §1 Stage 5](OPERATIONS.md) — exact `kubectl create secret` invocations per Secret
- [docs/SECURITY.md](SECURITY.md) — broader security model (RBAC, network policies, image signing)
- [.sops.yaml](../.sops.yaml) — current creation rules (only operator-facing config file)
- [Makefile](../Makefile) — `decrypt-secrets`, `langfuse-secret`, `ar-pull-secret` targets
- DESIGN §13 (in `.claude/sdd/features/DESIGN_whisperops.md`) — decision log for security-relevant choices (DD-19 IAM Conditions removal, DD-29 langfuse-secret Makefile path)
