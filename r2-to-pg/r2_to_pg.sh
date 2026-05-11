#!/usr/bin/env bash
# =============================================================================
# r2_to_pg.sh v1
# Cloudflare R2 / S3 Object Storage -> gunzip -> PostgreSQL restore
# Repo : ghcr.io/abilfida/toolsh/r2-to-pg
#
# FORMAT KOMPATIBEL DENGAN pg-dump-to-r2 v5:
# rclone cat -> gunzip -c -> psql
# =============================================================================

set -uo pipefail

# =============================================================================
# KONFIGURASI - semua dari ENV VAR
# =============================================================================

# --- DATABASE TARGET ---
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-postgres}"
DB_ADMIN_DB="${DB_ADMIN_DB:-postgres}"

# --- TCP KEEPALIVE & TIMEOUT ---
DB_CONNECT_TIMEOUT="${DB_CONNECT_TIMEOUT:-30}"

# --- CLOUDFLARE R2 ---
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
R2_BUCKET="${R2_BUCKET:-}"
R2_PREFIX="${R2_PREFIX:-pg-backups}"
R2_OBJECT="${R2_OBJECT:-}"

# --- OPSI RESTORE ---
CLEAN_BEFORE_RESTORE="${CLEAN_BEFORE_RESTORE:-true}"
CREATE_DB_IF_NOT_EXISTS="${CREATE_DB_IF_NOT_EXISTS:-true}"
POST_RESTORE_ANALYZE="${POST_RESTORE_ANALYZE:-false}"

# =============================================================================
# INTERNAL VARS
# =============================================================================

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/r2_to_pg_${TIMESTAMP}.log"
PIPE_STATUS_FILE="/tmp/r2_to_pg_pipe_status_${TIMESTAMP}"
RESTORE_OBJECT=""
RESTORE_SOURCE=""

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

cleanup() {
  rm -f "${PIPE_STATUS_FILE}_rclone"
  rm -f "${PIPE_STATUS_FILE}_gunzip"
  rm -f "${PIPE_STATUS_FILE}_psql"
}

trap 'log WARN "Script dihentikan paksa (INT/TERM)."; cleanup; exit 130' INT TERM

# =============================================================================
# INISIALISASI
# =============================================================================

touch "$LOG_FILE"

log STEP "============================================================"
log STEP " R2 to PG | ghcr.io/abilfida/toolsh/r2-to-pg v1"
log STEP " Mode     : STREAMING RESTORE (zero temp file)"
log STEP " Database : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log STEP " Prefix   : r2://${R2_BUCKET}/${R2_PREFIX}/"
log STEP " Log      : ${LOG_FILE}"
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

if [[ "$MISSING" -eq 1 ]]; then
  log ERROR "Konfigurasi tidak lengkap. Script berhenti."
  exit 1
fi

log OK "Semua konfigurasi valid."

# =============================================================================
# STEP 2 - Dependensi + konfigurasi rclone
# =============================================================================

log STEP "[2/5] Memeriksa dependensi dan menyiapkan R2..."

for CMD in psql dropdb createdb gunzip rclone; do
  if ! command -v "$CMD" &>/dev/null; then
    log ERROR "Command tidak ditemukan: $CMD"
    exit 1
  fi
done

export RCLONE_CONFIG_R2_TYPE="s3"
export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_REGION="auto"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"
export RCLONE_CONFIG_R2_ACL="private"

log INFO "psql   : $(psql --version 2>&1)"
log INFO "rclone : $(rclone version 2>&1 | head -1)"
log INFO "gunzip : $(gunzip --version 2>&1 | head -1)"
log OK "Semua dependensi tersedia."

# =============================================================================
# STEP 3 - Tentukan object backup di R2
# =============================================================================

log STEP "[3/5] Menentukan file backup dari R2..."

if [[ -n "$R2_OBJECT" ]]; then
  RESTORE_OBJECT="$R2_OBJECT"
  log INFO "Menggunakan object explicit dari ENV: ${RESTORE_OBJECT}"
else
  RESTORE_OBJECT="$(
    rclone lsf "R2:${R2_BUCKET}/${R2_PREFIX}/" \
      --files-only \
      --include "*.dump.gz" \
      2>>"$LOG_FILE" \
    | sort \
    | tail -1
  )"

  if [[ -z "$RESTORE_OBJECT" ]]; then
    log ERROR "Tidak ditemukan file *.dump.gz di R2:${R2_BUCKET}/${R2_PREFIX}/"
    exit 1
  fi

  log INFO "Auto-select object terbaru: ${RESTORE_OBJECT}"
fi

RESTORE_SOURCE="R2:${R2_BUCKET}/${R2_PREFIX}/${RESTORE_OBJECT}"

if ! rclone lsf "$RESTORE_SOURCE" >>"$LOG_FILE" 2>&1; then
  log ERROR "Object tidak ditemukan / tidak bisa diakses: ${RESTORE_SOURCE}"
  exit 1
fi

log OK "Source restore valid: r2://${R2_BUCKET}/${R2_PREFIX}/${RESTORE_OBJECT}"

# =============================================================================
# STEP 4 - Siapkan database target
# =============================================================================

log STEP "[4/5] Memeriksa koneksi DB dan menyiapkan target..."

export PGPASSWORD="$DB_PASSWORD"
export PGCONNECT_TIMEOUT="$DB_CONNECT_TIMEOUT"

CONN_TEST=$(
  psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_ADMIN_DB" \
    -tAq -c "SELECT 1" 2>&1
)
CONN_RC=$?

if [[ "$CONN_RC" -ne 0 ]]; then
  log ERROR "Koneksi database GAGAL (exit: ${CONN_RC}): ${CONN_TEST}"
  exit 1
