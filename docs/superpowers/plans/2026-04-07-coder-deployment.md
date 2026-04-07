# Coder Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Coder to the homelab cluster as an ArgoCD-managed app under `dev/coder/`, backed by an in-cluster CloudPirates Postgres, exposed at `coder.mtaku3.com` with wildcard workspace-app support at `*.coder.mtaku3.com`.

**Architecture:** A single `dev/coder/` directory containing a kustomization that pulls two helm charts (`coder` from `https://helm.coder.com/v2`, `postgres` from CloudPirates) plus inline cert-manager Certificate, Traefik IngressRoutes, and SealedSecrets. ArgoCD's existing `homelab-apps` ApplicationSet picks the directory up automatically.

**Tech Stack:** Kustomize (`helmCharts:`), Helm (Coder 2.29.5, CloudPirates Postgres 0.18.3), cert-manager (DNS-01 via Cloudflare), Traefik IngressRoute, Bitnami SealedSecrets, ArgoCD.

**Spec:** `docs/superpowers/specs/2026-04-07-coder-deployment-design.md`

**Branch:** `feat/coder-deployment` (already created)

---

## Background for the implementer

A few non-obvious things about this repo you should know before starting:

- **ArgoCD auto-discovers `dev/*` directories** via `dev/argocd/application-set.yaml`. You do NOT need to write an `Application` resource for Coder. Just creating `dev/coder/` with a valid `kustomization.yaml` is enough — ArgoCD generates the app automatically and the destination namespace is the directory basename (`coder`).
- **Build verification command:** `scripts/build.sh dev/coder` runs `kustomize build dev/coder --enable-helm` and stamps a default namespace. Use this throughout the plan to verify each step renders.
- **SealedSecrets workflow:** Write a plain `Secret` YAML to a file, then run `scripts/s2ss.sh <file>` which calls `kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets` and rewrites the file in-place as a `SealedSecret`. The script requires `kubeseal` to be installed and a kube-context that can reach the cluster's sealed-secrets controller.
- **IMPORTANT — never commit a plain Secret.** Always run `s2ss.sh` before `git add`. If you cannot reach the cluster to seal, STOP and ask the user.
- **IMPORTANT — never read existing secret values from the cluster.** When generating new passwords, generate them locally with `openssl rand` or similar, do not `kubectl get secret -o yaml` an existing one.
- **Pattern to follow:** `dev/open-webui/` is the closest analogue (single helm chart + Traefik IngressRoute + cert). `dev/mt4jm/` is the closest analogue for SealedSecret usage.
- **No `git push` and no PR** until the user explicitly asks. Commit locally on `feat/coder-deployment`.
- **Don't `kubectl apply` anything.** ArgoCD auto-syncs from the branch once merged. Validation in this plan is local-only (`scripts/build.sh`, `kubeseal`).

---

## File Structure

All new files live under `dev/coder/`:

| File | Responsibility |
|---|---|
| `dev/coder/kustomization.yaml` | Declare two `helmCharts` entries + list inline resources |
| `dev/coder/values.yaml` | Coder helm values (env vars, ingress disabled, service type) |
| `dev/coder/postgres-values.yaml` | CloudPirates Postgres helm values (auth, persistence) |
| `dev/coder/certificate.yaml` | cert-manager `Certificate` for `coder.mtaku3.com` + wildcard |
| `dev/coder/ingress-route.yaml` | Two Traefik `IngressRoute`s (Host + HostRegexp), shared TLS secret |
| `dev/coder/postgres-secret.yaml` | SealedSecret `coder-postgres-auth` containing `POSTGRES_PASSWORD` |
| `dev/coder/db-url-secret.yaml` | SealedSecret `coder-db-url` containing `url` (full DSN for Coder) |

Plus one updated file:

| File | Change |
|---|---|
| `docs/superpowers/plans/2026-04-07-coder-deployment.md` | This plan (already saved) |

---

## Task 1: Scaffold the directory and verify the helm chart sources resolve

**Files:**
- Create: `dev/coder/kustomization.yaml`
- Create: `dev/coder/values.yaml` (empty placeholder, will be filled in Task 4)
- Create: `dev/coder/postgres-values.yaml` (empty placeholder, will be filled in Task 5)

This task exists to fail fast on chart-source issues (wrong repo URL, wrong chart name, OCI-only chart) before writing any other YAML.

- [ ] **Step 1: Create empty values files**

```bash
mkdir -p dev/coder
: > dev/coder/values.yaml
: > dev/coder/postgres-values.yaml
```

- [ ] **Step 2: Write the initial kustomization.yaml**

`dev/coder/kustomization.yaml`:

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

