#!/usr/bin/env bash
# =============================================================================
# pg_dump_to_r2.sh v4
# PostgreSQL Dump -> gzip -> Upload ke Cloudflare R2 / S3 Object Storage
# Repo : ghcr.io/abilfida/toolsh/pg-dump-to-r2
#
# CHANGELOG v4:
#   [FIX 7] Tampilkan stderr pg_dump langsung ke stdout DAN log file
#           Sebelumnya error pg_dump hanya masuk ke log file (tidak terlihat)
#   [FIX 8] Tambah log versi pg_dump, psql, rclone di awal untuk diagnosis
#   [FIX 9] Tambah TCP keepalive di connection string pg_dump
#           pg_dump berjalan 80 detik lalu gagal = koneksi idle diputus firewall
#   [FIX 10] Tambah PGCONNECT_TIMEOUT dan keepalive parameter
#   [FIX 11] Redirect stderr pg_dump ke fd terpisah agar error langsung tampil
#   [FIX 12] Tambah diagnosa pg_dump version check di awal
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

# --- TCP KEEPALIVE & TIMEOUT (detik) ---
# Mencegah koneksi putus saat dump data besar melintasi network
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
DUMP_DIR="${DUMP_DIR:-/backup}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-6}"

# =============================================================================
# INTERNAL VARS
# =============================================================================
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DUMP_FILENAME="${DB_NAME}_${TIMESTAMP}.dump.gz"
DUMP_SQL="${DUMP_DIR}/${DB_NAME}_${TIMESTAMP}.sql"
DUMP_GZ="${DUMP_DIR}/${DUMP_FILENAME}"
LOG_FILE="/tmp/pg_dump_r2_${TIMESTAMP}.log"
R2_DEST="${R2_BUCKET}/${R2_PREFIX}/${DUMP_FILENAME}"

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

format_size() {
    local file="$1"
    if [[ -f "$file" ]]; then
        du -sh "$file" 2>/dev/null | cut -f1
    else
        echo "0B"
    fi
}

# =============================================================================
# CLEANUP
# =============================================================================
cleanup() {
    local mode="${1:-success}"
    if [[ -f "$DUMP_SQL" ]]; then
        log INFO "Menghapus file SQL sementara: $DUMP_SQL"
        rm -f "$DUMP_SQL"
    fi
    if [[ "$mode" == "failed" && -f "$DUMP_GZ" ]]; then
        log INFO "Menghapus file GZ gagal: $DUMP_GZ"
        rm -f "$DUMP_GZ"
    elif [[ "$mode" == "success" && -f "$DUMP_GZ" ]]; then
        log INFO "Menghapus file GZ lokal (sudah terupload): $DUMP_GZ"
        rm -f "$DUMP_GZ"
    fi
}

trap 'log WARN "Script dihentikan paksa (INT/TERM)."; cleanup failed; exit 130' INT TERM

# =============================================================================
# INISIALISASI
# =============================================================================
mkdir -p "$DUMP_DIR"
touch "$LOG_FILE"

log STEP "============================================================"
log STEP "  PG Dump to R2 | ghcr.io/abilfida/toolsh/pg-dump-to-r2 v4"
log STEP "  Database : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log STEP "  Tujuan   : r2://${R2_DEST}"
log STEP "  Log      : ${LOG_FILE}"
log STEP "  Dump Dir : ${DUMP_DIR}"
log STEP "============================================================"

# =============================================================================
# STEP 1 - Validasi ENV VARS
# =============================================================================
log STEP "[1/5] Validasi konfigurasi..."

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
# STEP 2 - Cek dependensi + LOG VERSI (v4: untuk diagnosis)
# =============================================================================
log STEP "[2/5] Memeriksa dependensi dan versi..."

for CMD in pg_dump pg_restore psql gzip rclone; do
    if ! command -v "$CMD" &>/dev/null; then
        log ERROR "Command tidak ditemukan: $CMD"
        exit 1
    fi
done

# [FIX 8] Log versi semua tools untuk memudahkan diagnosis
PGDUMP_VER=$(pg_dump --version 2>&1)
PSQL_VER=$(psql --version 2>&1)
RCLONE_VER=$(rclone version 2>&1 | head -1)
GZIP_VER=$(gzip --version 2>&1 | head -1)

log INFO "pg_dump  : ${PGDUMP_VER}"
log INFO "psql     : ${PGSQL_VER:-${PSQL_VER:-$(psql --version)}}"
log INFO "rclone   : ${RCLONE_VER}"
log INFO "gzip     : ${GZIP_VER}"
log OK "Semua dependensi tersedia."

