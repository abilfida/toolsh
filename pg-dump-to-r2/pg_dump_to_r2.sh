#!/usr/bin/env bash
# =============================================================================
# pg_dump_to_r2.sh v5
# PostgreSQL Dump -> gzip -> Cloudflare R2 / S3 Object Storage
# Repo : ghcr.io/abilfida/toolsh/pg-dump-to-r2
#
# CHANGELOG v5 - ZERO DISK USAGE (streaming pipeline):
#   [FIX 13] Ganti pendekatan file sementara ke streaming pipeline
#            pg_dump | gzip | rclone rcat -> R2 langsung tanpa tulis ke disk
#            Disk usage: 0 bytes (sebelumnya: 2x ukuran DB)
#   [FIX 14] Exit code pipeline ditangkap via named pipe + subshell trick
#            Karena PIPESTATUS tidak bisa dipakai dengan process substitution
#   [FIX 15] Progress tracking via rclone stats ke stderr terpisah
#   Tetap ada semua fix dari v4:
#            - stderr pg_dump langsung tampil ke console
#            - TCP keepalive di DSN connection string
#            - Version check pg_dump vs server
#            - Log versi semua tools
# =============================================================================
#
# CARA KERJA STREAMING:
#
#   SEBELUM (v3/v4) - butuh disk 2x ukuran DB:
#     pg_dump -> /tmp/db.sql (misal 5GB)
#     gzip    -> /tmp/db.sql.gz (misal 1GB)
#     upload  -> R2
#     total disk: 6GB!
#
#   SESUDAH (v5) - disk usage = 0:
#     pg_dump stdout
#         |
#       gzip stdin/stdout
#         |
#       rclone rcat stdin -> R2
#     total disk: 0 bytes
#
# =============================================================================

set -uo pipefail

# =============================================================================
# KONFIGURASI - semua dari ENV VAR
# =============================================================================

# --- DATABASE ---
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-postgres}"

# --- TCP KEEPALIVE & TIMEOUT ---
DB_KEEPALIVES="${DB_KEEPALIVES:-1}"
DB_KEEPALIVES_IDLE="${DB_KEEPALIVES_IDLE:-30}"
DB_KEEPALIVES_INTERVAL="${DB_KEEPALIVES_INTERVAL:-10}"
DB_KEEPALIVES_COUNT="${DB_KEEPALIVES_COUNT:-5}"
DB_CONNECT_TIMEOUT="${DB_CONNECT_TIMEOUT:-30}"
DB_TCP_USER_TIMEOUT="${DB_TCP_USER_TIMEOUT:-60000}"

# --- CLOUDFLARE R2 ---
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
R2_BUCKET="${R2_BUCKET:-}"
R2_PREFIX="${R2_PREFIX:-pg-backups}"

# --- OPSI BACKUP ---
RETENTION_DAYS="${RETENTION_DAYS:-7}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-6}"

# =============================================================================
# INTERNAL VARS
# =============================================================================
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILENAME="${DB_NAME}_${TIMESTAMP}.dump.gz"
LOG_FILE="/tmp/pg_dump_r2_${TIMESTAMP}.log"
R2_DEST="${R2_BUCKET}/${R2_PREFIX}/${DUMP_FILENAME}"

# File untuk menangkap exit code dari setiap stage pipeline
PIPE_STATUS_FILE="/tmp/pg_dump_pipe_status_${TIMESTAMP}"

# =============================================================================
# FUNGSI LOGGING
# =============================================================================
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    echo "$line" | tee -a "$LOG_FILE"
}

# =============================================================================
# CLEANUP - hanya hapus file status temp, tidak ada file dump
# =============================================================================
cleanup() {
    rm -f "${PIPE_STATUS_FILE}_pgdump"
    rm -f "${PIPE_STATUS_FILE}_gzip"
    rm -f "${PIPE_STATUS_FILE}_rclone"
}

trap 'log WARN "Script dihentikan paksa (INT/TERM)."; cleanup; exit 130' INT TERM

# =============================================================================
# INISIALISASI
# =============================================================================
touch "$LOG_FILE"

log STEP "============================================================"
log STEP "  PG Dump to R2 | ghcr.io/abilfida/toolsh/pg-dump-to-r2 v5"
log STEP "  Mode     : STREAMING (zero disk usage)"
log STEP "  Database : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log STEP "  Tujuan   : r2://${R2_DEST}"
log STEP "  Log      : ${LOG_FILE}"
log STEP "============================================================"

# =============================================================================
# STEP 1 - Validasi ENV VARS
# =============================================================================
log STEP "[1/4] Validasi konfigurasi..."

