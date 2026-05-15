# Runbook: Budget Kill-Switch

**Trigger:** `BudgetBurnPage` alert fires in Mimir → `budget-controller` scales agent to 0 replicas.

**Severity:** P2 (agent down, no data loss)

---

## What happened

The Mimir Ruler evaluated the `whisperops_spend_usd:cumulative` recording rule and found that a per-agent cumulative spend reached or exceeded the `budget_usd` annotation on the agent's namespace. The `BudgetBurnPage` alert was set to `firing` with `labels.action=killswitch`. The `budget-controller` polled the Mimir alerts API, saw the firing alert, and scaled all Deployments in the agent namespace to 0 replicas.

## Verification steps

```bash
alias kk='gcloud compute ssh whisperops-vm --zone=us-central1-a --command'

# 1. Confirm the agent is scaled to 0
kk 'sudo kubectl get deploy -n agent-{name}'
# All replicas should show 0

# 2. Confirm the BudgetBurnPage alert is firing
kk 'sudo kubectl exec -n observability deploy/lgtm-distributed-mimir-nginx -- \
  wget -qO- "http://localhost:80/prometheus/api/v1/alerts" \
  | python3 -m json.tool | grep -A10 BudgetBurnPage'

# 3. Check budget-controller logs for the killswitch action
kk 'sudo kubectl logs -n whisperops-system deploy/budget-controller --tail=100 | grep -i killswitch'

# 4. Check the current spend vs budget annotation
kk 'sudo kubectl get namespace agent-{name} -o jsonpath="{.metadata.annotations}"'
# Look for whisperops.io/budget-usd
```

## Resolution: top-up and re-enable

**Step 1: Increase the budget annotation** (or confirm the operator wants to re-enable at same budget):

```bash
# Increase budget (e.g. from 5.00 to 10.00)
kk 'sudo kubectl annotate namespace agent-{name} whisperops.io/budget-usd="10.00" --overwrite'
```

**Step 2: Scale deployments back up:**

```bash
kk 'sudo kubectl scale deploy planner worker sandbox chat-frontend \
  -n agent-{name} --replicas=1'
```

**Step 3: Verify pods are running:**

```bash
kk 'sudo kubectl get pods -n agent-{name}'
# All 4 deployments (planner, worker, sandbox, chat-frontend) should show Running
```

**Step 4: Verify budget-controller no longer fires the kill-switch:**

```bash
# Wait ~60s for budget-controller's next poll cycle, then check logs
kk 'sudo kubectl logs -n whisperops-system deploy/budget-controller --tail=30'
# Should show "no killswitch alerts firing" or similar
```

## If the alert keeps re-firing

The `whisperops_spend_usd:cumulative` recording rule uses a 1-day `increase()` window. If spend was incurred today it will keep appearing until the window rolls off. Options:

1. **Set a higher budget**: safest — the agent resumes and the operator controls future spend.
2. **Reset the spend window**: not directly possible via PromQL — the underlying `whisperops_tokens_*` counters are cumulative. The effective reset happens at the metric expiry boundary (24h window slides forward).
3. **Silence the alert temporarily**: in Grafana Alerting → Silences → add a silence for `alertname=BudgetBurnPage, agent_name={name}` with a fixed duration. This prevents the kill-switch from firing again during the silence window.

## BudgetBurnWarn (80%)

The `BudgetBurnWarn` alert fires at 80% of budget (severity: warn). The budget-controller emits a Kubernetes Warning Event to the agent namespace but does NOT scale to 0. This is informational — the operator may choose to increase the budget proactively.

```bash
# View warning events for an agent namespace
kk 'sudo kubectl get events -n agent-{name} --field-selector type=Warning'
```

## Related

- `docs/ARCHITECTURE.md §budget-controller` — how the kill-switch is wired
- `docs/OPERATIONS.md §Budget kill-switch` — quick diagnostic commands
- `platform/observability/mimir-ruler-rules/budget-burn.yaml` — the PromQL recording rule and alert definitions
- `src/budget-controller/main.py` — kill-switch implementation
