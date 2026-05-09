# =============================================================================
# pg-dump-to-r2
# Docker image: PostgreSQL dump → Gzip → Cloudflare R2 / S3 Object Storage
# ghcr.io/abilfida/toolsh/pg-dump-to-r2
# =============================================================================

FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/abilfida/toolsh"
LABEL org.opencontainers.image.description="PostgreSQL dump to Cloudflare R2 / S3 Object Storage"
LABEL org.opencontainers.image.licenses="MIT"

# Install PostgreSQL client, gzip, curl
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    gzip \
    curl \
    ca-certificates \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install rclone
RUN curl -fsSL https://rclone.org/install.sh | bash \
    && rm -rf /tmp/*

# Copy script
COPY pg_dump_to_r2.sh /usr/local/bin/pg_dump_to_r2.sh
RUN chmod +x /usr/local/bin/pg_dump_to_r2.sh

# =============================================================================
# ENV VARS — semua dapat di-override via docker run -e / K8S env / .env file
# Variabel tanpa default WAJIB diisi (akan error jika kosong)
# =============================================================================

# --- DATABASE ---
ENV DB_HOST="127.0.0.1"
ENV DB_PORT="5432"
ENV DB_USER=""
ENV DB_PASSWORD=""
ENV DB_NAME=""

# --- CLOUDFLARE R2 / S3 ---
ENV R2_ACCOUNT_ID=""
ENV R2_ACCESS_KEY_ID=""
ENV R2_SECRET_ACCESS_KEY=""
ENV R2_BUCKET=""
ENV R2_PREFIX="pg-backups"
ENV R2_ENDPOINT=""

# --- OPSI DUMP ---
ENV COMPRESS_LEVEL="9"
ENV RETENTION_DAYS="7"
ENV DUMP_DIR="/tmp"
ENV LOCK_WAIT_TIMEOUT="120s"

ENTRYPOINT ["/usr/local/bin/pg_dump_to_r2.sh"]