# =============================================================================
# STEP 3 - Uji koneksi database
# =============================================================================
log STEP "[3/5] Menguji koneksi ke database..."

export PGPASSWORD="$DB_PASSWORD"
export PGCONNECT_TIMEOUT="$DB_CONNECT_TIMEOUT"

CONN_TEST=$(psql \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -c "SELECT version()" \
    -tAq 2>&1)
CONN_RC=$?

if [[ $CONN_RC -ne 0 ]]; then
    log ERROR "Koneksi database GAGAL (exit code: ${CONN_RC})"
    log ERROR "Detail: ${CONN_TEST}"
    exit 1
fi
log OK "Koneksi database OK."
log INFO "Server   : $(echo "$CONN_TEST" | head -1)"

# Cek kompatibilitas versi pg_dump vs server
SERVER_VER_NUM=$(psql \
    -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -tAq -c "SHOW server_version_num;" 2>/dev/null || echo "0")
CLIENT_VER_NUM=$(pg_dump --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 | awk -F. '{printf "%d%04d", $1, $2}')
SERVER_MAJOR=$(echo "$SERVER_VER_NUM" | cut -c1-2)
CLIENT_MAJOR=$(pg_dump --version 2>/dev/null | grep -oE '[0-9]+' | head -1)

log INFO "Server version_num : ${SERVER_VER_NUM}"
log INFO "Client pg_dump major: ${CLIENT_MAJOR}"
log INFO "Server major       : ${SERVER_MAJOR}"

if [[ "$CLIENT_MAJOR" -lt "$SERVER_MAJOR" ]]; then
    log ERROR "VERSION MISMATCH: pg_dump v${CLIENT_MAJOR} < server v${SERVER_MAJOR}"
    log ERROR "Rebuild image dengan: --build-arg PG_MAJOR=${SERVER_MAJOR}"
    exit 1
fi
log OK "Versi pg_dump kompatibel (client: v${CLIENT_MAJOR}, server major: v${SERVER_MAJOR})."

# =============================================================================
# STEP 4 - pg_dump -> gzip (DUA LANGKAH TERPISAH)
# [FIX 7] stderr pg_dump ditampilkan langsung ke stdout DAN log file
# [FIX 9] Tambah keepalive & timeout di connection string pg_dump
# =============================================================================
log STEP "[4/5] Menjalankan pg_dump..."
log INFO "Output SQL : ${DUMP_SQL}"
log INFO "Output GZ  : ${DUMP_GZ}"
log INFO "Keepalives : idle=${DB_KEEPALIVES_IDLE}s interval=${DB_KEEPALIVES_INTERVAL}s count=${DB_KEEPALIVES_COUNT}"

# Build DSN string dengan keepalive parameters
# Ini mencegah firewall/NAT memutus koneksi idle saat dump data besar
PG_DSN="host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD} connect_timeout=${DB_CONNECT_TIMEOUT} keepalives=${DB_KEEPALIVES} keepalives_idle=${DB_KEEPALIVES_IDLE} keepalives_interval=${DB_KEEPALIVES_INTERVAL} keepalives_count=${DB_KEEPALIVES_COUNT} tcp_user_timeout=${DB_TCP_USER_TIMEOUT}"

log INFO "Menjalankan pg_dump (format plain, dengan keepalive)..."

# [FIX 7] Gunakan process substitution untuk tampilkan stderr ke stdout sekaligus tulis ke log
# Sebelumnya: 2>> "$LOG_FILE" -- error tersembunyi di log file, tidak tampil ke console
pg_dump \
    -d "${PG_DSN}" \
    --format=plain \
    --no-owner \
    --no-acl \
    --verbose \
    -f "$DUMP_SQL" \
    2> >(tee -a "$LOG_FILE" >&2)
DUMP_RC=$?

if [[ $DUMP_RC -ne 0 ]]; then
    log ERROR "pg_dump GAGAL dengan exit code: ${DUMP_RC}"
    log ERROR "=== TAIL LOG ERROR ==="
    tail -20 "$LOG_FILE" | tee -a "$LOG_FILE"
    cleanup failed
    exit 1
fi

# Validasi file SQL tidak kosong
if [[ ! -f "$DUMP_SQL" ]]; then
    log ERROR "File SQL tidak ditemukan setelah pg_dump: ${DUMP_SQL}"
    cleanup failed
    exit 1
fi

DUMP_SQL_SIZE=$(stat -c%s "$DUMP_SQL" 2>/dev/null || echo 0)
if [[ "$DUMP_SQL_SIZE" -lt 100 ]]; then
    log ERROR "File SQL terlalu kecil (${DUMP_SQL_SIZE} bytes) - dump kemungkinan kosong/gagal."
    cleanup failed
    exit 1
