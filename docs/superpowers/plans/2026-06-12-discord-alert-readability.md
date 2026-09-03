# Discord Alert Readability + Deep-Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Alertmanager→Discord alerts readable (custom embed), deliver one message per alert, and link to Grafana.

**Architecture:** Edit the `alertmanager` block in the VictoriaMetrics k8s-stack Helm values. Set `group_by: ['...']` to disable bundling, and add inline `title`/`message` Go templates (shared via YAML anchors) to both Discord receivers. No new objects, ingress, or secrets.

**Tech Stack:** VictoriaMetrics k8s-stack chart 0.63.1, Alertmanager `discord_configs`, Go text/template, kustomize+Helm, ArgoCD.

---

## Background facts (verified)

- Config lives only in `dev/victoria-metrics/values-k8s-stack.yaml`, alertmanager block (current lines 115–138).
- Chart renders `alertmanager.config` via plain `toYaml` (no `tpl`) — see `charts/victoria-metrics-k8s-stack-0.63.1/.../templates/victoria-metrics-operator/vmalertmanager/vmalertmanager.yaml:28`. So `{{ ... }}` Go templates inside the strings pass through to Alertmanager untouched. Safe.
- Pods dashboard UID = `k8s_views_pods` with template vars `namespace`, `pod` (confirmed in `files/dashboards/generated/kubernetes-views-pods.yaml`).
- Grafana exposed at `https://grafana.mtaku3.com`. Alertmanager/vmalert NOT exposed (intentional).
- Render command: `kustomize build --enable-helm dev/victoria-metrics`.

## File Structure

- Modify: `dev/victoria-metrics/values-k8s-stack.yaml` (alertmanager `config` block only). Single file, single responsibility.

---

## Task 1: Rewrite the alertmanager config block

**Files:**
- Modify: `dev/victoria-metrics/values-k8s-stack.yaml:115-138`

- [ ] **Step 1: Replace the `config:` block**

Replace the existing `config:` block (currently lines 115–138, starting at `  config:` under `alertmanager:`) with exactly this. `group_by: ['...']` disables aggregation (one message per alert); the `&discord_title` / `&discord_message` anchors are reused by the warning receiver (DRY).

```yaml
  config:
    route:
      receiver: blackhole
      group_by: ['...']
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
          - webhook_url_file: /etc/vm/secrets/discord-webhook/webhook-critical
            send_resolved: true
            title: &discord_title |-
              {{ if eq .Status "firing" }}🔥 FIRING{{ else }}✅ RESOLVED{{ end }}: {{ .CommonLabels.alertname }}
            message: &discord_message |-
              {{ range .Alerts -}}
              {{- if .Annotations.summary }}**{{ .Annotations.summary }}**
              {{ end }}
              {{- if .Annotations.description }}{{ .Annotations.description }}
              {{ end }}
              **Severity:** `{{ .Labels.severity }}`
              {{- with .Labels.namespace }}
              **Namespace:** `{{ . }}`
              {{- end }}
              {{- with .Labels.pod }}
              **Pod:** `{{ . }}`
              {{- end }}
              {{- with .Labels.instance }}
              **Instance:** `{{ . }}`
              {{- end }}

              [🏠 Grafana Home](https://grafana.mtaku3.com){{ if .Labels.pod }} · [📊 Pod Metrics](https://grafana.mtaku3.com/d/k8s_views_pods/kubernetes-views-pods?var-namespace={{ .Labels.namespace | urlquery }}&var-pod={{ .Labels.pod | urlquery }}&from=now-1h&to=now){{ end }}
              {{ end -}}
      - name: discord-warning
        discord_configs:
          - webhook_url_file: /etc/vm/secrets/discord-webhook/webhook-warning
            send_resolved: true
            title: *discord_title
            message: *discord_message
```

- [ ] **Step 2: Render and confirm it builds**

Run:
```bash
kustomize build --enable-helm dev/victoria-metrics > /tmp/vm-render.yaml; echo "exit=$?"
```
Expected: `exit=0`, no Helm/YAML error.

- [ ] **Step 3: Confirm the rendered alertmanager secret contains the templates and parses**

Run:
```bash
# Extract the rendered alertmanager.yaml from the Secret and check YAML validity + content
kustomize build --enable-helm dev/victoria-metrics \
  | yq 'select(.kind=="Secret" and (.stringData."alertmanager.yaml"|. != null)).stringData."alertmanager.yaml"' \
  | tee /tmp/am.yaml | yq '.route.group_by, .receivers[1].discord_configs[0].title' -
```
Expected: prints `- '...'` for `group_by` and the firing/resolved title line — proving the anchor resolved and the Go template survived as a literal string. `yq` parsing it without error confirms YAML validity (backticks/`{{ }}` correctly quoted by `toYaml`).

- [ ] **Step 4: Commit**

