#!/usr/bin/env bash
# =============================================================================
# pg_dump_to_r2.sh
# Dump PostgreSQL → Gzip → Upload ke Cloudflare R2 / S3 Object Storage
# Semua konfigurasi dibaca dari environment variables
#
# FIX LOG:
#  - [BUG1] trap cleanup EXIT dipindah SETELAH proses dump & upload selesai
#           agar file tidak terhapus sebelum di-upload
#  - [BUG2] Hapus double compression: pg_dump custom format sudah compress,
#           tidak perlu di-pipe ke gzip lagi. Gunakan format plain + gzip.
#  - [BUG3] Perbaiki rclone inline remote syntax untuk Cloudflare R2
#  - [BUG4] Tambah exit code check setelah pg_dump agar tidak lanjut upload
#           jika dump gagal
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
# [BUG2 FIX] Gunakan format plain + gzip pipe (bukan custom+gzip double)
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

# [BUG1 FIX] cleanup hanya hapus file dump sementara, dipanggil manual di akhir
# TIDAK menggunakan trap EXIT agar file tidak terhapus sebelum upload selesai
cleanup() {
    if [[ -f "$DUMP_PATH" ]]; then
        log INFO "Menghapus file dump sementara: $DUMP_PATH"
        rm -f "$DUMP_PATH"
    fi
}

# Trap hanya untuk error/interrupt — bukan EXIT normal
trap 'log ERROR "Script dibatalkan."; cleanup; exit 1' INT TERM

format_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# [BUG3 FIX] rclone remote syntax yang benar untuk Cloudflare R2
# Gunakan named remote via env variable, bukan inline connection string
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

# =============================================================================
# MULAI
# =============================================================================

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

# [BUG2 FIX] Format plain lalu pipe ke gzip — tidak ada double compression
# pg_dump format=plain menghasilkan SQL plain text, gzip mengkompresinya
# Gunakan pipefail agar error pg_dump terdeteksi meski ada pipe ke gzip
set -o pipefail

PGPASSWORD="$DB_PASSWORD" pg_dump \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    --format=plain \
    --no-owner \
    --no-acl \
    --lock-wait-timeout="${LOCK_WAIT_TIMEOUT}" \
    --keepalives=1 \
    --keepalives-idle=60 \
    --keepalives-interval=10 \
    --keepalives-count=5 \
    2>>"$LOG_FILE" \
    | gzip -"${COMPRESS_LEVEL}" > "$DUMP_PATH"

# [BUG4 FIX] Cek exit code pipe — pastikan dump benar-benar sukses
DUMP_EXIT=${PIPESTATUS[0]}
GZIP_EXIT=${PIPESTATUS[1]}

if [[ "$DUMP_EXIT" -ne 0 ]]; then
    log ERROR "pg_dump gagal dengan exit code ${DUMP_EXIT}. Lihat log: ${LOG_FILE}"
    cleanup
    exit 1
fi

if [[ "$GZIP_EXIT" -ne 0 ]]; then
    log ERROR "gzip gagal dengan exit code ${GZIP_EXIT}."
    cleanup
    exit 1
fi

# Validasi file tidak kosong
if [[ ! -s "$DUMP_PATH" ]]; then
    log ERROR "File dump kosong (0 bytes): ${DUMP_PATH}"
    cleanup
    exit 1
fi

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
DUMP_SIZE=$(format_size "$DUMP_PATH")
log OK "Dump selesai dalam ${ELAPSED}s. Ukuran file: ${DUMP_SIZE}"

# =============================================================================
# [4/4] UPLOAD KE CLOUDFLARE R2
# =============================================================================

log STEP "[4/4] Mengupload ke Cloudflare R2..."

UPLOAD_START=$(date +%s)

# [BUG3 FIX] Gunakan named remote "R2:" yang dikonfigurasi via RCLONE_CONFIG_R2_*
rclone copy \
    "$DUMP_PATH" \
    "R2:${R2_BUCKET}/${R2_PREFIX}/" \
    --transfers=1 \
    --retries=3 \
    --retries-sleep=10s \
    --stats=30s \
    -v \
    2>&1 | tee -a "$LOG_FILE"

UPLOAD_EXIT=${PIPESTATUS[0]}
if [[ "$UPLOAD_EXIT" -ne 0 ]]; then
    log ERROR "Upload ke R2 gagal dengan exit code ${UPLOAD_EXIT}. Lihat log: ${LOG_FILE}"
    cleanup
    exit 1
fi

UPLOAD_END=$(date +%s)
UPLOAD_ELAPSED=$(( UPLOAD_END - UPLOAD_START ))
log OK "Upload ke R2 selesai dalam ${UPLOAD_ELAPSED}s."

# =============================================================================
# HAPUS FILE DUMP SEMENTARA (setelah upload sukses)
# =============================================================================

cleanup

# =============================================================================
# RETENSI: HAPUS FILE LAMA DI R2
# =============================================================================

if [[ "${RETENTION_DAYS}" -gt 0 ]]; then
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
                "R2:${R2_BUCKET}/${R2_PREFIX}/${FILE_NAME}" \
                2>>"$LOG_FILE" \
                && DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        fi
    done < <(rclone lsl \
        "R2:${R2_BUCKET}/${R2_PREFIX}/" \
        2>>"$LOG_FILE" | grep "\.dump\.gz$" || true)

    log OK "Retensi selesai: ${DELETED_COUNT} file lama dihapus."
fi

# =============================================================================
# VERIFIKASI LIST FILE DI R2
# =============================================================================

log INFO "File backup di r2://${R2_BUCKET}/${R2_PREFIX}/:"
rclone lsl \
    "R2:${R2_BUCKET}/${R2_PREFIX}/" \
    2>>"$LOG_FILE" \
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
