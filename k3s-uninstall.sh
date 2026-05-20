#!/bin/bash
# =============================================================================
# k3s-uninstall.sh
# Script untuk uninstall K3s server secara menyeluruh
# Repo: https://github.com/abilfida/toolsh
# =============================================================================

set -e

# Warna output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Wrapper read yang selalu baca dari /dev/tty
# (fix untuk curl | bash dimana stdin bukan terminal)
prompt() {
  local __var="$1"
  local __msg="$2"
  read -rp "$__msg" "$__var" </dev/tty
}

# =============================================================================
# Banner
# =============================================================================
echo ""
echo -e "${RED}============================================${NC}"
echo -e "${RED}   K3s Server Full Uninstall Script        ${NC}"
echo -e "${RED}============================================${NC}"
echo ""
print_warn "Script ini akan menghapus K3s beserta semua datanya!"
print_warn "Pastikan kamu sudah backup data penting sebelum melanjutkan."
echo ""
prompt CONFIRM "Lanjutkan uninstall? (yes/no): "
if [[ "$CONFIRM" != "yes" ]]; then
  print_info "Uninstall dibatalkan."
  exit 0
fi
echo ""

# =============================================================================
# Langkah 1: Drain & Hapus Agent Node (Opsional - Multi-Node)
# =============================================================================
echo -e "${CYAN}--- Langkah 1: Drain & Hapus Agent Node (Multi-Node) ---${NC}"
print_warn "Jika kamu menggunakan multi-node cluster, drain worker node terlebih dahulu."
print_info "Untuk melihat semua node: kubectl get nodes"
echo ""
prompt HAS_AGENTS "Apakah ada agent/worker node yang perlu di-drain? (yes/no): "

if [[ "$HAS_AGENTS" == "yes" ]]; then
  # Tampilkan daftar node
  if command -v kubectl &>/dev/null; then
    print_info "Daftar node yang tersedia:"
    kubectl get nodes 2>/dev/null || print_warn "Tidak bisa mengambil daftar node (cluster mungkin sudah tidak aktif)."
    echo ""
  fi

  prompt AGENT_NODES "Masukkan nama agent node (pisahkan dengan spasi jika lebih dari satu): "

  for NODE in $AGENT_NODES; do
    print_info "Draining node: $NODE ..."
    kubectl drain "$NODE" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force 2>/dev/null || print_warn "Gagal drain $NODE, mungkin sudah tidak aktif. Lanjut..."

    print_info "Menghapus node: $NODE dari cluster..."
    kubectl delete node "$NODE" 2>/dev/null || print_warn "Gagal delete node $NODE. Lanjut..."
    print_success "Node $NODE selesai diproses."
  done

  echo ""
  print_warn "Jangan lupa jalankan perintah berikut di setiap agent node:"
  echo -e "  ${YELLOW}/usr/local/bin/k3s-agent-uninstall.sh${NC}"
  echo ""
  prompt _PAUSE "Tekan ENTER untuk lanjut ke uninstall server..."
else
  print_info "Melewati langkah drain agent node."
fi

echo ""

# =============================================================================
# Langkah 2: Jalankan Uninstall Script Bawaan K3s
# =============================================================================
echo -e "${CYAN}--- Langkah 2: Menjalankan K3s Uninstall Script ---${NC}"

if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
  print_info "Menjalankan /usr/local/bin/k3s-uninstall.sh ..."
  /usr/local/bin/k3s-uninstall.sh
  print_success "K3s uninstall script selesai dijalankan."
else
  print_warn "File /usr/local/bin/k3s-uninstall.sh tidak ditemukan."
  print_info "Mungkin K3s belum terinstall atau sudah dihapus sebelumnya."
fi

echo ""

# =============================================================================
# Langkah 3: Bersihkan Sisa Direktori (Full Clean)
# =============================================================================
echo -e "${CYAN}--- Langkah 3: Membersihkan Sisa Direktori ---${NC}"

DIRS=(
  "/var/lib/rancher/k3s"
  "/etc/rancher/k3s"
  "/run/k3s"
  "/run/flannel"
  "/var/lib/kubelet"
  "/var/lib/cni"
)

for DIR in "${DIRS[@]}"; do
  if [[ -d "$DIR" ]]; then
    print_info "Menghapus $DIR ..."
    rm -rf "$DIR"
    print_success "$DIR dihapus."
  else
    print_info "$DIR tidak ditemukan, dilewati."
  fi
done

echo ""

# =============================================================================
# Selesai
# =============================================================================
print_success "============================================"
print_success "  K3s berhasil diuninstall secara menyeluruh!"
print_success "============================================"
echo ""
print_warn "CATATAN:"
echo "  - Script ini TIDAK menghapus data dari external datastore (misal: PostgreSQL eksternal)."
echo "  - Script ini TIDAK menghapus data dari Kubernetes Persistent Volumes yang dibuat pod."
echo ""

prompt DO_REBOOT "Lakukan reboot sekarang untuk membersihkan network interface & mount point? (yes/no): "
if [[ "$DO_REBOOT" == "yes" ]]; then
  print_info "Melakukan reboot dalam 3 detik..."
  sleep 3
  sudo reboot
else
  print_info "Reboot dilewati. Disarankan untuk reboot manual sebelum reinstall K3s."
fi
