# =============================================================================
# r2-to-pg Dockerfile
# Cloudflare R2 / S3 Object Storage -> PostgreSQL restore
# ghcr.io/abilfida/toolsh/r2-to-pg
# =============================================================================

FROM debian:bookworm-slim

ARG PG_MAJOR=18
ENV PG_MAJOR=${PG_MAJOR}

LABEL org.opencontainers.image.source="https://github.com/abilfida/toolsh"
LABEL org.opencontainers.image.description="Cloudflare R2 to PostgreSQL restore tool"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    gzip \
    unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    postgresql-client-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/* \
    && psql --version \
    && createdb --version \
    && dropdb --version

RUN curl -fsSL https://rclone.org/install.sh | bash \
    && rm -rf /tmp/* \
    && rclone version

COPY r2_to_pg.sh /usr/local/bin/r2_to_pg.sh
RUN chmod +x /usr/local/bin/r2_to_pg.sh

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD psql --version && rclone version || exit 1

ENTRYPOINT ["/usr/local/bin/r2_to_pg.sh"]
