# Discord Notifications for the Kubernetes Homelab — Design

**Date:** 2026-06-12
**Status:** Implemented (PR #80, commit 1ac76d9)

## Goal

Forward two classes of Kubernetes events to Discord, routed across four channels under the **📡 HOMELAB-K8S** category:

| Channel | ID | Source |
|---------|-----|--------|
| `#alerts-critical` | `1514664712128692396` | Alertmanager, `severity=critical` |
| `#alerts-warning` | `1514664715199189133` | Alertmanager, `severity=warning` |
| `#deployments` | `1514664718038597724` | ArgoCD `on-sync-failed` + `on-deployed` |
| `#cluster-events` | `1514664721553297599` | ArgoCD `on-health-degraded` + `on-sync-running` |

Four channels → **four** Discord webhooks → four secret values.

## Non-goals

- No new long-running components. Uses controllers already deployed (Alertmanager via the VM operator; the argocd-notifications controller bundled in the argo-cd chart).
- No `alertmanager-discord` bridge — Alertmanager v0.28.1 supports Discord natively.
- No raw Kubernetes Event streaming (no event-exporter). Explicitly out of scope.
- No plaintext webhook URLs in git — all four are stored as SealedSecrets.

## Current-state facts (verified)

- `dev/victoria-metrics/charts/.../values.yaml`: `alertmanager.enabled: true`, image `v0.28.1`, `useManagedConfig: false`, default route → `blackhole`. `alertmanager.spec.secrets` mounts named secrets at `/etc/alertmanager/secrets/<name>/`, one file per key.
- Alertmanager v0.28.1 supports `discord_configs` (since 0.25) and `webhook_url_file` (since 0.27).
- `dev/argocd/kustomization.yaml`: argo-cd chart `9.2.2`, which ships the notifications controller (enabled by default).
- Secrets are sealed with `scripts/s2ss.sh <file>` (seals a `kind: Secret` YAML in place via `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets`). SealedSecrets are namespace-scoped.
- Local render: `./scripts/build.sh <dir> [namespace]` (`kustomize build --enable-helm`).
- Discord guild `842211856226975764`; the four target channels exist (IDs above).

## Architecture

```
[VM defaultRules] -> [VMAlert] -> [Alertmanager v0.28.1]
                                     |  route by severity
                                     |--- critical --> discord-critical (webhook_url_file) --> #alerts-critical
                                     '--- warning  --> discord-warning  (webhook_url_file) --> #alerts-warning
                                     (info / Watchdog / InfoInhibitor -> blackhole)
        SealedSecret: discord-webhook { webhook-critical, webhook-warning }   (ns victoria-metrics)

[ArgoCD Applications] -> [argocd-notifications-controller]
                                     |  subscriptions
                                     |--- sync-failed, deployed       --> svc discord-deployments    --> #deployments
                                     '--- health-degraded, sync-running --> svc discord-cluster-events --> #cluster-events
        SealedSecret: argocd-notifications-secret { discord-deployments, discord-cluster-events }   (ns argocd)
```

Two independent integrations. They share only the SealedSecrets *pattern*, never a secret value.

## Prerequisite (user, manual — cannot be automated by the agent)

Create **four** Incoming Webhooks in Discord (Server Settings → Integrations → Webhooks, or `POST /channels/{id}/webhooks` with the bot token), one bound to each channel above. Collect the four URLs; they fill the secret templates before sealing.

(Optional automation: the four webhooks can be created via the Discord REST API using the bot token. If chosen, the URLs are written straight into the local plain-Secret files and sealed immediately, minimizing plaintext exposure. Decided at implementation time.)

## Component 1 — Alertmanager → Discord (severity-split)

### Secret

New file `dev/victoria-metrics/secrets/discord-webhook.yaml`, authored as a plain Secret then sealed in place:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: discord-webhook
  namespace: victoria-metrics
stringData:
  webhook-critical: "https://discord.com/api/webhooks/<CRITICAL_WEBHOOK>"
  webhook-warning:  "https://discord.com/api/webhooks/<WARNING_WEBHOOK>"
```

Seal: `./scripts/s2ss.sh dev/victoria-metrics/secrets/discord-webhook.yaml`
Register: add `secrets/discord-webhook.yaml` to `dev/victoria-metrics/kustomization.yaml` `resources`.

### Config (`dev/victoria-metrics/values-k8s-stack.yaml`)

Add an `alertmanager` block:

```yaml
alertmanager:
  spec:
    secrets:
      - discord-webhook          # files at /etc/alertmanager/secrets/discord-webhook/{webhook-critical,webhook-warning}
  config:
    route:
      receiver: blackhole         # default: drop anything unmatched (incl. info)
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - matchers: ['alertname=~"Watchdog|InfoInhibitor"']
          receiver: blackhole     # drop heartbeats explicitly
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

Severity filter satisfied: only `critical`/`warning` reach a Discord receiver; info + heartbeats hit `blackhole`. Default discord title/message templates are used (color is red while firing, green on resolve). Custom `alertmanager.templateFiles` may be added later if richer formatting is wanted.

## Component 2 — ArgoCD → Discord (two webhook services)

### Secret

New file `dev/argocd/notifications-secret.yaml`, authored as plain Secret then sealed:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
stringData:
  discord-deployments:    "https://discord.com/api/webhooks/<DEPLOYMENTS_WEBHOOK>"
  discord-cluster-events: "https://discord.com/api/webhooks/<CLUSTER_EVENTS_WEBHOOK>"
```

Seal: `./scripts/s2ss.sh dev/argocd/notifications-secret.yaml`
Register: add `notifications-secret.yaml` to `dev/argocd/kustomization.yaml` `resources`.
The chart must NOT also create this secret → set `notifications.secret.create: false` (exact key verified during planning).

### Config (`dev/argocd/values.yaml`)

Add a `notifications` block. Two webhook services, color-coded embeds, dynamic strings individually `quote`d (sprig) so error text with quotes/newlines cannot break the JSON:

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

Notes:
- A webhook template's `webhook:` key MUST equal the target service name (`discord-deployments` / `discord-cluster-events`); each trigger's `send:` references the matching template.
- Default `subscriptions` apply to all Applications — no per-app annotations needed.
- `on-sync-running` is intentionally chatty (fires on every sync start), routed to `#cluster-events`. Drop later by removing one trigger + one subscription entry.
- Color ints: red `15158332`, orange `15105570`, green `3066993`, blue `3447003`.

## Error handling

- **Bad/empty webhook URL** → controller logs a send error and retries; nothing crashes on our side, but Discord won't receive it. Caught at the live-test step.
- **JSON-breaking ArgoCD message** → mitigated by per-field `| quote`.
- **Secret not mounted** (Alertmanager) → Alertmanager fails config load at runtime. Verified post-deploy via pod logs.

## Verification

1. `./scripts/build.sh dev/victoria-metrics` and `./scripts/build.sh dev/argocd` both render without error and include the new resources.
2. After ArgoCD syncs:
   - Alertmanager: `kubectl -n victoria-metrics get secret discord-webhook`; check the rendered Alertmanager config + pod logs. Optionally fire a synthetic critical + warning alert and confirm each lands in the correct channel.
   - ArgoCD: trigger a sync (trivial app change) → message in `#deployments` (deployed) and `#cluster-events` (sync-running); force a sync failure → message in `#deployments`.

## Open items to resolve during planning

- Confirm the exact argo-cd chart key to disable chart-managed notifications secret (`notifications.secret.create`).
- Confirm `argocd-notifications-secret` needs no extra labels for the controller to read it.
- Decide webhook provisioning method (manual UI vs bot-token API) — affects only how the four URLs are obtained, not the manifests.

## File change summary

| File | Change |
|------|--------|
| `dev/victoria-metrics/secrets/discord-webhook.yaml` | NEW — SealedSecret, 2 keys (critical/warning webhooks) |
| `dev/victoria-metrics/kustomization.yaml` | add secret to `resources` |
| `dev/victoria-metrics/values-k8s-stack.yaml` | add `alertmanager.spec.secrets` + severity-split `alertmanager.config` |
| `dev/argocd/notifications-secret.yaml` | NEW — SealedSecret, 2 keys (deployments/cluster-events webhooks) |
| `dev/argocd/kustomization.yaml` | add secret to `resources` |
| `dev/argocd/values.yaml` | add `notifications` block (2 services, 4 templates/triggers, subscriptions), disable chart-managed secret |
