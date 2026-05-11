#!/usr/bin/env bash
# =============================================================================
# pg_dump_to_r2.sh v3
# PostgreSQL Dump -> gzip -> Upload ke Cloudflare R2 / S3 Object Storage
# Repo : ghcr.io/abilfida/toolsh/pg-dump-to-r2
#
# CHANGELOG v3:
#   [FIX 1] Hapus set -e, ganti explicit exit code check per step
#           Mencegah silent exit tanpa log saat pipe gagal
#   [FIX 2] Pisah pg_dump dan gzip (tidak pipe) agar exit code terbaca benar
#           PIPESTATUS tidak reliable dengan set -e aktif
#   [FIX 3] rclone named remote via RCLONE_CONFIG_R2_* env vars
#           Inline syntax ":s3,..." tidak reliable untuk Cloudflare R2
#   [FIX 4] cleanup() dipanggil MANUAL setelah upload sukses
#           trap EXIT menyebabkan file terhapus sebelum upload jalan
#   [FIX 5] Validasi file size setelah dump dan setelah gzip
#   [FIX 6] DUMP_DIR default /backup (bukan /tmp) agar persist di container
# =============================================================================

# JANGAN pakai set -e — menyebabkan silent exit saat pipe gagal
# Gunakan explicit exit code check di setiap step
set -uo pipefail

# =============================================================================
# KONFIGURASI — semua dari ENV VAR
# =============================================================================

# --- DATABASE ---
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-postgres}"

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
# CLEANUP — dipanggil MANUAL, BUKAN via trap EXIT
# [FIX 4] trap EXIT adalah root cause file terhapus sebelum upload
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

# Trap HANYA untuk signal kill/interrupt — BUKAN EXIT
trap 'log WARN "Script dihentikan paksa (INT/TERM)."; cleanup failed; exit 130' INT TERM

# =============================================================================
# INISIALISASI
# =============================================================================
mkdir -p "$DUMP_DIR"
touch "$LOG_FILE"

log STEP "============================================================"
log STEP "  PG Dump to R2 | ghcr.io/abilfida/toolsh/pg-dump-to-r2 v3"
log STEP "  Database : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log STEP "  Tujuan   : r2://${R2_DEST}"
log STEP "  Log      : ${LOG_FILE}"
log STEP "  Dump Dir : ${DUMP_DIR}"
log STEP "============================================================"

# =============================================================================
# STEP 1 — Validasi ENV VARS
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
# STEP 2 — Cek dependensi
# =============================================================================
log STEP "[2/5] Memeriksa dependensi..."

for CMD in pg_dump gzip rclone psql; do
    if ! command -v "$CMD" &>/dev/null; then
        log ERROR "Command tidak ditemukan: $CMD"
        exit 1
    fi
    log INFO "  OK: $CMD -> $(command -v $CMD)"
done
log OK "Semua dependensi tersedia."

# =============================================================================
# STEP 3 — Uji koneksi database
# =============================================================================
log STEP "[3/5] Menguji koneksi ke database..."

export PGPASSWORD="$DB_PASSWORD"

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
log INFO "Server: $(echo "$CONN_TEST" | head -1)"

# =============================================================================
# STEP 4 — pg_dump -> gzip (DUA LANGKAH TERPISAH)
# [FIX 2] Tidak pakai pipe pg_dump | gzip agar exit code masing-masing terbaca
# [FIX 1] Tidak pakai set -e sehingga kita bisa cek $? setelah setiap command
# =============================================================================
log STEP "[4/5] Menjalankan pg_dump..."
log INFO "Output SQL : ${DUMP_SQL}"
log INFO "Output GZ  : ${DUMP_GZ}"

# --- 4a. pg_dump ke file SQL plain ---
log INFO "Menjalankan pg_dump (format plain)..."

pg_dump \
    -h "$DB_HOST" \
    -p "$DB_PORT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    --format=plain \
    --no-owner \
    --no-acl \
    --verbose \
    -f "$DUMP_SQL" \
    2>> "$LOG_FILE"
DUMP_RC=$?

if [[ $DUMP_RC -ne 0 ]]; then
    log ERROR "pg_dump GAGAL dengan exit code: ${DUMP_RC}"
    log ERROR "Lihat log lengkap: ${LOG_FILE}"
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
    log ERROR "File SQL terlalu kecil (${DUMP_SQL_SIZE} bytes) — dump kemungkinan kosong/gagal."
    cleanup failed
    exit 1
fi
log OK "pg_dump selesai. Ukuran SQL: $(format_size $DUMP_SQL)"

# --- 4b. Kompres dengan gzip ---
log INFO "Mengkompresi dengan gzip level ${COMPRESS_LEVEL}..."

gzip -"${COMPRESS_LEVEL}" -c "$DUMP_SQL" > "$DUMP_GZ"
GZIP_RC=$?

if [[ $GZIP_RC -ne 0 ]]; then
    log ERROR "gzip GAGAL dengan exit code: ${GZIP_RC}"
    cleanup failed
    exit 1
fi

# Validasi file GZ tidak kosong
if [[ ! -f "$DUMP_GZ" ]]; then
    log ERROR "File GZ tidak ditemukan setelah gzip: ${DUMP_GZ}"
    cleanup failed
    exit 1
fi

DUMP_GZ_SIZE=$(stat -c%s "$DUMP_GZ" 2>/dev/null || echo 0)
if [[ "$DUMP_GZ_SIZE" -lt 50 ]]; then
    log ERROR "File GZ terlalu kecil (${DUMP_GZ_SIZE} bytes) — gzip gagal."
    cleanup failed
    exit 1
fi
log OK "Kompresi selesai. Ukuran GZ: $(format_size $DUMP_GZ)"

# Hapus SQL setelah berhasil dikompres
rm -f "$DUMP_SQL"
log INFO "File SQL sementara dihapus."

# =============================================================================
# STEP 5 — Upload ke Cloudflare R2 via rclone named remote
# [FIX 3] Gunakan RCLONE_CONFIG_R2_* env vars (named remote "R2")
#         Bukan inline syntax ":s3,..." yang tidak reliable untuk R2
# =============================================================================
log STEP "[5/5] Mengupload ke Cloudflare R2..."
log INFO "Bucket   : ${R2_BUCKET}"
log INFO "Prefix   : ${R2_PREFIX}"
log INFO "File     : ${DUMP_FILENAME}"
log INFO "Endpoint : https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Konfigurasi rclone named remote "R2" via environment variables
# Cara resmi rclone — tidak butuh file rclone.conf
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
    # Jangan hapus file GZ agar bisa di-retry manual
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

# Hapus file GZ lokal setelah upload sukses
cleanup success
log OK "File lokal dibersihkan."

# =============================================================================
# RETENTION — hapus file lama di R2
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
        log WARN "Retention cleanup gagal (non-fatal), proses tetap dianggap sukses."
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
