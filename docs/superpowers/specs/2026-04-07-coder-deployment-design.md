# Coder Deployment Design

## Goal

Deploy [Coder](https://coder.com/docs/install/kubernetes) (self-hosted cloud
development environments) to the homelab cluster, managed by ArgoCD, with an
in-cluster PostgreSQL backend provisioned via the
[CloudPirates Postgres helm chart](https://artifacthub.io/packages/helm/cloudpirates-postgres/postgres).
Expose Coder at `coder.mtaku3.com` with wildcard workspace-app support at
`*.coder.mtaku3.com`.

## Architecture

A new ArgoCD application under `dev/coder/`, following the same kustomize +
`helmCharts` pattern used by `dev/open-webui/`. The kustomization declares two
helm charts (Coder server and CloudPirates Postgres) and inline resources for
TLS, ingress, and secrets. Coder connects to Postgres via the cluster-internal
service. Traefik IngressRoutes (one `Host`, one `HostRegexp`) front Coder, with
a single wildcard cert from cert-manager covering both names.

```
                  +-------------------+
   internet ----> |     Traefik       |
                  +---------+---------+
                            |
              +-------------+-------------+
              |                           |
   Host(coder.mtaku3.com)     HostRegexp(*.coder.mtaku3.com)
              |                           |
              +-------------+-------------+
                            |
                       +----v-----+
                       |  coder   |  (Service: ClusterIP)
                       +----+-----+
                            |
                       +----v-----+
                       | postgres |  (Service: ClusterIP, PVC 10Gi)
                       +----------+
```

## Components

| Path                              | Purpose                                                       |
|-----------------------------------|---------------------------------------------------------------|
| `dev/coder/kustomization.yaml`    | Declares Coder + Postgres helm charts and inline resources    |
| `dev/coder/values.yaml`           | Coder helm values                                             |
| `dev/coder/postgres-values.yaml`  | CloudPirates Postgres helm values                             |
| `dev/coder/certificate.yaml`      | cert-manager `Certificate` for `coder.mtaku3.com` + wildcard  |
| `dev/coder/ingress-route.yaml`    | Two Traefik `IngressRoute`s (main host + wildcard)            |
| `dev/coder/postgres-secret.yaml`  | SealedSecret with `POSTGRES_PASSWORD`                         |
| `dev/coder/db-url-secret.yaml`    | SealedSecret with full Coder DB URL (`url` key)               |

ArgoCD picks this directory up automatically via the existing
`homelab-apps` ApplicationSet (`dev/argocd/application-set.yaml`), which
generates one Application per `dev/*` directory. The destination namespace is
the directory basename (`coder`).

## Helm chart sourcing

Following the open-webui pattern (helm repo URL declared in
`kustomization.yaml`):

```yaml
helmCharts:
  - repo: https://helm.coder.com/v2
    name: coder
    version: "2.29.5"
    namespace: coder
    releaseName: coder
    valuesFile: values.yaml
  - repo: https://cloudpirates-io.github.io/helm-charts
    name: postgres
    version: "0.18.3"
    namespace: coder
    releaseName: coder-postgres
    valuesFile: postgres-values.yaml
```

If the CloudPirates chart turns out to be OCI-only at implementation time, we
will switch the second entry to its OCI form
(`oci://ghcr.io/cloudpirates-io/helm-charts/postgres`). Both versions are
pinned and renovate-friendly.

## Coder values (`values.yaml`)

```yaml
coder:
  env:
    - name: CODER_PG_CONNECTION_URL
      valueFrom:
        secretKeyRef:
          name: coder-db-url
          key: url
    - name: CODER_ACCESS_URL
      value: "https://coder.mtaku3.com"
    - name: CODER_WILDCARD_ACCESS_URL
      value: "*.coder.mtaku3.com"
  service:
    type: ClusterIP
  ingress:
    enabled: false
```

Workspace pods use cluster defaults (piraeus storage class, no node selector).

## Postgres values (`postgres-values.yaml`)

```yaml
auth:
  username: coder
  database: coder
  existingSecret: coder-postgres-auth
  secretKeys:
    adminPasswordKey: POSTGRES_PASSWORD
persistence:
  size: 10Gi
```

## Secrets

Both secrets are created locally with `kubeseal` and committed as
SealedSecrets.

**`coder-postgres-auth`** — consumed by the Postgres chart via
`auth.existingSecret`:

```
POSTGRES_PASSWORD: <random>
```

**`coder-db-url`** — consumed by Coder via `CODER_PG_CONNECTION_URL`. The
`url` value embeds the same password and points at the Postgres service:

```
url: postgres://coder:<password>@coder-postgres:5432/coder?sslmode=disable
```

The exact Postgres service name is confirmed during implementation by
inspecting the rendered chart (default is `<releaseName>-postgres` or
`<releaseName>` depending on the chart's templates). The DB URL secret is
generated *after* that confirmation.

## Networking

### Certificate (`certificate.yaml`)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: coder-tls
  namespace: coder
spec:
  secretName: coder-tls-cert
  dnsNames:
    - coder.mtaku3.com
    - "*.coder.mtaku3.com"
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
```

The existing `letsencrypt` ClusterIssuer uses DNS-01 via Cloudflare, so
wildcard issuance works without changes.

### IngressRoutes (`ingress-route.yaml`)

Two routes share the same TLS secret. The main route follows the open-webui
template; the wildcard route uses Traefik's `HostRegexp` matcher and an
`external-dns` hostname annotation (because `HostRegexp` doesn't expose a
clean hostname for external-dns to discover automatically).

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: web
  namespace: coder
  annotations:
    external-dns.alpha.kubernetes.io/target: 202.215.58.76
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`coder.mtaku3.com`)
      kind: Rule
      services:
        - name: coder
          port: 80
  tls:
    secretName: coder-tls-cert
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: web-wildcard
  namespace: coder
  annotations:
    external-dns.alpha.kubernetes.io/target: 202.215.58.76
    external-dns.alpha.kubernetes.io/hostname: "*.coder.mtaku3.com"
spec:
  entryPoints: [websecure]
  routes:
    - match: HostRegexp(`{subdomain:[a-z0-9-]+}.coder.mtaku3.com`)
      kind: Rule
      services:
        - name: coder
          port: 80
  tls:
    secretName: coder-tls-cert
```

The Coder service port name (`80` vs `http`) will be confirmed against the
rendered chart during implementation.

## Data flow

1. User hits `https://coder.mtaku3.com` → Cloudflare → home WAN IP
   (`202.215.58.76`) → Traefik → `coder` service.
2. Workspace web app at e.g. `https://app--ws--user.coder.mtaku3.com`
   → wildcard DNS → same IP → Traefik HostRegexp route → `coder` service →
   Coder proxies to the workspace agent.
3. Coder pod reads `CODER_PG_CONNECTION_URL` from `coder-db-url` secret on
   startup, connects to `coder-postgres:5432` inside the namespace.

## Error / failure considerations

- **Postgres unavailable on first boot:** Coder retries DB connection on
  startup; ArgoCD will retry the Sync. No action needed.
- **Wildcard cert issuance fails:** The DNS-01 challenge runs against
  Cloudflare; failure is observable via `Certificate` status. The main host
  cert and wildcard cert share one Certificate resource — if the wildcard
  fails, the main host is also blocked. If this proves fragile we'll split
  into two Certificate resources.
- **Coder helm upgrade introduces breaking change:** Versions are pinned;
  Renovate proposes upgrades as PRs.

## Testing

After merge and ArgoCD sync:

1. `kubectl -n coder get pods` — Coder + Postgres healthy.
2. `kubectl -n coder get certificate` — `Ready=True` for `coder-tls`.
3. `curl -I https://coder.mtaku3.com` — 200/302 from Coder.
4. `curl -I https://anything.coder.mtaku3.com` — reaches Coder (200/404
   depending on Coder's wildcard handling without an active workspace app).
5. Create the initial Coder owner via the web UI.

## Out of scope (YAGNI)

- **OIDC / Google SSO** — Coder's built-in auth is sufficient for initial
  rollout. Can be added later mirroring open-webui's `google-sso-secret.yaml`.
- **Backups** — No backup strategy exists for other stateful apps in this
  repo.
- **Workspace templates** — Created in-app post-deploy, not part of the
  manifest repo.
- **Resource tuning** — Use chart defaults; revisit if usage demands.
