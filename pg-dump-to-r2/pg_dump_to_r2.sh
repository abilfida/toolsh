#!/usr/bin/env bash
# =============================================================================
# pg_dump_to_r2.sh
# Dump PostgreSQL → Gzip → Upload ke Cloudflare R2 / S3 Object Storage
# Semua konfigurasi dibaca dari environment variables
# =============================================================================

set -euo pipefail

# =============================================================================
# BACA ENV VARS (dengan validasi wajib)
# =============================================================================

# --- DATABASE ---
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:?ERROR: DB_USER env var wajib diisi}"
DB_PASSWORD="${DB_PASSWORD:?ERROR: DB_PASSWORD env var wajib diisi}"
DB_NAME="${DB_NAME:?ERROR: DB_NAME env var wajib diisi}"

# --- CLOUDFLARE R2 / S3 ---
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:?ERROR: R2_ACCOUNT_ID env var wajib diisi}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?ERROR: R2_ACCESS_KEY_ID env var wajib diisi}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?ERROR: R2_SECRET_ACCESS_KEY env var wajib diisi}"
R2_BUCKET="${R2_BUCKET:?ERROR: R2_BUCKET env var wajib diisi}"
R2_PREFIX="${R2_PREFIX:-pg-backups}"
R2_ENDPOINT="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"

# --- OPSI DUMP ---
COMPRESS_LEVEL="${COMPRESS_LEVEL:-9}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DUMP_DIR="${DUMP_DIR:-/tmp}"
LOCK_WAIT_TIMEOUT="${LOCK_WAIT_TIMEOUT:-120s}"

# =============================================================================
# SETUP
# =============================================================================

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DUMP_FILENAME="${DB_NAME}_${TIMESTAMP}.dump.gz"
DUMP_PATH="${DUMP_DIR}/${DUMP_FILENAME}"
LOG_FILE="${DUMP_DIR}/pg_dump_r2_${TIMESTAMP}.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log() {
    local level="$1"; local message="$2"; local color="$NC"
    local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
    case "$level" in
        INFO)  color="$CYAN"   ;;
        OK)    color="$GREEN"  ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED"    ;;
        STEP)  color="$BLUE"   ;;
    esac
    echo -e "${color}[${ts}] [${level}] ${message}${NC}" | tee -a "$LOG_FILE"
}

check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        log ERROR "Command '$1' tidak ditemukan di dalam image."
        exit 1
    fi
}

cleanup() {
    if [[ -f "$DUMP_PATH" ]]; then
        log INFO "Menghapus file dump sementara: $DUMP_PATH"
        rm -f "$DUMP_PATH"
    fi
}

format_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# rclone inline remote — tidak perlu rclone.conf
RCLONE_REMOTE=":s3,provider=Cloudflare,access_key_id=${R2_ACCESS_KEY_ID},secret_access_key=${R2_SECRET_ACCESS_KEY},endpoint=${R2_ENDPOINT},no_check_bucket=true:"

# =============================================================================
# MULAI
# =============================================================================

trap cleanup EXIT

log STEP "============================================================"
log STEP "  PG Dump to R2 | ghcr.io/abilfida/toolsh/pg-dump-to-r2"
log STEP "  Database : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log STEP "  Tujuan   : r2://${R2_BUCKET}/${R2_PREFIX}/${DUMP_FILENAME}"
log STEP "  Log      : ${LOG_FILE}"
log STEP "============================================================"

# =============================================================================
# [1/4] CEK DEPENDENSI
# =============================================================================

log STEP "[1/4] Memeriksa dependensi..."
check_dependency pg_dump
check_dependency gzip
check_dependency rclone
log OK "Semua dependensi tersedia."

# =============================================================================
# [2/4] TEST KONEKSI DATABASE
# =============================================================================

log STEP "[2/4] Menguji koneksi ke database..."
if ! PGPASSWORD="$DB_PASSWORD" pg_isready \
    -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q 2>>"$LOG_FILE"; then
    log ERROR "Tidak dapat terhubung ke PostgreSQL ${DB_HOST}:${DB_PORT}."
    exit 1
fi
log OK "Koneksi database OK."

# =============================================================================
# [3/4] PG_DUMP + GZIP STREAMING
# =============================================================================

