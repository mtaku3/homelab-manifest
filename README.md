# homelab-manifest

GitOps manifests for my personal Kubernetes homelab. Argo CD is the root of trust; everything else is reconciled from this repo.

## Layout

```
dev/
  argocd/             # Argo CD itself + Application definitions for the rest
  cert-manager/       # TLS via Let's Encrypt
  external-dns/       # DNS record sync
  gitlab/             # Self-hosted GitLab
  mt4jm/              # Personal app
  open-webui/         # LLM chat UI
  piraeus-datastore/  # LINSTOR-backed storage
  sealed-secrets/     # Encrypted secrets at rest in git
  traefik/            # Ingress + tinyauth
  victoria-metrics/   # Metrics stack
scripts/
  build.sh            # kustomize build with helm + namespace defaulting
  s2ss.sh             # convert plain Secret YAML to SealedSecret via kubeseal
docs/
```

Each app dir is a Kustomize overlay, often wrapping an upstream Helm chart via `kustomize --enable-helm`.

## Tooling

[devbox](https://www.jetify.com/devbox) pins the local toolchain (`python`, `pyyaml`, `yq`). Cluster-side tools needed: `kubectl`, `kustomize`, `helm`, `kubeseal`, `argocd`.

## Usage

Render an app locally:

```sh
./scripts/build.sh dev/traefik
```

Seal a plain Secret in place:

```sh
./scripts/s2ss.sh path/to/secret.yaml
```

## Secrets

All secrets in this repo are [SealedSecrets](https://github.com/bitnami-labs/sealed-secrets) encrypted to the controller running in the target cluster. They cannot be decrypted without that cluster's private key.

## License

MIT — see [LICENSE](LICENSE).

This repo is published as reference for my own setup. No support, no guarantees; values, hostnames, and email addresses are specific to my environment and will need to be changed before use elsewhere.
