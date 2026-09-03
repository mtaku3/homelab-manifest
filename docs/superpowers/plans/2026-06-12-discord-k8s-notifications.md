# Discord k8s Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward Alertmanager alerts (severity-split) and ArgoCD deploy events to four Discord channels, using only controllers already running, with webhook URLs stored as SealedSecrets.

**Architecture:** Alertmanager (victoria-metrics-k8s-stack, v0.28.1) uses native `discord_configs` with `webhook_url_file` reading a mounted SealedSecret; routes `critical`/`warning` to two receivers. The argocd-notifications controller (bundled in the argo-cd chart) uses two `webhook` services with color-coded embeds, fed from a sealed `argocd-notifications-secret`. No new long-running components.

**Tech Stack:** Kustomize + Helm (`--enable-helm`), VictoriaMetrics k8s-stack chart 0.63.1, argo-cd chart 9.2.2, Bitnami SealedSecrets (`kubeseal`), Alertmanager 0.28.1.

**Spec:** `docs/superpowers/specs/2026-06-12-discord-k8s-notifications-design.md`

**Channel → webhook map (guild `842211856226975764`):**

| Channel | ID | Fed by |
|---------|-----|--------|
| `#alerts-critical` | `1514664712128692396` | Alertmanager `severity=critical` |
| `#alerts-warning` | `1514664715199189133` | Alertmanager `severity=warning` |
| `#deployments` | `1514664718038597724` | ArgoCD `sync-failed` + `deployed` |
| `#cluster-events` | `1514664721553297599` | ArgoCD `health-degraded` + `sync-running` |

**Environment notes:**
- `./scripts/build.sh <dir>` runs `kustomize build --enable-helm`. The argo-cd chart is **not** vendored, so the first render fetches it from `argoproj.github.io` (needs network). If the shell is sandboxed, run render/seal steps via the `!` prefix or with sandbox disabled.
- `./scripts/s2ss.sh <file>` seals a `kind: Secret` in place via `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets` (talks to the apiserver at `192.168.10.102`).
- `grep` is aliased to `ugrep`: plain `grep PATTERN` works; avoid `--include`.
- **Secret hygiene:** never paste a webhook URL into chat or commit it unsealed. Edit the plain-Secret file locally, run `s2ss.sh`, confirm the file is now `kind: SealedSecret`, *then* `git add`.

---

### Task 0: Create the feature branch

**Files:** none

- [ ] **Step 1: Branch off main**

Run:
```bash
cd /home/mtaku3/Workspaces/homelab-manifest
git checkout -b feat/discord-notifications
```
Expected: `Switched to a new branch 'feat/discord-notifications'`

---

### Task 1: Provision the four Discord webhooks

**Files:** none (produces four webhook URLs, held locally — not committed, not pasted into chat)

Pick ONE method.

- [ ] **Step 1 (Option A — Discord UI):** In each channel (`#alerts-critical`, `#alerts-warning`, `#deployments`, `#cluster-events`): Channel → Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL. Keep the four URLs in a local scratch file you will delete.

- [ ] **Step 1 (Option B — bot-token API, run in YOUR shell with `!`):** Creates one webhook per channel and prints `channel_id → url`. Run, then copy the URLs.

```
! TOKEN=$(grep '^DISCORD_BOT_TOKEN=' ~/.claude/channels/discord/.env | cut -d= -f2- | tr -d '"'); for C in 1514664712128692396 1514664715199189133 1514664718038597724 1514664721553297599; do curl -s -X POST -H "Authorization: Bot $TOKEN" -H "User-Agent: DiscordBot (homelab,1.0)" -H "Content-Type: application/json" -d '{"name":"k8s-notify"}' "https://discord.com/api/v10/channels/$C/webhooks" | python3 -c "import sys,json;w=json.load(sys.stdin);print('%s -> %s'%(w.get('channel_id'),w.get('url')) if 'url' in w else 'ERR: %r'%w)"; done
```
Expected: four `channel_id -> https://discord.com/api/webhooks/.../...` lines. (If `ERR` with code 50013, the bot lacks **Manage Webhooks** — grant it or use Option A.)

Map the four URLs to: critical = `1514664712128692396`, warning = `1514664715199189133`, deployments = `1514664718038597724`, cluster-events = `1514664721553297599`.

