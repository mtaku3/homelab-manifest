# Hindsight

Self-hosted Hindsight for persistent Codex memory.

## Hindsight recommendations applied

- OpenRouter's recommended default model: `qwen/qwen3.5-9b`
- Multilingual embeddings: `BAAI/bge-m3`
- Multilingual reranker: `BAAI/bge-reranker-v2-m3`
- PGroonga for Japanese/CJK keyword search
- External PostgreSQL 15+ with pgvector for production
- API key authentication and a stable worker ID

References:

- <https://hindsight.vectorize.io/developer/models>
- <https://hindsight.vectorize.io/developer/multilingual>
- <https://hindsight.vectorize.io/developer/installation>
- <https://hindsight.vectorize.io/developer/configuration>

## Homelab decisions

### CloudPirates PostgreSQL chart

This follows the repository's former Coder and Obot deployments: PostgreSQL is
a separate CloudPirates Helm release, credentials are supplied by a
SealedSecret, and data is stored on a 10Gi Piraeus PVC. Separating the database
from Hindsight prevents an application chart upgrade or removal from owning the
database lifecycle.

### Combined PGroonga and pgvector image

Hindsight's official PGroonga example builds pgvector on top of the PGroonga
image. The application-independent image is built in the companion
[`postgres-pgroonga-pgvector-image`](https://github.com/mtaku3/postgres-pgroonga-pgvector-image)
repository because the historically used `pgvector/pgvector:pg17` image does
not include PGroonga. It contains PostgreSQL 17, PGroonga 4.0.8, and pgvector
0.8.6, matching Hindsight's current upstream recipe. The base image digest and
the exact pgvector package version are pinned, and consumers use the image
repository's complete Git commit SHA plus the published multi-platform digest.

This is intentionally not a Hindsight-specific image. Database names, users,
extension initialization, credentials, and Hindsight connection settings stay
in this manifest repository. This keeps the image reusable by any PostgreSQL
consumer that needs both extensions and follows the existing `*-image`
repository naming convention.

The GHCR package is publicly readable. Its multi-platform manifest was verified
without Docker credentials, so the database does not need an image pull secret.

### Model cache PVC

Hindsight prefers baking non-default local models into a production image. This
deployment deliberately uses a 10Gi model-cache PVC instead: the homelab has one
node and one API replica, so the RWO scheduling cost is negligible, while a
second very large multi-architecture image build would add substantial registry
storage and CI time. The PVC avoids downloading BGE-M3 and its reranker after
every pod restart. A custom API image remains an upgrade path if replicas are
added later.

### Resource sizing

The API request/limit is raised above the chart default because BGE-M3 and
BGE-reranker-v2-m3 are substantially larger than Hindsight's English defaults.
The 4Gi request and 8Gi limit leave room for both models and runtime overhead on
the homelab's 32Gi node. PostgreSQL receives a 512Mi request and 2Gi limit to
cover extension initialization and index maintenance without reserving an
excessive share of the single node.

### Runtime topology and ingress

One API replica with its internal worker and one Control Plane replica are used
because this is a single-user memory service. Dedicated workers can be added if
operation queues or retain latency show sustained contention. Traefik,
cert-manager, SealedSecrets, and Piraeus follow the repository's existing
ingress, TLS, credential, and storage conventions.

Only `/v1` is routed to the API. The MCP endpoint and `/metrics` remain
cluster-internal; the Codex integration uses Hindsight's authenticated external
API mode.