fi
log OK "pg_dump selesai. Ukuran SQL: $(format_size $DUMP_SQL)"

# --- Kompres dengan gzip ---
log INFO "Mengkompresi dengan gzip level ${COMPRESS_LEVEL}..."

gzip -"${COMPRESS_LEVEL}" -c "$DUMP_SQL" > "$DUMP_GZ"
GZIP_RC=$?

if [[ $GZIP_RC -ne 0 ]]; then
    log ERROR "gzip GAGAL dengan exit code: ${GZIP_RC}"
    cleanup failed
    exit 1
fi

if [[ ! -f "$DUMP_GZ" ]]; then
    log ERROR "File GZ tidak ditemukan setelah gzip: ${DUMP_GZ}"
    cleanup failed
    exit 1
fi

DUMP_GZ_SIZE=$(stat -c%s "$DUMP_GZ" 2>/dev/null || echo 0)
if [[ "$DUMP_GZ_SIZE" -lt 50 ]]; then
    log ERROR "File GZ terlalu kecil (${DUMP_GZ_SIZE} bytes) - gzip gagal."
    cleanup failed
    exit 1
fi
log OK "Kompresi selesai. Ukuran GZ: $(format_size $DUMP_GZ)"

rm -f "$DUMP_SQL"
log INFO "File SQL sementara dihapus."

# =============================================================================
# STEP 5 - Upload ke Cloudflare R2
# =============================================================================
log STEP "[5/5] Mengupload ke Cloudflare R2..."
log INFO "Bucket   : ${R2_BUCKET}"
log INFO "Prefix   : ${R2_PREFIX}"
log INFO "File     : ${DUMP_FILENAME}"
log INFO "Endpoint : https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

export RCLONE_CONFIG_R2_TYPE="s3"
export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_REGION="auto"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"
export RCLONE_CONFIG_R2_ACL="private"

rclone copy \
    "$DUMP_GZ" \
    "R2:${R2_BUCKET}/${R2_PREFIX}/" \
    --s3-chunk-size=64M \
    --s3-upload-concurrency=4 \
    --retries=5 \
    --retries-sleep=15s \
    --log-level=INFO \
    --stats=30s \
    --progress \
    2>&1 | tee -a "$LOG_FILE"
UPLOAD_RC=${PIPESTATUS[0]}

if [[ $UPLOAD_RC -ne 0 ]]; then
    log ERROR "rclone upload GAGAL dengan exit code: ${UPLOAD_RC}"
    log ERROR "Cek log lengkap: ${LOG_FILE}"
    exit 1
fi

log OK "Upload berhasil ke r2://${R2_DEST}"

# Verifikasi file ada di R2
log INFO "Verifikasi file di R2..."
VERIFY=$(rclone lsf "R2:${R2_BUCKET}/${R2_PREFIX}/" --include "${DUMP_FILENAME}" 2>&1)
VERIFY_RC=$?
if [[ $VERIFY_RC -ne 0 || -z "$VERIFY" ]]; then
    log WARN "Verifikasi R2 tidak berhasil konfirmasi file (non-fatal): ${VERIFY}"
else
    log OK "Verifikasi R2: file ${DUMP_FILENAME} ditemukan di bucket."
fi

cleanup success
log OK "File lokal dibersihkan."

# =============================================================================
# RETENTION
# =============================================================================
if [[ "${RETENTION_DAYS}" -gt 0 ]]; then
    log INFO "Menerapkan retensi: hapus file lebih dari ${RETENTION_DAYS} hari di R2..."
    rclone delete \
        "R2:${R2_BUCKET}/${R2_PREFIX}/" \
        --min-age="${RETENTION_DAYS}d" \
        --log-level=INFO \
        2>&1 | tee -a "$LOG_FILE"
    RETAIN_RC=${PIPESTATUS[0]}
    if [[ $RETAIN_RC -ne 0 ]]; then
        log WARN "Retention cleanup gagal (non-fatal)."
    else
        log OK "Retention cleanup selesai (hapus file > ${RETENTION_DAYS} hari)."
    fi
fi

# =============================================================================
# SELESAI
# =============================================================================
log STEP "============================================================"
log STEP "  SELESAI SUKSES"
log STEP "  File    : ${DUMP_FILENAME}"
log STEP "  Lokasi  : r2://${R2_DEST}"
log STEP "  Log     : ${LOG_FILE}"
log STEP "============================================================"

exit 0