---

### Task 2: Alertmanager Discord SealedSecret

**Files:**
- Create: `dev/victoria-metrics/secrets/discord-webhook.yaml`
- Modify: `dev/victoria-metrics/kustomization.yaml:23` (append to `resources`)

- [ ] **Step 1: Write the plain Secret (placeholders), then fill URLs locally**

Create `dev/victoria-metrics/secrets/discord-webhook.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: discord-webhook
  namespace: victoria-metrics
stringData:
  webhook-critical: "REPLACE_WITH_CRITICAL_WEBHOOK_URL"
  webhook-warning: "REPLACE_WITH_WARNING_WEBHOOK_URL"
```
Then edit the file in your editor, replacing both placeholders with the real URLs from Task 1.

- [ ] **Step 2: Seal in place**

Run:
```bash
./scripts/s2ss.sh dev/victoria-metrics/secrets/discord-webhook.yaml
```
Expected: `✅ Successfully sealed dev/victoria-metrics/secrets/discord-webhook.yaml`

- [ ] **Step 3: Verify it is sealed (no plaintext URL remains)**

Run:
```bash
head -5 dev/victoria-metrics/secrets/discord-webhook.yaml
grep -c 'discord.com/api/webhooks' dev/victoria-metrics/secrets/discord-webhook.yaml
```
Expected: `kind: SealedSecret` in the head; the grep prints `0` (no plaintext URL).

- [ ] **Step 4: Register the secret in the kustomization**

In `dev/victoria-metrics/kustomization.yaml`, add to the `resources:` list (after `secrets/etcd-certs.yaml`):
```yaml
  - secrets/discord-webhook.yaml
```

- [ ] **Step 5: Render to confirm it builds and includes the SealedSecret**

Run:
```bash
./scripts/build.sh dev/victoria-metrics > /tmp/vm.yaml && grep -A2 'name: discord-webhook' /tmp/vm.yaml
```
Expected: exit 0; output shows the `discord-webhook` SealedSecret. (Render uses the vendored VM chart under `charts/`, so this works offline.)

- [ ] **Step 6: Commit**

```bash
git add dev/victoria-metrics/secrets/discord-webhook.yaml dev/victoria-metrics/kustomization.yaml
git commit -m "feat(victoria-metrics): add sealed Discord webhook secret"
```

---

### Task 3: Alertmanager severity-split Discord config

**Files:**
- Modify: `dev/victoria-metrics/values-k8s-stack.yaml` (append top-level `alertmanager:` block)

- [ ] **Step 1: Add the alertmanager block**

Append to `dev/victoria-metrics/values-k8s-stack.yaml`:
```yaml
alertmanager:
  spec:
    secrets:
      - discord-webhook
  config:
    route:
      receiver: blackhole
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - matchers: ['alertname=~"Watchdog|InfoInhibitor"']
          receiver: blackhole
        - matchers: ['severity="critical"']
          receiver: discord-critical
        - matchers: ['severity="warning"']
          receiver: discord-warning
    receivers:
      - name: blackhole
      - name: discord-critical
        discord_configs:
          - webhook_url_file: /etc/alertmanager/secrets/discord-webhook/webhook-critical
            send_resolved: true
      - name: discord-warning
        discord_configs:
          - webhook_url_file: /etc/alertmanager/secrets/discord-webhook/webhook-warning
            send_resolved: true
```

- [ ] **Step 2: Render and verify the config reached the manifest**