REQUIRED_VARS=(
    "DB_HOST" "DB_PORT" "DB_USER" "DB_PASSWORD" "DB_NAME"
    "R2_ACCOUNT_ID" "R2_ACCESS_KEY_ID" "R2_SECRET_ACCESS_KEY" "R2_BUCKET"
)
MISSING=0
for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR:-}" ]]; then
        log ERROR "ENV VAR wajib tidak diset: ${VAR}"
        MISSING=1
    fi
done
if [[ $MISSING -eq 1 ]]; then
    log ERROR "Konfigurasi tidak lengkap. Script berhenti."
    exit 1
fi
log OK "Semua konfigurasi valid."

# =============================================================================
# STEP 2 - Cek dependensi + versi + version check
# =============================================================================
log STEP "[2/4] Memeriksa dependensi dan versi..."

for CMD in pg_dump psql gzip rclone; do
    if ! command -v "$CMD" &>/dev/null; then
        log ERROR "Command tidak ditemukan: $CMD"
        exit 1
    fi
done

PGDUMP_VER=$(pg_dump --version 2>&1)
PSQL_VER=$(psql --version 2>&1)
RCLONE_VER=$(rclone version 2>&1 | head -1)
GZIP_VER=$(gzip --version 2>&1 | head -1)

log INFO "pg_dump  : ${PGDUMP_VER}"
log INFO "psql     : ${PSQL_VER}"
log INFO "rclone   : ${RCLONE_VER}"
log INFO "gzip     : ${GZIP_VER}"
log OK "Semua dependensi tersedia."

# =============================================================================
# STEP 3 - Uji koneksi + version check
# =============================================================================
log STEP "[3/4] Menguji koneksi dan kompatibilitas versi..."

export PGPASSWORD="$DB_PASSWORD"
export PGCONNECT_TIMEOUT="$DB_CONNECT_TIMEOUT"

CONN_TEST=$(psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" \
    -c "SELECT version()" -tAq 2>&1)
CONN_RC=$?

if [[ $CONN_RC -ne 0 ]]; then
    log ERROR "Koneksi database GAGAL (exit: ${CONN_RC}): ${CONN_TEST}"
    exit 1
fi
log OK "Koneksi database OK."
log INFO "Server   : $(echo "$CONN_TEST" | head -1)"

# Version compatibility check
SERVER_VER_NUM=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -tAq -c "SHOW server_version_num;" 2>/dev/null || echo "0")
SERVER_MAJOR=$(echo "$SERVER_VER_NUM" | cut -c1-2)
CLIENT_MAJOR=$(pg_dump --version 2>/dev/null | grep -oE '[0-9]+' | head -1)

log INFO "Version check: pg_dump v${CLIENT_MAJOR} vs server v${SERVER_MAJOR}"

if [[ "$CLIENT_MAJOR" -lt "$SERVER_MAJOR" ]]; then
    log ERROR "VERSION MISMATCH: pg_dump v${CLIENT_MAJOR} < server v${SERVER_MAJOR}"
    log ERROR "Rebuild image dengan: --build-arg PG_MAJOR=${SERVER_MAJOR}"
    exit 1
fi
log OK "Versi kompatibel: pg_dump v${CLIENT_MAJOR} >= server v${SERVER_MAJOR}."

# =============================================================================
# STEP 4 - STREAMING PIPELINE: pg_dump | gzip | rclone rcat -> R2
#
# Teknik: jalankan setiap stage di subshell terpisah, simpan exit code
# ke file temp, lalu cek setelah pipeline selesai.
#
# rclone rcat: baca dari stdin dan upload langsung ke R2
# Tidak ada file yang ditulis ke disk sama sekali.
# =============================================================================
log STEP "[4/4] Streaming: pg_dump | gzip | rclone rcat -> R2..."
log INFO "File tujuan : ${DUMP_FILENAME}"
log INFO "Kompresi    : gzip level ${COMPRESS_LEVEL}"
log INFO "Keepalives  : idle=${DB_KEEPALIVES_IDLE}s interval=${DB_KEEPALIVES_INTERVAL}s"
log INFO "Disk usage  : 0 bytes (pure streaming)"

# DSN dengan TCP keepalive
PG_DSN="host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} \
password=${DB_PASSWORD} connect_timeout=${DB_CONNECT_TIMEOUT} \
keepalives=${DB_KEEPALIVES} keepalives_idle=${DB_KEEPALIVES_IDLE} \
keepalives_interval=${DB_KEEPALIVES_INTERVAL} keepalives_count=${DB_KEEPALIVES_COUNT} \
tcp_user_timeout=${DB_TCP_USER_TIMEOUT}"

# Konfigurasi rclone named remote R2
export RCLONE_CONFIG_R2_TYPE="s3"
export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_REGION="auto"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"
export RCLONE_CONFIG_R2_ACL="private"

log INFO "Memulai streaming pipeline..."
STREAM_START=$(date +%s)

