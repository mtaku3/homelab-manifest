# CloudCLI Deployment Design

**Date:** 2026-04-17
**Status:** Approved

## Overview

Deploy [CloudCLI](https://cloudcli.ai/) (based on the open-source [`siteboon/claudecodeui`](https://github.com/siteboon/claudecodeui)) as a self-hosted web UI for Claude Code on the homelab Kubernetes cluster, accessible at `cloudcli.mtaku3.com`.

CloudCLI is a Node.js web server (port 3001) that provides a browser/mobile UI for Claude Code sessions. It has no built-in authentication, so Traefik + tinyauth handles auth. Users authenticate with their Claude.ai subscription interactively via the web UI on first use; credentials are persisted to the PVC.

## Deliverable 1: `mtaku3/cloudcli-image` GitHub Repository

A new public GitHub repository containing the Docker image definition.

**Repo:** `github.com/mtaku3/cloudcli-image`
**Image:** `ghcr.io/mtaku3/cloudcli:latest`

### Dockerfile

- Base: `node:22-slim`
- Install native build dependencies required by CloudCLI's native modules (`node-pty`, `better-sqlite3`, `bcrypt`):
  - `build-essential`, `python3`, `python3-setuptools`, `ripgrep`, `sqlite3`, `zip`, `unzip`, `jq`
- Create non-root user `cloudcli` at UID 1000
- Install npm packages globally as root, then switch to `cloudcli` user:
  - `@cloudcli-ai/cloudcli`
  - `@anthropic-ai/claude-code`
- Working directory: `/home/cloudcli`
- Expose port `3001`
- Entrypoint: `cloudcli start --port 3001` (foreground)

### GitHub Actions CI (`.github/workflows/build.yml`)

- Trigger: push to `main`
- Build for `linux/amd64`
- Push to `ghcr.io/mtaku3/cloudcli` with tags: `latest` and the commit SHA

## Deliverable 2: `homelab-manifest` Changes

### `dev/cloudcli/` — Kubernetes Manifests

New namespace `cloudcli` with raw Kubernetes manifests following the same pattern as other services.

**`kustomization.yaml`**
References all resources in the directory.

**`deployment.yaml`**
- Single replica
- Image: `ghcr.io/mtaku3/cloudcli:latest`
- Runs as UID 1000 (`cloudcli` user)
- PVC mounted at `/home/cloudcli` (session storage and Claude auth credentials)
- Port `3001`

**`service.yaml`**
- ClusterIP service on port `3001`

**`pvc.yaml`**
- ReadWriteOnce, `20Gi`
- Stores CloudCLI session data and Claude.ai authentication credentials

**`certificate.yaml`**
- TLS certificate for `cloudcli.mtaku3.com`

**`ingress-route.yaml`**
- Host: `cloudcli.mtaku3.com`
- EntryPoint: `websecure`
- Middleware: `tinyauth` (namespace `traefik`)
- TLS: references the certificate secret
- External DNS annotation: `202.215.58.76`

### `dev/argocd/applications/cloudcli.yaml`

ArgoCD Application with:
- `path: dev/cloudcli`
- `namespace: cloudcli`
- `CreateNamespace=true`
- Automated sync with `prune: true` and `selfHeal: true`
- `ServerSideApply=true`, `ForceConflicts=true`

## Architecture

```
Browser / Mobile
      │
      ▼
Traefik (websecure)
      │  tinyauth middleware (ForwardAuth)
      ▼
CloudCLI web server :3001
      │
      ├── PVC /home/cloudcli  (sessions + Claude auth)
      │
      └── Claude Code CLI subprocess
              │
              └── Claude.ai API (user's subscription)
```

## Non-Goals

- No Anthropic API key secret — users authenticate via Claude.ai subscription through the web UI
- No Helm chart — raw manifests are sufficient for a single-service deployment
- No multi-replica — CloudCLI is stateful (PVC-backed); single replica is correct