```bash
git add dev/victoria-metrics/values-k8s-stack.yaml
git commit -m "feat(alertmanager): readable per-alert Discord embeds with Grafana links

- group_by ['...'] -> one Discord message per alert
- custom title/message templates (shared via anchors)
- pod alerts deep-link to k8s_views_pods, others link Grafana home"
```

---

## Task 2: Deploy and verify behavior

**Files:** none (runtime verification).

- [ ] **Step 1: Push and sync**

```bash
git push
```
Then let ArgoCD auto-sync, or force it:
```bash
argocd app sync victoria-metrics 2>/dev/null || kubectl -n argocd annotate app victoria-metrics argocd.argoproj.io/refresh=hard --overwrite
```
(Adjust app name if different: `kubectl -n argocd get app | grep -i victoria`.)

- [ ] **Step 2: Confirm Alertmanager reloaded without config errors**

```bash
AM_POD=$(kubectl -n victoria-metrics get pod -l app.kubernetes.io/name=vmalertmanager -o name | head -1)
kubectl -n victoria-metrics logs "$AM_POD" -c alertmanager --tail=40 | grep -iE "error|reload|completed loading" | tail
```
Expected: a successful reload / "completed loading of configuration" line, NO parse error referencing `discord_configs`.

- [ ] **Step 3: Inject a test alert through Alertmanager (routes to #warning)**

This posts a real firing alert via the AM v2 API; it auto-resolves after `resolve_timeout`, so it is self-cleaning (no rule changes).

```bash
AM_POD=$(kubectl -n victoria-metrics get pod -l app.kubernetes.io/name=vmalertmanager -o name | head -1)
kubectl -n victoria-metrics port-forward "$AM_POD" 9093:9093 >/tmp/pf.log 2>&1 &
PF=$!; sleep 2
curl -sS -XPOST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {"labels":{"alertname":"DiscordFormatTest","severity":"warning","namespace":"default","pod":"nginx-test","instance":"10.0.0.9:9100"},
   "annotations":{"summary":"Embed format test","description":"Verifying the new Discord layout and Grafana deep-link."}}
]'
echo " -> posted"; kill $PF 2>/dev/null
```
Expected: one message in the #warning channel — red embed, title `🔥 FIRING: DiscordFormatTest`, bold summary, description, `Severity`/`Namespace`/`Pod`/`Instance` fields, and BOTH `🏠 Grafana Home` and `📊 Pod Metrics` links. Click `📊` → opens `k8s_views_pods` filtered to namespace=default, pod=nginx-test.

- [ ] **Step 4: Verify the resolved (green) variant**

Wait for `resolve_timeout` (default 5m) OR post the same payload with `"endsAt"` set to a near-past time to resolve immediately:
```bash
AM_POD=$(kubectl -n victoria-metrics get pod -l app.kubernetes.io/name=vmalertmanager -o name | head -1)
kubectl -n victoria-metrics port-forward "$AM_POD" 9093:9093 >/tmp/pf.log 2>&1 &
PF=$!; sleep 2
curl -sS -XPOST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {"labels":{"alertname":"DiscordFormatTest","severity":"warning","namespace":"default","pod":"nginx-test"},
   "annotations":{"summary":"Embed format test","description":"resolve check"},
   "endsAt":"2000-01-01T00:00:00.000Z"}
]'
kill $PF 2>/dev/null
```
Expected: a green embed titled `✅ RESOLVED: DiscordFormatTest`.

- [ ] **Step 5: Tune whitespace if needed**

If the embed has stray blank lines or cramped fields, adjust the `{{- ... }}` / `{{ ... -}}` trim markers in the `message` template, re-render (Task 1 Step 2), commit, re-sync, re-test Step 3. Alertmanager template whitespace is normally finalized against a live render — one or two iterations is expected, not a defect.

- [ ] **Step 6: Confirm no leftovers**

The test alert is transient (auto-resolves; no VMRule added). Confirm nothing temporary remains:
```bash
git status --porcelain        # only the values change should have been committed; tree clean
```
Expected: clean tree (the spec/plan docs under docs/superpowers/ stay untracked and uncommitted by policy).

---

## Self-Review

- **Spec coverage:** readability (custom title/message — Task 1) ✓; one-message-per-alert (`group_by: ['...']` — Task 1) ✓; URL domain → Grafana home + pods deep-link (Task 1 template) ✓; verification of firing+resolved+links (Task 2) ✓.
- **Placeholders:** none — full YAML block and exact commands provided.
- **Consistency:** anchor names `discord_title`/`discord_message` defined in `discord-critical`, referenced in `discord-warning`; dashboard UID `k8s_views_pods` matches the verified chart value.
- **No-commit policy:** only `values-k8s-stack.yaml` is committed; this plan + the spec stay local (user standing rule).
