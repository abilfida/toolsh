#!/bin/bash

# Script untuk setup swap 2GB dan swappiness 60
# Pastikan dijalankan dengan sudo/root

set -e

echo "=== Setup Swap 2GB dan Swappiness 60 ==="

# Check apakah swap sudah ada
if [ -f /swapfile ]; then
    echo "Warning: /swapfile sudah ada. Menghapus swap lama..."
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile
fi

# Buat swap file 2GB
echo "Membuat swap file 2GB..."
sudo fallocate -l 2G /swapfile

# Set permission yang aman
echo "Mengatur permission..."
sudo chmod 600 /swapfile

# Format sebagai swap
echo "Format swap file..."
sudo mkswap /swapfile

# Aktifkan swap
echo "Mengaktifkan swap..."
sudo swapon /swapfile

# Tambahkan ke /etc/fstab agar persistent
if ! grep -q "/swapfile" /etc/fstab; then
    echo "Menambahkan ke /etc/fstab..."
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# Set swappiness ke 60
echo "Mengatur swappiness ke 60..."
sudo sysctl vm.swappiness=60

# Buat persistent di /etc/sysctl.conf
if grep -q "^vm.swappiness" /etc/sysctl.conf; then
    sudo sed -i 's/^vm.swappiness.*/vm.swappiness=60/' /etc/sysctl.conf
else
    echo 'vm.swappiness=60' | sudo tee -a /etc/sysctl.conf
fi

# Verifikasi
echo ""
echo "=== Status Swap ==="
sudo swapon --show
echo ""
echo "=== Memory Info ==="
free -h
echo ""
echo "=== Swappiness Value ==="
cat /proc/sys/vm/swappiness

echo ""
echo "Setup selesai! Swap 2GB telah aktif dengan swappiness 60"