resources: []
```

- [ ] **Step 3: Render with `scripts/build.sh` to verify both charts resolve**

Run: `scripts/build.sh dev/coder | head -50`

Expected: YAML output showing the start of rendered Coder + Postgres manifests (you'll see things like `kind: ServiceAccount`, `kind: Deployment`, etc.). No errors about "chart not found", "no such repository", or "401 Unauthorized".

**If this fails:**
- If the CloudPirates HTTP repo URL is wrong, try the OCI form: replace its `repo:` line with `repo: oci://ghcr.io/cloudpirates-io/helm-charts` and re-run. (Kustomize supports OCI repos in `helmCharts:` since 5.x.)
- If both fail, STOP and ask the user. Do not invent a URL.

- [ ] **Step 4: Confirm the rendered Postgres service name**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "Service" and (.metadata.name | test("postgres"))) | .metadata.name'`

Expected: A single service name. **Write it down — you need it in Task 6 for the DB URL.** It will likely be `coder-postgres` (matches releaseName) but could be `coder-postgres-postgres` depending on the chart's `fullnameOverride` defaults.

- [ ] **Step 5: Confirm the rendered Coder service port name**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "Service" and .metadata.name == "coder") | .spec.ports'`

Expected: A list of ports. **Write down the `name` of the HTTP port (likely `http` or unnamed at port 80).** You need it in Task 8 for the IngressRoute.

- [ ] **Step 6: Commit**

```bash
git add dev/coder/kustomization.yaml dev/coder/values.yaml dev/coder/postgres-values.yaml
git commit -m "feat(coder): scaffold helmCharts kustomization

Pull Coder 2.29.5 and CloudPirates Postgres 0.18.3 charts.
Values files are empty placeholders for now."
```

---

## Task 2: Generate the Postgres password locally

**Files:** none (this task only generates a value held in your shell history)

This password is used twice: in the `coder-postgres-auth` SealedSecret (Task 3) and embedded in the `coder-db-url` SealedSecret (Task 6). Generate it once and keep it in a shell variable for both tasks. Do **not** write it to any committed file.

- [ ] **Step 1: Generate a password and stash it**

Run: `export CODER_PG_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)`

Then verify it's set: `echo "len=${#CODER_PG_PW}"`

Expected: `len=32` (or similar — just confirm it's non-empty).

- [ ] **Step 2: Verify kubeseal works against the cluster**

Run: `echo -n test | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --raw --scope cluster-wide --from-file=/dev/stdin`

Expected: A long base64 blob starting with `Ag...`. If this errors with "no such host" or "unable to fetch certificate", STOP — your kube-context cannot reach the sealed-secrets controller.

(No commit — this task produces only shell state.)

---

## Task 3: Create the Postgres password SealedSecret

**Files:**
- Create: `dev/coder/postgres-secret.yaml`

- [ ] **Step 1: Write a plain Secret YAML**

```bash
cat > dev/coder/postgres-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: coder-postgres-auth
  namespace: coder
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${CODER_PG_PW}"
EOF
```

- [ ] **Step 2: Seal it in place**

Run: `scripts/s2ss.sh dev/coder/postgres-secret.yaml`

Expected output: `Sealing Secret in dev/coder/postgres-secret.yaml` followed by `✅ Successfully sealed dev/coder/postgres-secret.yaml`.

- [ ] **Step 3: Verify the file is now a SealedSecret, not a Secret**

Run: `head -20 dev/coder/postgres-secret.yaml`

Expected: `kind: SealedSecret`, `apiVersion: bitnami.com/v1alpha1`, and `encryptedData.POSTGRES_PASSWORD` containing a long base64 blob. If you still see `kind: Secret` or `stringData:`, STOP — sealing failed silently.

- [ ] **Step 4: Commit**

```bash
git add dev/coder/postgres-secret.yaml
git commit -m "feat(coder): add SealedSecret for Postgres password"
```

---

## Task 4: Fill in Coder helm values

**Files:**
- Modify: `dev/coder/values.yaml`

- [ ] **Step 1: Write values.yaml**

Replace the empty `dev/coder/values.yaml` with:

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

- [ ] **Step 2: Render and verify the env vars made it through**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "Deployment" and .metadata.name == "coder") | .spec.template.spec.containers[0].env'`

Expected: A list including `CODER_PG_CONNECTION_URL` (with `valueFrom.secretKeyRef.name: coder-db-url`), `CODER_ACCESS_URL`, and `CODER_WILDCARD_ACCESS_URL`. If any are missing, the chart's value path is different — check `helm show values coder-v2/coder --version 2.29.5` or the chart's README and adjust.

