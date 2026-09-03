# Discord Alert Readability + Deep-Link Design

Date: 2026-06-12
Status: Implemented (PR #81, commit c18fa27)
Scope: `dev/victoria-metrics/values-k8s-stack.yaml` (alertmanager block only)

## Problem

Alertmanager routes critical/warning alerts to Discord via the native
`discord_configs` receiver, but with no custom `title`/`message`. The default
template produces a hard-to-read dump. Two issues raised by the user:

1. **Readability** — alert embeds are dense and hard to parse.
2. **URL domain not set** — links in the message point to an internal/unset
   address instead of a reachable domain.
3. **Receive alerts separately** — clarified to mean *one Discord message per
   alert* (currently Alertmanager bundles alerts by `alertname`+`namespace`
   into a single embed).

## Decisions

- **Approach A (inline templates).** Customize `title` + `message` directly on
  each discord receiver. No named-template configmap (Approach B) and no
  alertmanager→discord bridge sidecar (Approach C) — both add moving parts not
  justified for two receivers.
- **Link target = Grafana** (`grafana.mtaku3.com`), the only observability UI
  already exposed via ingress. Alertmanager and vmalert are **not** exposed and
  will **not** be exposed (no silence/source links needed since the custom
  template renders its own links). No `external_url` configured.
- **Ungroup** via `group_by: ['...']` on the top route → each firing alert posts
  its own message. Inherited by the `critical` and `warning` subroutes.

## Out of scope (YAGNI)

- New ingress / certificate / Google SSO for Alertmanager.
- Extra catch-all Discord channel (severity-split channels kept as-is).
- Timestamp timezone conversion (Discord shows the message timestamp natively).
- Grafana Explore deep-link with the alert's exact query (the PromQL `expr` is
  not present in `.Labels`; the encoded-JSON Explore URL is fragile).

## Embed design

Alertmanager auto-colors the embed: firing = red, resolved = green. Built-in,
no config needed.

**Title**

```
{{ if eq .Status "firing" }}🔥 FIRING{{ else }}✅ RESOLVED{{ end }}: {{ .CommonLabels.alertname }}
```

With `group_by: ['...']` each group holds a single alert, so `.CommonLabels`
resolves to that alert's labels.

**Message** (conceptual — exact Go-template whitespace trimming finalized in
implementation)

```
{{ range .Alerts -}}
{{ with .Annotations.summary }}**{{ . }}**{{ end }}
{{ with .Annotations.description }}{{ . }}{{ end }}

**Severity:** `{{ .Labels.severity }}`
{{ with .Labels.namespace }}**Namespace:** `{{ . }}`{{ end }}
{{ with .Labels.pod }}**Pod:** `{{ . }}`{{ end }}
{{ with .Labels.instance }}**Instance:** `{{ . }}`{{ end }}

[🏠 Grafana Home](https://grafana.mtaku3.com){{ if .Labels.pod }} · [📊 Pod Metrics](https://grafana.mtaku3.com/d/k8s_views_pods/kubernetes-views-pods?var-namespace={{ .Labels.namespace | urlquery }}&var-pod={{ .Labels.pod | urlquery }}&from=now-1h&to=now){{ end }}
{{ end -}}
```

Field rules:
- Each label field rendered only when the label is present (`with`).
- `🏠 Grafana Home` link always shown.
- `📊 Pod Metrics` deep-link shown only when the alert carries a `pod` label;
  links to the bundled `k8s_views_pods` dashboard filtered by `namespace`+`pod`,
  time range `now-1h`..`now`. `urlquery` encodes label values safely.

Same `title`/`message` applied to both `discord-critical` and `discord-warning`
receivers.

## Resulting alertmanager config shape

```yaml
alertmanager:
  spec:
    secrets:
      - discord-webhook
  config:
    route:
      receiver: blackhole
      group_by: ['...']          # was [alertname, namespace] -> one msg per alert
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
            title: '<title template>'
            message: '<message template>'
      - name: discord-warning
        discord_configs:
          - webhook_url_file: /etc/vm/secrets/discord-webhook/webhook-warning
            send_resolved: true
            title: '<title template>'
            message: '<message template>'
```

## Verification

- `kubectl -n victoria-metrics get vmalertmanager -o yaml` reflects the new
  config; alertmanager pod reloads without config errors
  (`amtool check-config` semantics — watch pod logs for parse errors).
- Trigger/observe a firing pod alert → single Discord message, readable embed,
  working `🏠`/`📊` links.
- Confirm a non-pod alert (e.g., node/control-plane) shows only the home link.
- Confirm resolved notification renders green `✅ RESOLVED`.

## Notes / risks

- `discord_configs` `title`/`message` require Alertmanager ≥0.25 (bundled in
  vm-k8s-stack 0.63.1 — satisfied).
- `k8s_views_pods` UID confirmed from
  `charts/.../files/dashboards/generated/kubernetes-views-pods.yaml`
  (`uid: k8s_views_pods`, template vars include `namespace`, `pod`). If the chart
  is upgraded, re-confirm the UID.
