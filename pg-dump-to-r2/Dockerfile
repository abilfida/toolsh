# =============================================================================
# pg-dump-to-r2 Dockerfile
# PostgreSQL dump -> gzip -> Cloudflare R2 / S3 Object Storage
# ghcr.io/abilfida/toolsh/pg-dump-to-r2
#
# FIX: Install PostgreSQL client dari official PGDG APT repo
#      agar versi pg_dump selalu match dengan versi server PostgreSQL
#      Default PG_MAJOR=18, override via --build-arg PG_MAJOR=16
# =============================================================================

FROM debian:bookworm-slim

# Build arg untuk versi PostgreSQL client
# Sesuaikan dengan versi server PostgreSQL kamu
# Contoh: --build-arg PG_MAJOR=16 atau --build-arg PG_MAJOR=18
ARG PG_MAJOR=18
ENV PG_MAJOR=${PG_MAJOR}

LABEL org.opencontainers.image.source="https://github.com/abilfida/toolsh"
LABEL org.opencontainers.image.description="PostgreSQL dump to Cloudflare R2 / S3 Object Storage"
LABEL org.opencontainers.image.licenses="MIT"

# Install dependencies dasar + tambah PGDG official APT repo
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        lsb-release \
        gzip \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Tambahkan PostgreSQL official APT repository (PGDG)
# Ini memastikan pg_dump versi terbaru (16/17/18) tersedia
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \
https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

# Install PostgreSQL client sesuai PG_MAJOR
# pg_dump versi ini harus >= versi server PostgreSQL
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-client-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/* \
    && pg_dump --version

# Install rclone (latest stable)
RUN curl -fsSL https://rclone.org/install.sh | bash \
    && rm -rf /tmp/* \
    && rclone version

# Copy script utama
COPY pg_dump_to_r2.sh /usr/local/bin/pg_dump_to_r2.sh
RUN chmod +x /usr/local/bin/pg_dump_to_r2.sh

# Default dump dir
RUN mkdir -p /backup
VOLUME ["/backup"]

# Healthcheck — pastikan pg_dump dan rclone tersedia
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pg_dump --version && rclone version || exit 1

ENTRYPOINT ["/usr/local/bin/pg_dump_to_r2.sh"]