- [ ] **Step 3: Verify the service type and that ingress was NOT rendered**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "Service" and .metadata.name == "coder") | .spec.type'`

Expected: `ClusterIP`

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "Ingress")' | head`

Expected: empty output (no Ingress resources).

- [ ] **Step 4: Commit**

```bash
git add dev/coder/values.yaml
git commit -m "feat(coder): configure Coder access URL and DB connection env"
```

---

## Task 5: Fill in Postgres helm values

**Files:**
- Modify: `dev/coder/postgres-values.yaml`

- [ ] **Step 1: Write postgres-values.yaml**

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

- [ ] **Step 2: Render and verify the Postgres StatefulSet/Deployment references the SealedSecret**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "StatefulSet" or .kind == "Deployment") | select(.metadata.name | test("postgres")) | .spec.template.spec.containers[0].env'`

Expected: An env entry resolving the password from `secretKeyRef.name: coder-postgres-auth`, `key: POSTGRES_PASSWORD`. If you see the password being set inline or pointing at a different secret name, the chart's `existingSecret` plumbing isn't kicking in — check the chart's `values.yaml` for the correct path.

- [ ] **Step 3: Verify persistence size**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "PersistentVolumeClaim" or (.kind == "StatefulSet" and (.metadata.name | test("postgres")))) | .spec.volumeClaimTemplates[0].spec.resources.requests.storage // .spec.resources.requests.storage'`

Expected: `10Gi` somewhere in the output.

- [ ] **Step 4: Commit**

```bash
git add dev/coder/postgres-values.yaml
git commit -m "feat(coder): configure Postgres auth and 10Gi persistence"
```

---

## Task 6: Create the Coder DB URL SealedSecret

**Files:**
- Create: `dev/coder/db-url-secret.yaml`

This embeds the password generated in Task 2. The hostname is the Postgres service name you wrote down in Task 1, Step 4.

- [ ] **Step 1: Write the plain Secret YAML**

Substitute `<PG_SVC>` with the service name from Task 1, Step 4 (most likely `coder-postgres`):

```bash
PG_SVC="coder-postgres"  # CHANGE if Task 1 step 4 showed a different name
cat > dev/coder/db-url-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: coder-db-url
  namespace: coder
type: Opaque
stringData:
  url: "postgres://coder:${CODER_PG_PW}@${PG_SVC}:5432/coder?sslmode=disable"
EOF
```

- [ ] **Step 2: Seal it in place**

Run: `scripts/s2ss.sh dev/coder/db-url-secret.yaml`

Expected: `✅ Successfully sealed dev/coder/db-url-secret.yaml`.

- [ ] **Step 3: Verify it became a SealedSecret**

Run: `head -20 dev/coder/db-url-secret.yaml`

Expected: `kind: SealedSecret`, `encryptedData.url` with a base64 blob. If you see `kind: Secret` or `stringData:`, STOP — sealing failed.

- [ ] **Step 4: Commit**

```bash
git add dev/coder/db-url-secret.yaml
git commit -m "feat(coder): add SealedSecret with Postgres connection URL"
```

---

## Task 7: Add the cert-manager Certificate

**Files:**
- Create: `dev/coder/certificate.yaml`

- [ ] **Step 1: Write certificate.yaml**

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

- [ ] **Step 2: Commit (no kustomization wiring yet — that's Task 9)**

```bash
git add dev/coder/certificate.yaml
git commit -m "feat(coder): add wildcard TLS certificate"
```

---

## Task 8: Add the Traefik IngressRoutes

**Files:**
- Create: `dev/coder/ingress-route.yaml`

- [ ] **Step 1: Write ingress-route.yaml**

Substitute `<CODER_PORT>` with the port name from Task 1, Step 5. If the port had a `name`, use that string. If it was unnamed, use the integer `80`.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: web
  namespace: coder
  annotations:
    external-dns.alpha.kubernetes.io/target: 202.215.58.76
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`coder.mtaku3.com`)
      kind: Rule
      services:
        - name: coder
          port: <CODER_PORT>
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
  entryPoints:
    - websecure
  routes:
    - match: HostRegexp(`{subdomain:[a-z0-9-]+}.coder.mtaku3.com`)
      kind: Rule
      services:
        - name: coder
          port: <CODER_PORT>
  tls:
    secretName: coder-tls-cert
```

- [ ] **Step 2: Commit**

```bash
git add dev/coder/ingress-route.yaml
git commit -m "feat(coder): add Traefik IngressRoutes for host and wildcard"
```

---

## Task 9: Wire all inline resources into kustomization.yaml

**Files:**
- Modify: `dev/coder/kustomization.yaml`

- [ ] **Step 1: Replace `resources: []` with the full list**

Edit `dev/coder/kustomization.yaml` so the `resources:` block becomes:

```yaml
resources:
  - certificate.yaml
  - ingress-route.yaml
  - postgres-secret.yaml
  - db-url-secret.yaml