Run:
```bash
./scripts/build.sh dev/victoria-metrics > /tmp/vm.yaml; echo "exit=$?"; grep -c 'discord-critical\|discord-warning\|webhook_url_file' /tmp/vm.yaml
```
Expected: `exit=0`; grep count `>= 3`. (The VM chart renders the alertmanager config as plaintext in a Secret's `stringData`, so the receiver names appear.) If the count is `0`, the config did not merge — check that `alertmanager:` is top-level (column 0) in the values file.

- [ ] **Step 3: Verify the secret mount is on the VMAlertmanager CR**

Run:
```bash
grep -A4 'kind: VMAlertmanager' /tmp/vm.yaml | grep -A3 'secrets:'
```
Expected: shows `- discord-webhook` under the VMAlertmanager `spec.secrets`.

- [ ] **Step 4: Commit**

```bash
git add dev/victoria-metrics/values-k8s-stack.yaml
git commit -m "feat(victoria-metrics): route critical/warning alerts to Discord"
```

---

### Task 4: ArgoCD notifications SealedSecret + disable chart-managed secret

**Files:**
- Create: `dev/argocd/notifications-secret.yaml`
- Modify: `dev/argocd/kustomization.yaml:14` (append to `resources`)

(The `notifications.secret.create: false` key that tells the chart not to also create this secret is added in Task 5's block, kept together with the rest of the `notifications:` config.)

- [ ] **Step 1: Write the plain Secret (placeholders), then fill URLs locally**

Create `dev/argocd/notifications-secret.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
stringData:
  discord-deployments: "REPLACE_WITH_DEPLOYMENTS_WEBHOOK_URL"
  discord-cluster-events: "REPLACE_WITH_CLUSTER_EVENTS_WEBHOOK_URL"
```
Edit the file, replacing both placeholders with the real URLs from Task 1.

- [ ] **Step 2: Seal in place**

Run:
```bash
./scripts/s2ss.sh dev/argocd/notifications-secret.yaml
```
Expected: `✅ Successfully sealed dev/argocd/notifications-secret.yaml`

- [ ] **Step 3: Verify it is sealed**

Run:
```bash
head -5 dev/argocd/notifications-secret.yaml
grep -c 'discord.com/api/webhooks' dev/argocd/notifications-secret.yaml
```
Expected: `kind: SealedSecret`; grep prints `0`.

- [ ] **Step 4: Register the secret in the kustomization**

In `dev/argocd/kustomization.yaml`, add to `resources:` (after `repo-mfsm.yaml`):
```yaml
  - notifications-secret.yaml
```

- [ ] **Step 5: Commit**

```bash
git add dev/argocd/notifications-secret.yaml dev/argocd/kustomization.yaml
git commit -m "feat(argocd): add sealed Discord notifications secret"
```

---

### Task 5: ArgoCD notifications config (two webhook services, embeds)

**Files:**
- Modify: `dev/argocd/values.yaml` (append top-level `notifications:` block)

- [ ] **Step 1: Add the notifications block**

Append to `dev/argocd/values.yaml`:
```yaml
notifications:
  secret:
    create: false
  notifiers:
    service.webhook.discord-deployments: |
      url: $discord-deployments
      headers:
        - name: Content-Type
          value: application/json
    service.webhook.discord-cluster-events: |
      url: $discord-cluster-events
      headers:
        - name: Content-Type
          value: application/json
  templates:
    template.discord-sync-failed: |
      webhook:
        discord-deployments:
          method: POST
          body: |
            {"embeds":[{"title":{{ printf "❌ %s — sync failed" .app.metadata.name | quote }},"description":{{ .app.status.operationState.message | quote }},"color":15158332}]}
    template.discord-deployed: |
      webhook:
        discord-deployments:
          method: POST
          body: |
            {"embeds":[{"title":{{ printf "✅ %s — deployed" .app.metadata.name | quote }},"description":{{ printf "revision %s" .app.status.sync.revision | quote }},"color":3066993}]}
    template.discord-health-degraded: |
      webhook:
        discord-cluster-events:
          method: POST
          body: |
            {"embeds":[{"title":{{ printf "⚠️ %s — Degraded" .app.metadata.name | quote }},"description":{{ .app.status.health.message | quote }},"color":15105570}]}
    template.discord-sync-running: |
      webhook:
        discord-cluster-events:
          method: POST
          body: |
            {"embeds":[{"title":{{ printf "🔄 %s — sync running" .app.metadata.name | quote }},"color":3447003}]}
  triggers:
    trigger.on-sync-failed: |
      - when: app.status.operationState.phase in ['Error', 'Failed']
        send: [discord-sync-failed]
    trigger.on-deployed: |
      - when: app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy'
        send: [discord-deployed]
        oncePer: app.status.sync.revision
    trigger.on-health-degraded: |
      - when: app.status.health.status == 'Degraded'
        send: [discord-health-degraded]
    trigger.on-sync-running: |
      - when: app.status.operationState.phase in ['Running']
        send: [discord-sync-running]
  subscriptions:
    - recipients: [discord-deployments]
      triggers: [on-sync-failed, on-deployed]
    - recipients: [discord-cluster-events]
      triggers: [on-health-degraded, on-sync-running]
```

- [ ] **Step 2: Render and verify the config reached argocd-notifications-cm**

Run (needs network to fetch the argo-cd chart on first build):
```bash
./scripts/build.sh dev/argocd > /tmp/argocd.yaml; echo "exit=$?"; grep -c 'service.webhook.discord-deployments\|service.webhook.discord-cluster-events\|discord-sync-failed\|discord-sync-running' /tmp/argocd.yaml
```
Expected: `exit=0`; grep count `>= 4`. If exit is non-zero with a network error and the shell is sandboxed, re-run via `! ./scripts/build.sh dev/argocd > /tmp/argocd.yaml`.

- [ ] **Step 3: Verify the chart did NOT create a second notifications secret**

Run:
```bash
grep -B1 'name: argocd-notifications-secret' /tmp/argocd.yaml | grep 'kind:'
```
Expected: exactly one match, `kind: SealedSecret` (ours). If a `kind: Secret` also appears, the `notifications.secret.create: false` key is wrong for this chart version — check `dev/argocd/charts/.../values.yaml` (after first render the chart is cached under `dev/argocd/charts/`) for the correct key and fix.

- [ ] **Step 4: Commit**

```bash
git add dev/argocd/values.yaml
git commit -m "feat(argocd): send deploy + cluster events to Discord"
```

---

### Task 6: Deploy and live-verify

**Files:** none

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push -u origin feat/discord-notifications
gh pr create --fill
```
Expected: PR URL printed. (ArgoCD reconciles from `main`; merge when ready, or point a test app at the branch.)

- [ ] **Step 2: After merge + sync, confirm the Alertmanager secret is mounted**

Run:
```bash
kubectl -n victoria-metrics get secret discord-webhook
kubectl -n victoria-metrics logs statefulset/vmalertmanager-vm-victoria-metrics-k8s-stack -c alertmanager --tail=50 | grep -i 'error\|discord' || echo "no config errors"
```
Expected: secret exists; no config-load errors in the alertmanager log.

- [ ] **Step 3: Fire a synthetic alert to each severity (optional but recommended)**

Use the Alertmanager API to push one `critical` and one `warning` test alert (replace the service/port if different):
```bash
kubectl -n victoria-metrics port-forward svc/vmalertmanager-vm-victoria-metrics-k8s-stack 9093:9093 &
PF=$!
sleep 3
for SEV in critical warning; do
  curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
    -d "[{\"labels\":{\"alertname\":\"DiscordTest\",\"severity\":\"$SEV\"},\"annotations\":{\"summary\":\"test $SEV\"}}]"
done
kill $PF
```
Expected: the `critical` alert appears in `#alerts-critical`, the `warning` alert in `#alerts-warning` (within ~`group_wait` = 30s).

- [ ] **Step 4: Verify ArgoCD events**

Trigger a trivial sync on any app (e.g. `argocd app sync <app>` or a no-op manifest change). Expected: a `🔄 sync running` embed in `#cluster-events`, then a `✅ deployed` embed in `#deployments`. To test failure, point an app at a bad revision and confirm a `❌ sync failed` embed in `#deployments`.

- [ ] **Step 5: Delete the local scratch file holding raw webhook URLs (if you made one in Task 1).**

---

### Task 7: Finish the branch

- [ ] **Step 1:** Use superpowers:finishing-a-development-branch to merge the PR and clean up the branch.

---

## Notes for the executor

- Tasks 2–5 are independent edits but Task 3 depends on Task 2's secret name, and Task 5 depends on Task 4's secret + keys. Keep the order.
- If `s2ss.sh` fails to reach the controller, confirm `kubectl` context points at the homelab cluster (apiserver `192.168.10.102`) and that the `sealed-secrets` controller is in namespace `sealed-secrets`.
- The `| quote` sprig function in the ArgoCD templates is what keeps arbitrary error text from breaking the embed JSON — do not remove it.
