#!/usr/bin/env bash
# =============================================================================
# pg_clone.sh
# Clone seluruh data PostgreSQL dari server ORIGIN ke server CLONE (lokal).
# Script dijalankan dari server CLONE, menembak langsung ke server ORIGIN.
# =============================================================================

set -euo pipefail

# =============================================================================
# KONFIGURASI KONEKSI DATABASE
# Sesuaikan variabel berikut sebelum menjalankan script.
# =============================================================================

# --- SERVER ORIGIN (source) ---
ORIGIN_HOST="192.168.1.100"        # IP / hostname server origin
ORIGIN_PORT="5432"                  # Port PostgreSQL origin
ORIGIN_USER="postgres"              # User PostgreSQL origin
ORIGIN_PASSWORD="yourpassword"      # Password PostgreSQL origin
ORIGIN_DB="yourdb"                  # Nama database yang akan di-clone

# --- SERVER CLONE / LOKAL (destination) ---
CLONE_HOST="127.0.0.1"             # IP / hostname server clone (lokal)
CLONE_PORT="5432"                   # Port PostgreSQL clone
CLONE_USER="postgres"               # User PostgreSQL clone
CLONE_PASSWORD="yourpassword"       # Password PostgreSQL clone
CLONE_DB="yourdb_clone"             # Nama database tujuan di server clone

# =============================================================================
# KONFIGURASI TAMBAHAN
# =============================================================================

DUMP_FILE="/tmp/pg_clone_dump_$(date +%Y%m%d_%H%M%S).dump"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
LOG_FILE="/tmp/pg_clone_$(date +%Y%m%d_%H%M%S).log"
DROP_AND_RECREATE=true              # true = drop & recreate DB tujuan sebelum restore

# Gunakan warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# FUNGSI HELPER
# =============================================================================

log() {
    local level="$1"
    local message="$2"
    local color="$NC"
    case "$level" in
        INFO)  color="$CYAN"   ;;
        OK)    color="$GREEN"  ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED"    ;;
        STEP)  color="$BLUE"   ;;
    esac
    local line="[$TIMESTAMP] [$level] $message"
    echo -e "${color}${line}${NC}" | tee -a "$LOG_FILE"
}

check_dependency() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log ERROR "Command '$cmd' tidak ditemukan. Install terlebih dahulu."
        exit 1
    fi
}

cleanup() {
    if [[ -f "$DUMP_FILE" ]]; then
        log INFO "Membersihkan file dump sementara: $DUMP_FILE"
        rm -f "$DUMP_FILE"
    fi
}

# Eksekusi query ke server ORIGIN
origin_psql() {
    PGPASSWORD="$ORIGIN_PASSWORD" psql \
        -h "$ORIGIN_HOST" \
        -p "$ORIGIN_PORT" \
        -U "$ORIGIN_USER" \
        -d "postgres" \
        -c "$1" \
        --no-password \
        -q 2>>"$LOG_FILE"
}

# Eksekusi query ke server CLONE
clone_psql() {
    PGPASSWORD="$CLONE_PASSWORD" psql \
        -h "$CLONE_HOST" \
        -p "$CLONE_PORT" \
        -U "$CLONE_USER" \
        -d "postgres" \
        -c "$1" \
        --no-password \
        -q 2>>"$LOG_FILE"
}

# =============================================================================
# VALIDASI AWAL
# =============================================================================

trap cleanup EXIT

log STEP "============================================================"
log STEP "  PostgreSQL Clone Script"
log STEP "  Sumber  : $ORIGIN_USER@$ORIGIN_HOST:$ORIGIN_PORT/$ORIGIN_DB"
log STEP "  Tujuan  : $CLONE_USER@$CLONE_HOST:$CLONE_PORT/$CLONE_DB"
log STEP "  Log     : $LOG_FILE"
log STEP "============================================================"

log INFO "Memeriksa dependensi..."
check_dependency pg_dump
check_dependency pg_restore
check_dependency psql

# =============================================================================
# CEK KONEKSI ORIGIN
# =============================================================================

log INFO "Menguji koneksi ke server ORIGIN ($ORIGIN_HOST:$ORIGIN_PORT)..."
if ! PGPASSWORD="$ORIGIN_PASSWORD" pg_isready \
    -h "$ORIGIN_HOST" \
    -p "$ORIGIN_PORT" \
    -U "$ORIGIN_USER" \
    -d "$ORIGIN_DB" \
    -q 2>>"$LOG_FILE"; then
    log ERROR "Tidak dapat terhubung ke server ORIGIN. Periksa koneksi / kredensial."
    exit 1