```

(Leave the `helmCharts:` block above unchanged.)

- [ ] **Step 2: Render the whole thing and verify all expected kinds appear**

Run: `scripts/build.sh dev/coder | yq '[.kind] | unique'`

Expected: a list including at least `Certificate`, `IngressRoute`, `SealedSecret`, `Service`, `Deployment` (or `StatefulSet`), `ServiceAccount`, `ConfigMap`. If any of `Certificate`, `IngressRoute`, or `SealedSecret` is missing, the resources list isn't being picked up.

- [ ] **Step 3: Verify the two SealedSecrets are present by name**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "SealedSecret") | .metadata.name'`

Expected: two lines — `coder-postgres-auth` and `coder-db-url`.

- [ ] **Step 4: Verify the IngressRoutes both reference the same TLS secret**

Run: `scripts/build.sh dev/coder | yq 'select(.kind == "IngressRoute") | {name: .metadata.name, host: .spec.routes[0].match, tls: .spec.tls.secretName}'`

Expected: two entries, both with `tls: coder-tls-cert`, one matching `Host(...)` and one matching `HostRegexp(...)`.

- [ ] **Step 5: Verify the namespace stamping works**

Run: `scripts/build.sh dev/coder | yq '.metadata.namespace' | sort -u`

Expected: only `coder` (and possibly `null` for cluster-scoped resources like ClusterRoles, which is fine — the build script only fills in missing namespaces).

- [ ] **Step 6: Commit**

```bash
git add dev/coder/kustomization.yaml
git commit -m "feat(coder): wire cert, ingress, and secrets into kustomization"
```

---

## Task 10: Final end-to-end render check

**Files:** none

A fresh-eyes pass on the rendered output before handing off to the user.

- [ ] **Step 1: Render the full output to a temp file**

Run: `scripts/build.sh dev/coder > /tmp/coder-rendered.yaml && wc -l /tmp/coder-rendered.yaml`

Expected: A non-trivial line count (likely several thousand lines).

- [ ] **Step 2: Grep for any leaked plain `kind: Secret`**

Run: `yq 'select(.kind == "Secret")' /tmp/coder-rendered.yaml`

Expected: empty output. (Coder's helm chart may render its own internal Secrets — if those appear and contain harmless things like generated tokens, that's fine. What you're checking for is any of OUR files that should have been sealed but weren't.)

If any Secret appears with metadata name `coder-postgres-auth` or `coder-db-url`, STOP — one of the SealedSecret files reverted to plain. Re-seal it.

- [ ] **Step 3: Confirm the two env vars Coder needs**

Run: `yq 'select(.kind == "Deployment" and .metadata.name == "coder") | .spec.template.spec.containers[0].env[] | select(.name | test("CODER_(PG_CONNECTION_URL|ACCESS_URL|WILDCARD_ACCESS_URL)"))' /tmp/coder-rendered.yaml`

Expected: three entries — `CODER_PG_CONNECTION_URL` (with `secretKeyRef`), `CODER_ACCESS_URL` (literal), `CODER_WILDCARD_ACCESS_URL` (literal).

- [ ] **Step 4: Print a final summary for the user**

Show the user:
- The output of `git log --oneline main..feat/coder-deployment`
- The output of `ls dev/coder/`
- A note that nothing has been pushed and ArgoCD will not see this until the branch is merged

- [ ] **Step 5: Stop and wait for user instruction**

Do NOT push, do NOT open a PR, do NOT `kubectl apply`. Tell the user the branch is ready for review and ask whether they want a PR opened.

---

## Self-review notes

- **Spec coverage:** All seven files in the spec's Components table are produced (Tasks 1, 3, 4, 5, 6, 7, 8, 9). Wildcard cert + dual IngressRoute (Task 7, 8). DB URL secret with embedded password (Task 6). Postgres `existingSecret` wiring (Task 5). Coder env vars (Task 4). YAGNI items (OIDC, backups) intentionally absent.
- **Two flagged unknowns from the spec** (Postgres service name, Coder service port name) are resolved at the earliest possible moment (Task 1 steps 4–5) and the values are then referenced explicitly in Tasks 6 and 8.
- **Secret hygiene:** Password is generated locally (Task 2), held only in a shell variable, used in Tasks 3 and 6, and never written to a committed file in plaintext. Both files are sealed before commit.
- **No `kubectl apply` anywhere.** Validation is local-only via `scripts/build.sh`.
