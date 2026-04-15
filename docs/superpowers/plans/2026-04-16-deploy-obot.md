# Obot MCP Gateway Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy obot.ai as an MCP gateway/server on bare metal Kubernetes via ArgoCD with Google SSO.

**Architecture:** Single ArgoCD Application pointing at `dev/obot/` containing a Kustomize overlay with two Helm charts (obot + CloudPirates PostgreSQL). Traefik IngressRoute for HTTPS ingress, cert-manager for TLS, SealedSecrets for credentials.

**Tech Stack:** Obot Helm chart v0.19.0, CloudPirates PostgreSQL Helm chart v0.19.0 (OCI), pgvector/pgvector:pg17, Kustomize, ArgoCD, Traefik, cert-manager, SealedSecrets.

**Spec:** `docs/superpowers/specs/2026-04-16-obot-deployment-design.md`

---

### Task 1: Create PostgreSQL SealedSecret

**Files:**
- Create: `dev/obot/postgres-secret.yaml`

- [ ] **Step 1: Generate a random PostgreSQL password and seal it**

Run on a machine with `kubeseal` access to the cluster:

```bash
kubectl create secret generic obot-postgres-auth \
  --namespace obot \
  --from-literal=postgres-password="$(openssl rand -base64 24)" \
  --from-literal=CUSTOM_USER=obot \
  --from-literal=CUSTOM_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=CUSTOM_DB=obot \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --format yaml \
  > dev/obot/postgres-secret.yaml
```

- [ ] **Step 2: Verify the SealedSecret is valid YAML**

```bash
cat dev/obot/postgres-secret.yaml
```

Expected: a `SealedSecret` resource with `metadata.name: obot-postgres-auth`, `metadata.namespace: obot`, and encrypted keys under `spec.encryptedData`.

- [ ] **Step 3: Commit**

```bash
git add dev/obot/postgres-secret.yaml
git commit -m "feat(obot): add PostgreSQL sealed secret"
```

---

### Task 2: Create Obot SealedSecret

**Files:**
- Create: `dev/obot/obot-secret.yaml`

This secret contains all obot config env vars — both secret and non-secret — because the Helm chart's `config.existingSecret` replaces the entire chart-generated config secret.

- [ ] **Step 1: Generate encryption key and bootstrap token, create the secret**