fi
log OK "Koneksi ke server ORIGIN berhasil."

# =============================================================================
# CEK KONEKSI CLONE (LOKAL)
# =============================================================================

log INFO "Menguji koneksi ke server CLONE ($CLONE_HOST:$CLONE_PORT)..."
if ! PGPASSWORD="$CLONE_PASSWORD" pg_isready \
    -h "$CLONE_HOST" \
    -p "$CLONE_PORT" \
    -U "$CLONE_USER" \
    -q 2>>"$LOG_FILE"; then
    log ERROR "Tidak dapat terhubung ke server CLONE. Periksa koneksi / kredensial."
    exit 1
fi
log OK "Koneksi ke server CLONE berhasil."

# =============================================================================
# KONFIRMASI SEBELUM EKSEKUSI
# =============================================================================

if [[ "${DROP_AND_RECREATE}" == "true" ]]; then
    log WARN "PERHATIAN: Database '$CLONE_DB' di server CLONE akan di-DROP dan RECREATE."
    log WARN "Seluruh data existing di '$CLONE_DB' akan HILANG permanen!"
    echo -e "${YELLOW}"
    read -rp "Ketik 'YES' untuk melanjutkan: " confirm
    echo -e "${NC}"
    if [[ "$confirm" != "YES" ]]; then
        log INFO "Operasi dibatalkan oleh user."
        exit 0
    fi
fi

# =============================================================================
# LANGKAH 1: DUMP DARI ORIGIN (Custom Format untuk performa terbaik)
# =============================================================================

log STEP "[1/4] Membuat dump dari server ORIGIN..."
log INFO "Database source : $ORIGIN_DB"
log INFO "File dump       : $DUMP_FILE"

if PGPASSWORD="$ORIGIN_PASSWORD" pg_dump \
    -h "$ORIGIN_HOST" \
    -p "$ORIGIN_PORT" \
    -U "$ORIGIN_USER" \
    -d "$ORIGIN_DB" \
    --format=custom \
    --compress=9 \
    --no-owner \
    --no-acl \
    --verbose \
    -f "$DUMP_FILE" \
    2>>"$LOG_FILE"; then
    DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
    log OK "Dump berhasil. Ukuran file: $DUMP_SIZE"
else
    log ERROR "pg_dump gagal. Periksa log: $LOG_FILE"
    exit 1
fi

# =============================================================================
# LANGKAH 2: DROP DATABASE TUJUAN (JIKA ADA)
# =============================================================================

log STEP "[2/4] Menghapus database tujuan jika ada..."

# Putuskan semua koneksi aktif ke DB tujuan sebelum drop
clone_psql "SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname = '$CLONE_DB'
              AND pid <> pg_backend_pid();" 2>>"$LOG_FILE" || true

if PGPASSWORD="$CLONE_PASSWORD" psql \
    -h "$CLONE_HOST" \
    -p "$CLONE_PORT" \
    -U "$CLONE_USER" \
    -d "postgres" \
    -c "SELECT 1 FROM pg_database WHERE datname = '$CLONE_DB'" \
    --no-password -tA 2>>"$LOG_FILE" | grep -q 1; then

    log INFO "Database '$CLONE_DB' ditemukan, menghapus..."
    if clone_psql "DROP DATABASE IF EXISTS \"$CLONE_DB\";"; then
        log OK "Database '$CLONE_DB' berhasil dihapus."
    else
        log ERROR "Gagal menghapus database '$CLONE_DB'. Periksa log."
        exit 1
    fi
else
    log INFO "Database '$CLONE_DB' belum ada, melanjutkan ke tahap berikutnya."
fi

# =============================================================================
# LANGKAH 3: BUAT DATABASE BARU DI CLONE
# =============================================================================

log STEP "[3/4] Membuat database baru '$CLONE_DB' di server CLONE..."

# Ambil encoding & locale dari database origin
ORIGIN_ENCODING=$(PGPASSWORD="$ORIGIN_PASSWORD" psql \
    -h "$ORIGIN_HOST" -p "$ORIGIN_PORT" -U "$ORIGIN_USER" \
    -d "postgres" -tA \
    -c "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = '$ORIGIN_DB';" \
    2>>"$LOG_FILE")