log STEP "[3/4] Menjalankan pg_dump → gzip streaming..."
log INFO "File output : $DUMP_PATH"

START_TIME=$(date +%s)

PGPASSWORD="$DB_PASSWORD" pg_dump \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    --format=custom \
    --no-owner \
    --no-acl \
    --compress="${COMPRESS_LEVEL}" \
    --lock-wait-timeout="${LOCK_WAIT_TIMEOUT}" \
    --keepalives=1 \
    --keepalives-idle=60 \
    --keepalives-interval=10 \
    --keepalives-count=5 \
    2>>"$LOG_FILE" \
    | gzip -"${COMPRESS_LEVEL}" > "$DUMP_PATH"

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
DUMP_SIZE=$(format_size "$DUMP_PATH")
log OK "Dump selesai dalam ${ELAPSED}s. Ukuran file: ${DUMP_SIZE}"

# =============================================================================
# [4/4] UPLOAD KE CLOUDFLARE R2
# =============================================================================

log STEP "[4/4] Mengupload ke Cloudflare R2..."

UPLOAD_START=$(date +%s)

rclone copy \
    "$DUMP_PATH" \
    "${RCLONE_REMOTE}${R2_BUCKET}/${R2_PREFIX}/" \
    --s3-no-check-bucket \
    --s3-force-path-style \
    --transfers=1 \
    --retries=3 \
    --retries-sleep=10s \
    --stats=30s \
    --log-file="$LOG_FILE" \
    --log-level=INFO \
    2>>"$LOG_FILE"

UPLOAD_END=$(date +%s)
UPLOAD_ELAPSED=$(( UPLOAD_END - UPLOAD_START ))
log OK "Upload ke R2 selesai dalam ${UPLOAD_ELAPSED}s."

# =============================================================================
# RETENSI: HAPUS FILE LAMA DI R2
# =============================================================================

if [[ "$RETENTION_DAYS" -gt 0 ]]; then
    log INFO "Menerapkan retensi: hapus file lebih dari ${RETENTION_DAYS} hari..."

    CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" +%s 2>/dev/null \
        || date -v "-${RETENTION_DAYS}d" +%s 2>/dev/null || echo 0)
    DELETED_COUNT=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        FILE_DATE=$(echo "$line" | awk '{print $1, $2}')
        FILE_NAME=$(echo "$line" | awk '{print $NF}')
        FILE_EPOCH=$(date -d "$FILE_DATE" +%s 2>/dev/null || echo 0)

        if [[ "$FILE_EPOCH" -lt "$CUTOFF_DATE" ]]; then
            log INFO "Menghapus file lama: $FILE_NAME"
            rclone delete \
                "${RCLONE_REMOTE}${R2_BUCKET}/${R2_PREFIX}/${FILE_NAME}" \
                --s3-no-check-bucket 2>>"$LOG_FILE" \
                && DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        fi
    done < <(rclone lsl \
        "${RCLONE_REMOTE}${R2_BUCKET}/${R2_PREFIX}/" \
        --s3-no-check-bucket 2>>"$LOG_FILE" | grep "\.dump\.gz$" || true)

    log OK "Retensi selesai: ${DELETED_COUNT} file lama dihapus."
fi

# =============================================================================
# VERIFIKASI LIST FILE DI R2
# =============================================================================

log INFO "File backup di r2://${R2_BUCKET}/${R2_PREFIX}/:"
rclone lsl \
    "${RCLONE_REMOTE}${R2_BUCKET}/${R2_PREFIX}/" \
    --s3-no-check-bucket 2>>"$LOG_FILE" \
    | grep "\.dump\.gz$" \
    | while read -r size date time name; do
        echo -e "  \033[0;36m→\033[0m ${name}  (${size} bytes | ${date} ${time})"
    done || true

# =============================================================================
# SELESAI
# =============================================================================

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(( TOTAL_END - START_TIME ))

log STEP "============================================================"
log OK "  Backup selesai dalam total ${TOTAL_ELAPSED}s"
log OK "  File  : r2://${R2_BUCKET}/${R2_PREFIX}/${DUMP_FILENAME}"
log OK "  Size  : ${DUMP_SIZE}"
log STEP "============================================================"
