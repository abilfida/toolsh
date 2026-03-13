#!/bin/bash

# ==================================================
# Script: setup-domain-ssl.sh
# Deskripsi: Pointing domain ke Nginx + Install SSL Let's Encrypt
# Usage: sudo bash setup-domain-ssl.sh <domain> <email> [port]
# Contoh: sudo bash setup-domain-ssl.sh myapp.com admin@myapp.com 3000
# ==================================================

set -e

# ---- Warna output ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---- Validasi argumen ----
if [ -z "$1" ] || [ -z "$2" ]; then
  echo -e "${RED}[ERROR] Usage: sudo bash $0 <domain> <email> [port]${NC}"
  echo -e "  Contoh: sudo bash $0 myapp.com admin@myapp.com 3000"
  exit 1
fi

DOMAIN=$1
EMAIL=$2
PORT=${3:-80}           # default port app = 80 (static file), bisa diganti ke port app (misal 3000)
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
WEBROOT="/var/www/$DOMAIN/html"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Domain  : $DOMAIN${NC}"
echo -e "${CYAN}  Email   : $EMAIL${NC}"
echo -e "${CYAN}  App Port: $PORT${NC}"
echo -e "${CYAN}========================================${NC}"

# ---- Cek root ----
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Jalankan script ini sebagai root atau dengan sudo${NC}"
  exit 1
fi

# ---- 1. Update & Install Nginx ----
echo -e "\n${YELLOW}[1/6] Install/Update Nginx...${NC}"
apt-get update -qq
apt-get install -y nginx

systemctl enable nginx
systemctl start nginx
echo -e "${GREEN}[✓] Nginx aktif${NC}"

# ---- 2. Buat Web Root ----
echo -e "\n${YELLOW}[2/6] Membuat web root: $WEBROOT${NC}"
mkdir -p "$WEBROOT"
cat > "$WEBROOT/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>$DOMAIN</title></head>
<body><h1>$DOMAIN is live!</h1></body>
</html>
EOF
chown -R www-data:www-data "/var/www/$DOMAIN"
echo -e "${GREEN}[✓] Web root siap${NC}"

# ---- 3. Buat Nginx Server Block ----
echo -e "\n${YELLOW}[3/6] Membuat konfigurasi Nginx untuk $DOMAIN...${NC}"

# Deteksi: jika port bukan 80, gunakan reverse proxy
if [ "$PORT" -eq 80 ]; then
  # Static file / web root biasa
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root $WEBROOT;
    index index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Untuk verifikasi certbot
    location ~ /.well-known/acme-challenge {
        allow all;
        root $WEBROOT;
    }
}
EOF
else
  # Reverse proxy ke aplikasi di port tertentu
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;

    location / {
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # Untuk verifikasi certbot
    location ~ /.well-known/acme-challenge {
        allow all;
        root /var/www/html;
    }
}
EOF
fi

# Aktifkan konfigurasi
ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

# Hapus default jika ada
if [ -f /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default
  echo -e "${YELLOW}[!] Konfigurasi default Nginx dihapus${NC}"
fi

# Test & reload nginx
nginx -t && systemctl reload nginx
echo -e "${GREEN}[✓] Nginx konfigurasi berhasil${NC}"

# ---- 4. Install Certbot ----
echo -e "\n${YELLOW}[4/6] Install Certbot...${NC}"
apt-get install -y certbot python3-certbot-nginx
echo -e "${GREEN}[✓] Certbot terinstall${NC}"

# ---- 5. Request SSL Certificate ----
echo -e "\n${YELLOW}[5/6] Mengambil SSL certificate untuk $DOMAIN...${NC}"
certbot --nginx \
  -d "$DOMAIN" \
  -d "www.$DOMAIN" \
  --email "$EMAIL" \
  --agree-tos \
  --non-interactive \
  --redirect
echo -e "${GREEN}[✓] SSL berhasil dipasang! HTTPS aktif untuk $DOMAIN${NC}"

# ---- 6. Setup Auto-Renewal (Cron) ----
echo -e "\n${YELLOW}[6/6] Setup auto-renewal SSL...${NC}"

# Cek apakah cron renewal sudah ada
CRON_JOB="0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"
( crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_JOB" ) | crontab -

# Test dry-run renewal
certbot renew --dry-run
echo -e "${GREEN}[✓] Auto-renewal aktif (setiap hari jam 03:00)${NC}"

# ---- Done ----
echo -e "\n${CYAN}========================================${NC}"
echo -e "${GREEN}  SETUP SELESAI!${NC}"
echo -e "${CYAN}  Domain : https://$DOMAIN${NC}"
echo -e "${CYAN}  WWW    : https://www.$DOMAIN${NC}"
echo -e "${CYAN}  SSL    : Let's Encrypt (auto-renew aktif)${NC}"
echo -e "${CYAN}========================================${NC}"