fi

log OK "Koneksi database OK."

DB_EXISTS=$(
  psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_ADMIN_DB" \
    -tAq \
    -v dbname="$DB_NAME" \
    -c "SELECT 1 FROM pg_database WHERE datname = :'dbname';" \
    2>>"$LOG_FILE"
)

if [[ "$CLEAN_BEFORE_RESTORE" == "true" ]]; then
  log INFO "Mode restore: CLEAN_BEFORE_RESTORE=true"

  if [[ "$DB_EXISTS" == "1" ]]; then
    log INFO "Memutus semua koneksi aktif ke database ${DB_NAME}..."
    psql \
      -h "$DB_HOST" -p "$DB_PORT" \
      -U "$DB_USER" -d "$DB_ADMIN_DB" \
      -v ON_ERROR_STOP=1 \
      -v dbname="$DB_NAME" \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'dbname' AND pid <> pg_backend_pid();" \
      >>"$LOG_FILE" 2>&1 || {
        log ERROR "Gagal terminate koneksi aktif ke ${DB_NAME}"
        exit 1
      }

    log INFO "Drop database ${DB_NAME}..."
    dropdb \
      -h "$DB_HOST" -p "$DB_PORT" \
      -U "$DB_USER" \
      "$DB_NAME" >>"$LOG_FILE" 2>&1 || {
        log ERROR "dropdb gagal untuk ${DB_NAME}"
        exit 1
      }
  fi

  log INFO "Create database ${DB_NAME}..."
  createdb \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" \
    "$DB_NAME" >>"$LOG_FILE" 2>&1 || {
      log ERROR "createdb gagal untuk ${DB_NAME}"
      exit 1
    }

  log OK "Database target siap dalam mode bersih."
else
  log INFO "Mode restore: CLEAN_BEFORE_RESTORE=false"

  if [[ "$DB_EXISTS" != "1" ]]; then
    if [[ "$CREATE_DB_IF_NOT_EXISTS" == "true" ]]; then
      log INFO "Database belum ada, membuat ${DB_NAME}..."
      createdb \
        -h "$DB_HOST" -p "$DB_PORT" \
        -U "$DB_USER" \
        "$DB_NAME" >>"$LOG_FILE" 2>&1 || {
          log ERROR "createdb gagal untuk ${DB_NAME}"
          exit 1
        }
    else
      log ERROR "Database ${DB_NAME} belum ada dan CREATE_DB_IF_NOT_EXISTS=false"
      exit 1
    fi
  fi

  log OK "Database target siap tanpa drop/recreate."
fi

# =============================================================================
# STEP 5 - STREAMING RESTORE: rclone cat | gunzip | psql
# =============================================================================

log STEP "[5/5] Streaming restore: rclone cat | gunzip | psql..."
log INFO "Source : ${RESTORE_SOURCE}"
log INFO "Target : postgresql://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

RESTORE_START=$(date +%s)

(
  rclone cat "${RESTORE_SOURCE}" \
    --retries=5 \
    --retries-sleep=15s \
    --log-level=INFO \
    --stats=60s \
    2>&1 | tee -a "$LOG_FILE"
  echo ${PIPESTATUS[0]} > "${PIPE_STATUS_FILE}_rclone"
) | (
  gunzip -c
  echo $? > "${PIPE_STATUS_FILE}_gunzip"
) | (
  psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    2> >(tee -a "$LOG_FILE" >&2)
  echo $? > "${PIPE_STATUS_FILE}_psql"
)

PIPELINE_RC=$?
RESTORE_END=$(date +%s)
RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))

RCLONE_RC=$(cat "${PIPE_STATUS_FILE}_rclone" 2>/dev/null || echo "99")
GUNZIP_RC=$(cat "${PIPE_STATUS_FILE}_gunzip" 2>/dev/null || echo "99")
PSQL_RC=$(cat "${PIPE_STATUS_FILE}_psql" 2>/dev/null || echo "99")

log INFO "Durasi restore: ${RESTORE_DURATION} detik"
log INFO "Exit codes: rclone=${RCLONE_RC} | gunzip=${GUNZIP_RC} | psql=${PSQL_RC}"

FAIL=0
if [[ "$RCLONE_RC" -ne 0 ]]; then
  log ERROR "rclone GAGAL (exit: ${RCLONE_RC})"
  FAIL=1
fi
if [[ "$GUNZIP_RC" -ne 0 ]]; then
  log ERROR "gunzip GAGAL (exit: ${GUNZIP_RC})"
  FAIL=1
fi
if [[ "$PSQL_RC" -ne 0 ]]; then
  log ERROR "psql restore GAGAL (exit: ${PSQL_RC})"
  FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
  log ERROR "Restore pipeline GAGAL. Cek log: ${LOG_FILE}"
  cleanup
  exit 1
fi

log OK "Streaming restore selesai sukses."

if [[ "$POST_RESTORE_ANALYZE" == "true" ]]; then
  log INFO "Menjalankan VACUUM ANALYZE..."
  psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    -c "VACUUM ANALYZE;" >>"$LOG_FILE" 2>&1 || {
      log WARN "VACUUM ANALYZE gagal (non-fatal)."
    }
fi

cleanup

log STEP "============================================================"
log STEP " RESTORE SELESAI SUKSES"
log STEP " File   : ${RESTORE_OBJECT}"
log STEP " Source : r2://${R2_BUCKET}/${R2_PREFIX}/${RESTORE_OBJECT}"
log STEP " Target : postgresql://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log STEP " Durasi : ${RESTORE_DURATION} detik"
log STEP " Log    : ${LOG_FILE}"
log STEP "============================================================"

exit 0
