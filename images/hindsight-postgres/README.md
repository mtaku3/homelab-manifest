# Hindsight PostgreSQL image

PostgreSQL 17 with both PGroonga and pgvector for Hindsight's multilingual
hybrid retrieval.

The image follows Hindsight's upstream
[`docker/docker-compose/pgroonga/Dockerfile`](https://github.com/vectorize-io/hindsight/blob/main/docker/docker-compose/pgroonga/Dockerfile),
with immutable component versions for reproducible GitOps deployments.

The pinned PGroonga base currently includes an Apache Arrow APT source with an
unusable signing key. Arrow is unrelated to PostgreSQL, PGroonga, and pgvector,
so the Dockerfile removes only that source before installing build tools. The
Debian, PostgreSQL, and Groonga package sources remain enabled.

Published image:

```text
ghcr.io/mtaku3/hindsight-postgres:pg17-pgroonga4.0.4-pgvector0.8.0-r1
```

The tag is treated as immutable. Increment the `-rN` suffix whenever the
Dockerfile changes.
