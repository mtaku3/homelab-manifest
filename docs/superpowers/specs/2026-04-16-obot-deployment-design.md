# Obot MCP Gateway Deployment Design

## Overview

Deploy [obot.ai](https://github.com/obot-platform/obot) as an MCP (Model Context Protocol) gateway and server on bare metal Kubernetes, managed via ArgoCD. No LLM providers configured — used exclusively for MCP gateway/server functionality. Google SSO enabled for authentication.

## Architecture

### Components

1. **Obot server** — MCP gateway/server (Helm chart `obot/obot` v0.19.0 from `https://charts.obot.ai`)
2. **PostgreSQL 17 with pgvector** — Database backend (Helm chart `cloudpirates/postgres` v0.19.0, OCI registry)
3. **Traefik IngressRoute** — HTTPS ingress at `obot.mtaku3.com`
4. **cert-manager Certificate** — TLS via Let's Encrypt
5. **SealedSecrets** — Encrypted credentials in Git

### MCP Runtime

Obot spawns MCP server pods in a dedicated `obot-mcp` namespace (auto-created by the Helm chart). These are managed dynamically by obot at runtime, not by ArgoCD. The namespace has:
- Network policy restricting MCP pods to DNS, obot callbacks (port 8080), and public internet only
- Pod Security Admission set to "restricted"

## Directory Structure

```
dev/obot/
├── kustomization.yaml       # Two helmCharts entries + resources
├── values.yaml              # Obot Helm values
├── postgres-values.yaml     # CloudPirates PostgreSQL values
├── certificate.yaml         # cert-manager Certificate
├── ingress-route.yaml       # Traefik IngressRoute
├── postgres-secret.yaml     # SealedSecret for PostgreSQL password
└── obot-secret.yaml         # SealedSecret for encryption key + bootstrap token

dev/argocd/applications/obot.yaml  # ArgoCD Application
```

## ArgoCD Application

Standard Application resource following the repo pattern:

- **Source**: `dev/obot/` using `homelab-manifest-build` plugin
- **Destination**: `obot` namespace
- **Sync policy**: automated, prune, selfHeal
- **Sync options**: CreateNamespace, ServerSideApply, ForceConflicts

## PostgreSQL Configuration

Using CloudPirates PostgreSQL Helm chart (`oci://registry-1.docker.io/cloudpirates/postgres` v0.19.0):

- **Image**: `pgvector/pgvector:pg17` (drop-in replacement for official postgres, adds pgvector extension)
- **Custom user**: `obot` user with database `obot` (via `customUser` config, credentials in SealedSecret)
- **Auth**: SealedSecret `obot-postgres-auth` with keys `postgres-password`, `CUSTOM_USER`, `CUSTOM_PASSWORD`, `CUSTOM_DB`
- **Persistence**: 10Gi PVC, ReadWriteOnce
- **Service**: ClusterIP, port 5432
- **fullnameOverride**: `obot-postgres`
- **No resource requests/limits** (bare metal, no contention)

## Obot Server Configuration

Helm values for the obot chart:

| Config Key | Value |
|---|---|
| `OBOT_SERVER_HOSTNAME` | `https://obot.mtaku3.com` |
| `OBOT_SERVER_DSN` | `postgres://obot:<password>@obot-postgres:5432/obot` (stored in `obot-secret` SealedSecret) |
| `OBOT_SERVER_ENABLE_AUTHENTICATION` | `true` |
| `OBOT_SERVER_AUTH_OWNER_EMAILS` | `me@mtaku3.com` |
| `OBOT_SERVER_ENCRYPTION_PROVIDER` | `custom` |
| `OBOT_SERVER_ENCRYPTION_KEY` | From SealedSecret `obot-secret` |
| `OBOT_BOOTSTRAP_TOKEN` | From SealedSecret `obot-secret` |
| `OBOT_SERVER_MCPRUNTIME_BACKEND` | `kubernetes` |

Additional settings:
- **Ingress**: disabled (using Traefik IngressRoute instead)
- **Persistence**: 8Gi PVC at `/data` (default, local artifact storage)
- **No LLM API keys**: not needed for MCP gateway use
- **config.existingSecret**: `obot-secret` (for encryption key and bootstrap token)

Note: Non-secret config values go directly in `config:` block in values.yaml. Secret values (encryption key, bootstrap token) go in the SealedSecret referenced by `config.existingSecret`.

## Networking & TLS

### Certificate

cert-manager Certificate for `obot.mtaku3.com` using `letsencrypt` ClusterIssuer (DNS01 Cloudflare).

### IngressRoute

Traefik IngressRoute:
- Entrypoint: `websecure`
- Host: `obot.mtaku3.com`
- Service: `obot` on port 80 (Helm chart service port)
- TLS: references cert-manager secret
- DNS: `external-dns.alpha.kubernetes.io/target: 202.215.58.76`
- No tinyauth middleware (obot has its own authentication)

## Secrets

Two SealedSecrets:

### `obot-postgres-auth`
- `postgres-password`: Generated PostgreSQL superuser password

### `obot-secret`
- `OBOT_SERVER_DSN`: Full PostgreSQL connection string with password
- `OBOT_SERVER_ENCRYPTION_KEY`: Generated via `openssl rand -base64 32`
- `OBOT_BOOTSTRAP_TOKEN`: Generated token for initial admin login

## Authentication — Google SSO

Google SSO is configured post-deployment through the obot admin UI:

1. Log in with the bootstrap token
2. Navigate to Admin > User Management > Auth Providers > Google > Configure
3. Create Google OAuth 2.0 credentials in Google Cloud Console
4. Copy the callback URL from obot into Google's "Authorized redirect URIs"
5. Enter Google client ID and secret into obot's config form
6. Optionally restrict by email domain

`OBOT_SERVER_AUTH_OWNER_EMAILS=me@mtaku3.com` ensures the owner role is auto-assigned on first Google SSO login.

## Post-Deployment Steps

1. Retrieve bootstrap token from the `obot-secret` SealedSecret (or check obot logs if auto-generated)
2. Log in at `https://obot.mtaku3.com` with the bootstrap token
3. Configure Google SSO via admin UI
4. Verify MCP gateway functionality