# Jalankan pipeline dengan exit code capture per stage
# Menggunakan subshell + file status untuk bypass keterbatasan PIPESTATUS
(
    pg_dump \
        -d "${PG_DSN}" \
        --format=plain \
        --no-owner \
        --no-acl \
        2> >(tee -a "$LOG_FILE" >&2)
    echo $? > "${PIPE_STATUS_FILE}_pgdump"
) | (
    gzip -"${COMPRESS_LEVEL}" -c
    echo $? > "${PIPE_STATUS_FILE}_gzip"
) | (
    rclone rcat \
        "R2:${R2_BUCKET}/${R2_PREFIX}/${DUMP_FILENAME}" \
        --s3-chunk-size=64M \
        --s3-upload-concurrency=4 \
        --retries=5 \
        --retries-sleep=15s \
        --log-level=INFO \
        --stats=60s \
        2>&1 | tee -a "$LOG_FILE"
    echo ${PIPESTATUS[0]} > "${PIPE_STATUS_FILE}_rclone"
)
PIPELINE_RC=$?

STREAM_END=$(date +%s)
STREAM_DURATION=$(( STREAM_END - STREAM_START ))

log INFO "Durasi streaming: ${STREAM_DURATION} detik"

# Baca exit code masing-masing stage
PGDUMP_RC=$(cat "${PIPE_STATUS_FILE}_pgdump" 2>/dev/null || echo "99")
GZIP_RC=$(cat "${PIPE_STATUS_FILE}_gzip" 2>/dev/null || echo "99")
RCLONE_RC=$(cat "${PIPE_STATUS_FILE}_rclone" 2>/dev/null || echo "99")

log INFO "Exit codes: pg_dump=${PGDUMP_RC} | gzip=${GZIP_RC} | rclone=${RCLONE_RC}"

# Cek exit code tiap stage
FAIL=0

if [[ "$PGDUMP_RC" -ne 0 ]]; then
    log ERROR "pg_dump GAGAL (exit: ${PGDUMP_RC}) - cek log untuk detail error"
    FAIL=1
fi

if [[ "$GZIP_RC" -ne 0 ]]; then
    log ERROR "gzip GAGAL (exit: ${GZIP_RC})"
    FAIL=1
fi

if [[ "$RCLONE_RC" -ne 0 ]]; then
    log ERROR "rclone GAGAL (exit: ${RCLONE_RC})"
    FAIL=1
fi

if [[ $FAIL -ne 0 ]]; then
    log ERROR "Streaming pipeline GAGAL. Cek log: ${LOG_FILE}"
    cleanup
    exit 1
fi

log OK "Streaming pipeline selesai sukses dalam ${STREAM_DURATION} detik."

# Verifikasi file ada di R2
log INFO "Verifikasi file di R2..."
VERIFY=$(rclone lsf "R2:${R2_BUCKET}/${R2_PREFIX}/" \
    --include "${DUMP_FILENAME}" 2>&1)
VERIFY_RC=$?

if [[ $VERIFY_RC -ne 0 || -z "$VERIFY" ]]; then
    log WARN "Verifikasi R2 tidak berhasil konfirmasi file (non-fatal): ${VERIFY}"
else
    # Dapatkan ukuran file di R2
    R2_SIZE=$(rclone lsl "R2:${R2_BUCKET}/${R2_PREFIX}/" \
        --include "${DUMP_FILENAME}" 2>/dev/null \
        | awk '{print $1}' | head -1)
    log OK "Verifikasi R2: ${DUMP_FILENAME} (${R2_SIZE:-unknown} bytes) ditemukan di bucket."
fi

cleanup

# =============================================================================
# RETENTION - hapus file lama di R2
# =============================================================================
if [[ "${RETENTION_DAYS}" -gt 0 ]]; then
    log INFO "Retensi: hapus file lebih dari ${RETENTION_DAYS} hari di R2..."
    rclone delete \
        "R2:${R2_BUCKET}/${R2_PREFIX}/" \
        --min-age="${RETENTION_DAYS}d" \
        --log-level=INFO \
        2>&1 | tee -a "$LOG_FILE"
    RETAIN_RC=${PIPESTATUS[0]}
    if [[ $RETAIN_RC -ne 0 ]]; then
        log WARN "Retention cleanup gagal (non-fatal)."
    else
        log OK "Retention cleanup selesai."
    fi
fi

# =============================================================================
# SELESAI
# =============================================================================
log STEP "============================================================"
log STEP "  SELESAI SUKSES"
log STEP "  File     : ${DUMP_FILENAME}"
log STEP "  Lokasi   : r2://${R2_DEST}"
log STEP "  Durasi   : ${STREAM_DURATION} detik"
log STEP "  Disk used: 0 bytes"
log STEP "  Log      : ${LOG_FILE}"
log STEP "============================================================"

exit 0