First, note the PostgreSQL password that was generated in Task 1 (you'll need it for the DSN). Since the sealed secret is already encrypted, generate a new password and use it consistently:

```bash
PG_PASSWORD="$(openssl rand -base64 24)"
ENCRYPTION_KEY="$(openssl rand -base64 32)"
BOOTSTRAP_TOKEN="$(openssl rand -base64 32)"

kubectl create secret generic obot-secret \
  --namespace obot \
  --from-literal=OBOT_SERVER_DSN="postgres://obot:${PG_PASSWORD}@obot-postgres:5432/obot" \
  --from-literal=OBOT_SERVER_HOSTNAME="https://obot.mtaku3.com" \
  --from-literal=OBOT_SERVER_ENABLE_AUTHENTICATION="true" \
  --from-literal=OBOT_SERVER_AUTH_OWNER_EMAILS="me@mtaku3.com" \
  --from-literal=OBOT_SERVER_ENCRYPTION_PROVIDER="custom" \
  --from-literal=OBOT_SERVER_ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  --from-literal=OBOT_BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN}" \
  --from-literal=OBOT_SERVER_MCPRUNTIME_BACKEND="kubernetes" \
  --from-literal=NAH_THREADINESS="10000" \
  --from-literal=OBOT_SERVER_KNOWLEDGE_FILE_WORKERS="5" \
  --from-literal=KINM_DB_CONNECTIONS="5" \
  --from-literal=OBOT_SERVER_NANOBOT_INTEGRATION="true" \
  --from-literal=OBOT_SERVER_DISABLE_LEGACY_CHAT="true" \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --format yaml \
  > dev/obot/obot-secret.yaml
```

**IMPORTANT:** The `PG_PASSWORD` used here in the DSN must match the `CUSTOM_PASSWORD` sealed in Task 1's `obot-postgres-auth`. Since SealedSecrets are encrypted and we can't read them back, you need to either:
- Generate both secrets in a single script invocation sharing the same `PG_PASSWORD` variable, OR
- Create Tasks 1 and 2 together using a single script

Recommended: combine into a single script:

```bash
PG_ADMIN_PASSWORD="$(openssl rand -base64 24)"
PG_OBOT_PASSWORD="$(openssl rand -base64 24)"
ENCRYPTION_KEY="$(openssl rand -base64 32)"
BOOTSTRAP_TOKEN="$(openssl rand -base64 32)"

# PostgreSQL secret
kubectl create secret generic obot-postgres-auth \
  --namespace obot \
  --from-literal=postgres-password="${PG_ADMIN_PASSWORD}" \
  --from-literal=CUSTOM_USER=obot \
  --from-literal=CUSTOM_PASSWORD="${PG_OBOT_PASSWORD}" \
  --from-literal=CUSTOM_DB=obot \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --format yaml \
  > dev/obot/postgres-secret.yaml

# Obot secret
kubectl create secret generic obot-secret \
  --namespace obot \
  --from-literal=OBOT_SERVER_DSN="postgres://obot:${PG_OBOT_PASSWORD}@obot-postgres:5432/obot" \
  --from-literal=OBOT_SERVER_HOSTNAME="https://obot.mtaku3.com" \
  --from-literal=OBOT_SERVER_ENABLE_AUTHENTICATION="true" \
  --from-literal=OBOT_SERVER_AUTH_OWNER_EMAILS="me@mtaku3.com" \
  --from-literal=OBOT_SERVER_ENCRYPTION_PROVIDER="custom" \
  --from-literal=OBOT_SERVER_ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  --from-literal=OBOT_BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN}" \
  --from-literal=OBOT_SERVER_MCPRUNTIME_BACKEND="kubernetes" \
  --from-literal=NAH_THREADINESS="10000" \
  --from-literal=OBOT_SERVER_KNOWLEDGE_FILE_WORKERS="5" \
  --from-literal=KINM_DB_CONNECTIONS="5" \
  --from-literal=OBOT_SERVER_NANOBOT_INTEGRATION="true" \
  --from-literal=OBOT_SERVER_DISABLE_LEGACY_CHAT="true" \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --format yaml \
  > dev/obot/obot-secret.yaml

# Print bootstrap token for post-deployment login
echo "BOOTSTRAP_TOKEN: ${BOOTSTRAP_TOKEN}"
echo "Save this token — you will need it for initial admin login."
```

- [ ] **Step 2: Verify both SealedSecrets are valid YAML**

```bash
cat dev/obot/postgres-secret.yaml
cat dev/obot/obot-secret.yaml
```

Expected: two `SealedSecret` resources in namespace `obot`.

- [ ] **Step 3: Commit**

```bash
git add dev/obot/postgres-secret.yaml dev/obot/obot-secret.yaml
git commit -m "feat(obot): add PostgreSQL and obot sealed secrets"
```

---

### Task 3: Create PostgreSQL Helm Values

**Files:**
- Create: `dev/obot/postgres-values.yaml`

- [ ] **Step 1: Create the PostgreSQL values file**

```yaml
# dev/obot/postgres-values.yaml
fullnameOverride: obot-postgres

image:
  registry: docker.io
  repository: pgvector/pgvector
  tag: "pg17"

auth:
  existingSecret: obot-postgres-auth
  secretKeys:
    adminPasswordKey: postgres-password

customUser:
  existingSecret: obot-postgres-auth
  secretKeys:
    name: CUSTOM_USER
    database: CUSTOM_DB
    password: CUSTOM_PASSWORD

persistence:
  enabled: true
  size: 10Gi
```

- [ ] **Step 2: Commit**

```bash
git add dev/obot/postgres-values.yaml
git commit -m "feat(obot): add PostgreSQL helm values"
```

---

### Task 4: Create Obot Helm Values

**Files:**
- Create: `dev/obot/values.yaml`

- [ ] **Step 1: Create the Obot values file**

```yaml
# dev/obot/values.yaml
config:
  existingSecret: "obot-secret"
  OBOT_SERVER_ENCRYPTION_PROVIDER: "custom"
  OBOT_SERVER_MCPRUNTIME_BACKEND: "kubernetes"

ingress:
  enabled: false

persistence:
  enabled: true
  size: 8Gi
```

Note: `OBOT_SERVER_ENCRYPTION_PROVIDER` and `OBOT_SERVER_MCPRUNTIME_BACKEND` must remain in `config:` even with `existingSecret`, because the Helm templates check these values to conditionally render the encryption init container and MCP RBAC resources.

- [ ] **Step 2: Commit**

```bash
git add dev/obot/values.yaml
git commit -m "feat(obot): add obot helm values"
```

---

### Task 5: Create Certificate and IngressRoute

**Files:**
- Create: `dev/obot/certificate.yaml`
- Create: `dev/obot/ingress-route.yaml`

- [ ] **Step 1: Create the cert-manager Certificate**

```yaml
# dev/obot/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: obot
spec:
  secretName: web-tls-cert
  dnsNames:
    - obot.mtaku3.com
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
```

- [ ] **Step 2: Create the Traefik IngressRoute**

```yaml
# dev/obot/ingress-route.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: web
  namespace: obot
  annotations:
    external-dns.alpha.kubernetes.io/target: 202.215.58.76
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`obot.mtaku3.com`)
      kind: Rule
      services:
        - name: obot
          port: 80
  tls:
    secretName: web-tls-cert
```

- [ ] **Step 3: Commit**

```bash
git add dev/obot/certificate.yaml dev/obot/ingress-route.yaml
git commit -m "feat(obot): add certificate and ingress route"
```

---

### Task 6: Create Kustomization

**Files:**
- Create: `dev/obot/kustomization.yaml`

- [ ] **Step 1: Create the kustomization file**

```yaml
# dev/obot/kustomization.yaml
helmCharts:
  - repo: https://charts.obot.ai
    name: obot
    version: "v0.19.0"
    namespace: obot
    releaseName: obot
    valuesFile: values.yaml
  - repo: oci://registry-1.docker.io/cloudpirates
    name: postgres
    version: "0.19.0"
    namespace: obot
    releaseName: obot-postgres
    valuesFile: postgres-values.yaml

resources:
  - certificate.yaml
  - ingress-route.yaml
  - postgres-secret.yaml
  - obot-secret.yaml
```

- [ ] **Step 2: Verify kustomize build works**

```bash
cd dev/obot && kustomize build --enable-helm 2>&1 | head -20
```

Expected: valid YAML output starting with Kubernetes resources. No errors.

- [ ] **Step 3: Verify with the repo build script**

```bash
./scripts/build.sh dev/obot obot 2>&1 | head -20
```

Expected: valid YAML output with `metadata.namespace` set to `obot` on all resources.

- [ ] **Step 4: Commit**

```bash
git add dev/obot/kustomization.yaml
git commit -m "feat(obot): add kustomization with obot and postgres helm charts"
```

---

### Task 7: Create ArgoCD Application

**Files:**
- Create: `dev/argocd/applications/obot.yaml`

- [ ] **Step 1: Create the ArgoCD Application**

```yaml
# dev/argocd/applications/obot.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: obot
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mtaku3/homelab-manifest.git
    targetRevision: HEAD
    path: dev/obot
    plugin:
      name: homelab-manifest-build
  destination:
    server: https://kubernetes.default.svc
    namespace: obot
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ForceConflicts=true
```

- [ ] **Step 2: Commit**

```bash
git add dev/argocd/applications/obot.yaml
git commit -m "feat(obot): add ArgoCD application"
```

---

### Task 8: Push Branch and Create PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/deploy-obot
```

- [ ] **Step 2: Create the pull request**

```bash
gh pr create --title "feat: deploy obot MCP gateway" --body "$(cat <<'EOF'
## Summary
- Deploy obot.ai as MCP gateway/server via ArgoCD
- PostgreSQL 17 with pgvector (CloudPirates Helm chart)
- Traefik IngressRoute at obot.mtaku3.com
- Authentication enabled with Google SSO (configured post-deploy via admin UI)
- SealedSecrets for PostgreSQL credentials, encryption key, and bootstrap token

## Post-deployment steps
- [ ] Log in at https://obot.mtaku3.com with bootstrap token
- [ ] Configure Google SSO via Admin > User Management > Auth Providers > Google
- [ ] Verify MCP gateway functionality
EOF
)"
```

- [ ] **Step 3: Verify PR was created**

Expected: PR URL returned by `gh pr create`.