ORIGIN_LC_COLLATE=$(PGPASSWORD="$ORIGIN_PASSWORD" psql \
    -h "$ORIGIN_HOST" -p "$ORIGIN_PORT" -U "$ORIGIN_USER" \
    -d "postgres" -tA \
    -c "SELECT datcollate FROM pg_database WHERE datname = '$ORIGIN_DB';" \
    2>>"$LOG_FILE")

ORIGIN_LC_CTYPE=$(PGPASSWORD="$ORIGIN_PASSWORD" psql \
    -h "$ORIGIN_HOST" -p "$ORIGIN_PORT" -U "$ORIGIN_USER" \
    -d "postgres" -tA \
    -c "SELECT datctype FROM pg_database WHERE datname = '$ORIGIN_DB';" \
    2>>"$LOG_FILE")

log INFO "Encoding: $ORIGIN_ENCODING | LC_COLLATE: $ORIGIN_LC_COLLATE | LC_CTYPE: $ORIGIN_LC_CTYPE"

if clone_psql "CREATE DATABASE \"$CLONE_DB\"
               ENCODING '$ORIGIN_ENCODING'
               LC_COLLATE '$ORIGIN_LC_COLLATE'
               LC_CTYPE '$ORIGIN_LC_CTYPE'
               TEMPLATE template0
               OWNER \"$CLONE_USER\";"; then
    log OK "Database '$CLONE_DB' berhasil dibuat."
else
    log ERROR "Gagal membuat database '$CLONE_DB'. Periksa log."
    exit 1
fi

# =============================================================================
# LANGKAH 4: RESTORE KE DATABASE CLONE
# =============================================================================

log STEP "[4/4] Merestore dump ke database '$CLONE_DB' di server CLONE..."

# Jumlah jobs paralel untuk mempercepat restore (sesuaikan dengan jumlah CPU)
RESTORE_JOBS=4

if PGPASSWORD="$CLONE_PASSWORD" pg_restore \
    -h "$CLONE_HOST" \
    -p "$CLONE_PORT" \
    -U "$CLONE_USER" \
    -d "$CLONE_DB" \
    --no-owner \
    --no-acl \
    --jobs="$RESTORE_JOBS" \
    --verbose \
    "$DUMP_FILE" \
    2>>"$LOG_FILE"; then
    log OK "Restore berhasil ke database '$CLONE_DB'."
else
    # pg_restore mengembalikan exit code non-zero jika ada warning (bukan hanya error)
    log WARN "pg_restore selesai dengan beberapa warning (mungkin non-fatal). Periksa log."
fi

# =============================================================================
# VERIFIKASI JUMLAH TABEL
# =============================================================================

log INFO "Verifikasi: menghitung jumlah tabel..."

ORIGIN_TABLE_COUNT=$(PGPASSWORD="$ORIGIN_PASSWORD" psql \
    -h "$ORIGIN_HOST" -p "$ORIGIN_PORT" -U "$ORIGIN_USER" -d "$ORIGIN_DB" -tA \
    -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema') AND table_type='BASE TABLE';" \
    2>>"$LOG_FILE")

CLONE_TABLE_COUNT=$(PGPASSWORD="$CLONE_PASSWORD" psql \
    -h "$CLONE_HOST" -p "$CLONE_PORT" -U "$CLONE_USER" -d "$CLONE_DB" -tA \
    -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema') AND table_type='BASE TABLE';" \
    2>>"$LOG_FILE")

log INFO "Jumlah tabel di ORIGIN : $ORIGIN_TABLE_COUNT"
log INFO "Jumlah tabel di CLONE  : $CLONE_TABLE_COUNT"

if [[ "$ORIGIN_TABLE_COUNT" -eq "$CLONE_TABLE_COUNT" ]]; then
    log OK "Verifikasi tabel: MATCH ($ORIGIN_TABLE_COUNT tabel)"
else
    log WARN "Verifikasi tabel: TIDAK MATCH (origin=$ORIGIN_TABLE_COUNT, clone=$CLONE_TABLE_COUNT). Periksa log."
fi

# =============================================================================
# SELESAI
# =============================================================================

log STEP "============================================================"
log OK "  Clone selesai!"
log OK "  Sumber  : $ORIGIN_USER@$ORIGIN_HOST:$ORIGIN_PORT/$ORIGIN_DB"
log OK "  Tujuan  : $CLONE_USER@$CLONE_HOST:$CLONE_PORT/$CLONE_DB"
log OK "  Log     : $LOG_FILE"
log STEP "============================================================"

