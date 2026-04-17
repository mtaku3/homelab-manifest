# CloudCLI Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy CloudCLI (web UI for Claude Code) at `cloudcli.mtaku3.com` with tinyauth behind Traefik, using a custom Docker image built in a new public GitHub repo.

**Architecture:** A new public GitHub repo `mtaku3/cloudcli-image` holds the Dockerfile and GitHub Actions CI that builds and pushes `ghcr.io/mtaku3/cloudcli` on every push to `main`. The homelab-manifest gains a `dev/cloudcli/` namespace with raw Kubernetes manifests deployed by ArgoCD with tinyauth protecting the ingress.

**Tech Stack:** Node.js 22, `@cloudcli-ai/cloudcli`, `@anthropic-ai/claude-code`, GitHub Actions, ghcr.io, Kubernetes, Traefik IngressRoute, cert-manager, tinyauth ForwardAuth

---

## File Map

### New repo: `mtaku3/cloudcli-image`
| File | Purpose |
|---|---|
| `Dockerfile` | Builds the CloudCLI image from `node:22-slim` |
| `.github/workflows/build.yml` | CI: builds and pushes `ghcr.io/mtaku3/cloudcli` on push to `main` |

### New files in `homelab-manifest`
| File | Purpose |
|---|---|
| `dev/cloudcli/kustomization.yaml` | Kustomize root for the namespace |
| `dev/cloudcli/deployment.yaml` | CloudCLI Deployment, UID 1000, PVC at `/home/cloudcli` |
| `dev/cloudcli/service.yaml` | ClusterIP service, port 80 → 3001 |
| `dev/cloudcli/pvc.yaml` | 20Gi PVC for sessions and repo data |
| `dev/cloudcli/certificate.yaml` | cert-manager Certificate for `cloudcli.mtaku3.com` |
| `dev/cloudcli/ingress-route.yaml` | Traefik IngressRoute with tinyauth middleware |
| `dev/argocd/applications/cloudcli.yaml` | ArgoCD Application pointing at `dev/cloudcli` |

### Modified files in `homelab-manifest`
| File | Change |
|---|---|
| `dev/argocd/applications/kustomization.yaml` | Add `cloudcli.yaml` to resources list |

---

## Task 1: Create GitHub repo and Dockerfile

**Pre-requisite (manual):** Create a new **public** GitHub repository named `cloudcli-image` under `mtaku3`. Initialize it with no files (empty repo).

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Clone the new empty repo locally**

```bash
git clone https://github.com/mtaku3/cloudcli-image.git
cd cloudcli-image
```

- [ ] **Step 2: Write `Dockerfile`**

```dockerfile
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3 \
    python3-setuptools \
    ripgrep \
    sqlite3 \
    zip \
    unzip \
    jq \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @cloudcli-ai/cloudcli @anthropic-ai/claude-code

RUN usermod -l cloudcli -d /home/cloudcli -m --shell /bin/bash node && groupmod -n cloudcli node

WORKDIR /home/cloudcli

USER cloudcli

EXPOSE 3001

CMD ["cloudcli", "start", "--port", "3001"]
```

- [ ] **Step 3: Build the image locally to verify it succeeds**

```bash
docker build -t cloudcli-test .
```

Expected: build completes with no errors, final layer shows `cloudcli` user.

- [ ] **Step 4: Verify the container starts and port 3001 responds**

```bash
docker run -d --name cloudcli-test -p 3001:3001 cloudcli-test
sleep 5
curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/
docker rm -f cloudcli-test
```

Expected: HTTP status `200` (or `302` redirect — any non-connection-refused response confirms the server started).

- [ ] **Step 5: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile for CloudCLI image"
```

---

## Task 2: Add GitHub Actions CI

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Create the workflows directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Write `.github/workflows/build.yml`**

```yaml
name: Build and Push Docker Image

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: |
            ghcr.io/mtaku3/cloudcli:latest
            ghcr.io/mtaku3/cloudcli:${{ github.sha }}
```

- [ ] **Step 3: Commit and push to trigger the workflow**

```bash
git add .github/workflows/build.yml
git commit -m "feat: add GitHub Actions CI to build and push image"
git push origin main
```

- [ ] **Step 4: Verify the workflow succeeded**

Open `https://github.com/mtaku3/cloudcli-image/actions` in a browser.

Expected: the `Build and Push Docker Image` workflow run shows green. Verify the package appears at `https://github.com/mtaku3?tab=packages`.

- [ ] **Step 5: Make the package public**

In the GitHub package settings (`https://github.com/users/mtaku3/packages/container/cloudcli/settings`), change visibility to **Public** so the cluster can pull it without credentials.

---

## Task 3: Add CloudCLI Kubernetes manifests

**Working directory for this and remaining tasks:** `/home/mtaku3/Workspaces/homelab-manifest`

**Files:**
- Create: `dev/cloudcli/kustomization.yaml`
- Create: `dev/cloudcli/deployment.yaml`
- Create: `dev/cloudcli/service.yaml`
- Create: `dev/cloudcli/pvc.yaml`
- Create: `dev/cloudcli/certificate.yaml`
- Create: `dev/cloudcli/ingress-route.yaml`

- [ ] **Step 1: Create the namespace directory**

```bash
mkdir dev/cloudcli
```

- [ ] **Step 2: Write `dev/cloudcli/kustomization.yaml`**

```yaml
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
  - certificate.yaml
  - ingress-route.yaml
```

