# Hindsight recommends PGroonga for CJK text search and pgvector for vector
# search. This follows the upstream Hindsight PGroonga example while pinning
# both extension versions and the multi-architecture base image digest.
FROM groonga/pgroonga:4.0.4-debian-17@sha256:dc092196ea3a393001552d5dfbb93b9aaa3a72ad3f5cb0d20f5a6f1931790846

LABEL org.opencontainers.image.source="https://github.com/mtaku3/homelab-manifest"

ARG PGVECTOR_VERSION=v0.8.0

# The upstream image currently carries an Apache Arrow APT source whose key is
# not accepted by apt. Arrow is not needed to build or run pgvector, so remove
# only that source while retaining the Debian, PGDG, and Groonga repositories.
RUN rm /etc/apt/sources.list.d/apache-arrow.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      postgresql-server-dev-17 \
    && git clone --branch "${PGVECTOR_VERSION}" --depth 1 \
      https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && make -C /tmp/pgvector OPTFLAGS="" \
    && make -C /tmp/pgvector install \
    && rm -rf /tmp/pgvector /var/lib/apt/lists/* \
    && apt-get purge -y --auto-remove \
      build-essential \
      git \
      postgresql-server-dev-17