- [ ] **Step 3: Write `dev/cloudcli/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudcli
  namespace: cloudcli
  labels:
    app: cloudcli
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudcli
  template:
    metadata:
      labels:
        app: cloudcli
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: cloudcli
          image: ghcr.io/mtaku3/cloudcli:latest
          ports:
            - containerPort: 3001
          volumeMounts:
            - name: data
              mountPath: /home/cloudcli
          readinessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 30
            periodSeconds: 10
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: cloudcli-data
```

- [ ] **Step 4: Write `dev/cloudcli/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cloudcli
  namespace: cloudcli
spec:
  selector:
    app: cloudcli
  ports:
    - name: http
      port: 80
      targetPort: 3001
```

- [ ] **Step 5: Write `dev/cloudcli/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cloudcli-data
  namespace: cloudcli
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
```

- [ ] **Step 6: Write `dev/cloudcli/certificate.yaml`**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: cloudcli
spec:
  secretName: web-tls-cert
  dnsNames:
    - cloudcli.mtaku3.com
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
```

- [ ] **Step 7: Write `dev/cloudcli/ingress-route.yaml`**

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: web
  namespace: cloudcli
  annotations:
    external-dns.alpha.kubernetes.io/target: 202.215.58.76
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`cloudcli.mtaku3.com`)
      kind: Rule
      services:
        - name: cloudcli
          port: http
      middlewares:
        - name: tinyauth
          namespace: traefik
  tls:
    secretName: web-tls-cert
```

- [ ] **Step 8: Validate all manifests with kubectl dry-run**

```bash
kubectl apply --dry-run=client -f dev/cloudcli/deployment.yaml
kubectl apply --dry-run=client -f dev/cloudcli/service.yaml
kubectl apply --dry-run=client -f dev/cloudcli/pvc.yaml
kubectl apply --dry-run=client -f dev/cloudcli/certificate.yaml
kubectl apply --dry-run=client -f dev/cloudcli/ingress-route.yaml
```

Expected: each command prints `<resource> configured (dry run)` with no errors.

- [ ] **Step 9: Commit**

```bash
git add dev/cloudcli/
git commit -m "feat(cloudcli): add Kubernetes manifests for CloudCLI deployment"
```

---

## Task 4: Add ArgoCD Application and create PR

**Files:**
- Create: `dev/argocd/applications/cloudcli.yaml`
- Modify: `dev/argocd/applications/kustomization.yaml`

- [ ] **Step 1: Write `dev/argocd/applications/cloudcli.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudcli
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mtaku3/homelab-manifest.git
    targetRevision: HEAD
    path: dev/cloudcli
    plugin:
      name: homelab-manifest-build
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudcli
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ForceConflicts=true
```

- [ ] **Step 2: Add `cloudcli.yaml` to `dev/argocd/applications/kustomization.yaml`**

Current contents:
```yaml
resources:
  - argocd.yaml
  - cert-manager.yaml
  - external-dns.yaml
  - gitlab.yaml
  - loxilb.yaml
  - open-webui.yaml
  - piraeus-datastore.yaml
  - sealed-secrets.yaml
  - traefik.yaml
  - victoria-metrics.yaml
```

Updated contents (add `cloudcli.yaml` in alphabetical order):
```yaml
resources:
  - argocd.yaml
  - cert-manager.yaml
  - cloudcli.yaml
  - external-dns.yaml
  - gitlab.yaml
  - loxilb.yaml
  - open-webui.yaml
  - piraeus-datastore.yaml
  - sealed-secrets.yaml
  - traefik.yaml
  - victoria-metrics.yaml
```

- [ ] **Step 3: Commit**

```bash
git add dev/argocd/applications/cloudcli.yaml dev/argocd/applications/kustomization.yaml
git commit -m "feat(cloudcli): add ArgoCD Application"
```

- [ ] **Step 4: Push branch and create PR**

```bash
git push origin HEAD
gh pr create --title "feat(cloudcli): deploy CloudCLI at cloudcli.mtaku3.com" --body "$(cat <<'EOF'
## Summary
- Adds raw K8s manifests for CloudCLI (web UI for Claude Code) in `dev/cloudcli/`
- Adds ArgoCD Application to deploy the `cloudcli` namespace
- CloudCLI is accessible at https://cloudcli.mtaku3.com behind tinyauth
- Uses custom Docker image `ghcr.io/mtaku3/cloudcli` (built in `mtaku3/cloudcli-image`)

## Test plan
- [ ] ArgoCD Application `cloudcli` shows Synced and Healthy
- [ ] Pod in `cloudcli` namespace is Running
- [ ] `https://cloudcli.mtaku3.com` redirects to tinyauth login
- [ ] After tinyauth login, CloudCLI web UI loads
- [ ] Can start a Claude Code session and authenticate with Claude.ai subscription
EOF
)"
```

---

## Verification Checklist

After the PR merges and ArgoCD syncs:

1. **ArgoCD:** `cloudcli` Application shows `Synced` + `Healthy`
2. **Pod running:** `kubectl get pods -n cloudcli` shows `1/1 Running`
3. **Certificate issued:** `kubectl get certificate -n cloudcli` shows `READY=True`
4. **DNS resolves:** `dig cloudcli.mtaku3.com` returns `202.215.58.76`
5. **Auth works:** `https://cloudcli.mtaku3.com` redirects to tinyauth, then loads CloudCLI after login
