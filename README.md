# toolsh 🛠️

Kumpulan script dan Docker image untuk persiapan, manajemen, dan otomasi server Linux.

---

## 📦 Daftar Tools

| Tool | Tipe | Deskripsi |
|------|------|-----------|
| [`setup-swap.sh`](#setup-swapsh) | Shell Script | Setup swap memory di server |
| [`setup-domain-nginx.sh`](#setup-domain-nginxsh) | Shell Script | Setup domain Nginx + SSL Let's Encrypt |
| [`pg_clone.sh`](#pg_clonesh) | Shell Script | Clone database PostgreSQL antar server via remote |
| [`pg-dump-to-r2`](#pg-dump-to-r2-docker-image) | Docker Image | Dump PostgreSQL → gzip → upload ke Cloudflare R2 / S3 |

---

## setup-swap.sh

Setup swap memory pada server Linux.

```bash
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-swap.sh | sudo bash
```

---

## setup-domain-nginx.sh

Setup pointing domain ke Nginx sebagai reverse proxy atau static file server, sekaligus install SSL otomatis via Let's Encrypt (Certbot).

**Fitur:**
- Install & konfigurasi Nginx otomatis
- Support reverse proxy ke port aplikasi
- Install SSL Let's Encrypt dengan Certbot
- Setup auto-renewal SSL via cron (setiap hari jam 03:00)

**Usage:**

```bash
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-domain-nginx.sh \
  | sudo bash -s -- <domain> <email> [port]
```

**Contoh:**

```bash
# Reverse proxy ke aplikasi di port 3000
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-domain-nginx.sh \
  | sudo bash -s -- myapp.com admin@myapp.com 3000

# Static file / web root (port 80)
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-domain-nginx.sh \
  | sudo bash -s -- myapp.com admin@myapp.com
```

| Parameter | Wajib | Keterangan |
|-----------|-------|------------|
| `domain` | ✅ | Domain yang akan di-setup (contoh: `myapp.com`) |
| `email` | ✅ | Email untuk notifikasi SSL Let's Encrypt |
| `port` | ❌ | Port aplikasi untuk reverse proxy (default: `80`) |

---

## pg_clone.sh

Clone seluruh database PostgreSQL dari server origin ke server clone melalui koneksi remote. Script dijalankan dari **server tujuan (clone)**, menembak langsung ke server sumber (origin).

**Fitur:**
- Dump otomatis dari server origin via `pg_dump` custom format
- Drop & recreate database tujuan sebelum restore
- Memutus koneksi aktif ke DB tujuan sebelum drop
- Restore paralel dengan `pg_restore --jobs`
- Verifikasi jumlah tabel setelah clone selesai
- Konfirmasi interaktif sebelum eksekusi (safety guard)

**Flow:**

```
[Server Clone] ──── pg_dump remote ───► [Server Origin]
                                               │
                          dump file ◄──────────┘
                               │
                     pg_restore (lokal)
                               │
                        DB Clone ✅
```

**Cara pakai:**

Edit variabel konfigurasi di bagian atas script, lalu jalankan:

```bash
# Download script
curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/pg_clone.sh -o pg_clone.sh
chmod +x pg_clone.sh

# Jalankan dari server clone
./pg_clone.sh
```

**Variabel konfigurasi:**

```bash
# Server Origin (sumber)
ORIGIN_HOST="192.168.1.100"
ORIGIN_PORT="5432"
ORIGIN_USER="postgres"
ORIGIN_PASSWORD="yourpassword"
ORIGIN_DB="yourdb"

# Server Clone / Lokal (tujuan)
CLONE_HOST="127.0.0.1"
CLONE_PORT="5432"
CLONE_USER="postgres"
CLONE_PASSWORD="yourpassword"
CLONE_DB="yourdb_clone"
```

> **Tips:** Untuk database besar pada koneksi remote, jalankan `pg_dump` langsung di server origin lalu transfer file dump ke server clone untuk menghindari TCP timeout.

---

## pg-dump-to-r2 (Docker Image)

Docker image untuk backup PostgreSQL secara otomatis: dump → gzip → upload ke **Cloudflare R2** atau S3-compatible Object Storage.

**Image:**

```
ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
```

**Fitur:**
- `pg_dump` streaming langsung di-pipe ke `gzip` (hemat disk)
- Upload ke Cloudflare R2 / S3 via `rclone` tanpa file konfigurasi
- TCP keepalive bawaan untuk koneksi remote yang stabil
- Retensi otomatis: hapus file backup lama di R2
- Verifikasi list file setelah upload
- Semua konfigurasi via environment variables
- Support `linux/amd64` dan `linux/arm64`

### Cara Pakai

**1. Buat file `.env`:**

```bash
cp pg-dump-to-r2/.env.example .env
# Edit .env sesuai konfigurasi
```

```env
# Database
DB_HOST=127.0.0.1
DB_PORT=5432
DB_USER=your_db_user
DB_PASSWORD=your_db_password
DB_NAME=your_db_name

# Cloudflare R2
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_ACCESS_KEY_ID=your_r2_access_key_id
R2_SECRET_ACCESS_KEY=your_r2_secret_access_key
R2_BUCKET=your-bucket-name
R2_PREFIX=pg-backups

# Opsi dump (opsional)
COMPRESS_LEVEL=9
RETENTION_DAYS=7
```

**2. Jalankan:**

```bash
docker run --rm --env-file .env --network host \
  ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
```

**Atau inline dengan `-e`:**

```bash
docker run --rm \
  -e DB_HOST=127.0.0.1 \
  -e DB_USER=myuser \
  -e DB_PASSWORD=mypassword \
  -e DB_NAME=mydb \
  -e R2_ACCOUNT_ID=xxxx \
  -e R2_ACCESS_KEY_ID=xxxx \
  -e R2_SECRET_ACCESS_KEY=xxxx \
  -e R2_BUCKET=my-bucket \
  --network host \
  ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
```

### Kubernetes CronJob

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-dump-r2-secret
  namespace: default
type: Opaque
stringData:
  DB_HOST: "127.0.0.1"
  DB_PORT: "5432"
  DB_USER: "your_db_user"
  DB_PASSWORD: "your_db_password"
  DB_NAME: "your_db_name"
  R2_ACCOUNT_ID: "your_cf_account_id"
  R2_ACCESS_KEY_ID: "your_r2_key_id"
  R2_SECRET_ACCESS_KEY: "your_r2_secret"
  R2_BUCKET: "your-bucket"
  R2_PREFIX: "pg-backups"
  RETENTION_DAYS: "7"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-dump-to-r2
  namespace: default
spec:
  schedule: "0 2 * * *"   # Setiap hari jam 02:00
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          hostNetwork: true
          containers:
            - name: pg-dump-to-r2
              image: ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
              envFrom:
                - secretRef:
                    name: pg-dump-r2-secret
```

### Environment Variables

| Variabel | Default | Wajib | Keterangan |
|----------|---------|-------|------------|
| `DB_HOST` | `127.0.0.1` | — | Host PostgreSQL |
| `DB_PORT` | `5432` | — | Port PostgreSQL |
| `DB_USER` | — | ✅ | Username PostgreSQL |
| `DB_PASSWORD` | — | ✅ | Password PostgreSQL |
| `DB_NAME` | — | ✅ | Nama database |
| `R2_ACCOUNT_ID` | — | ✅ | Cloudflare Account ID |
| `R2_ACCESS_KEY_ID` | — | ✅ | R2 API Access Key ID |
| `R2_SECRET_ACCESS_KEY` | — | ✅ | R2 API Secret Access Key |
| `R2_BUCKET` | — | ✅ | Nama bucket R2 |
| `R2_PREFIX` | `pg-backups` | — | Subfolder di dalam bucket |
| `R2_ENDPOINT` | Auto dari `R2_ACCOUNT_ID` | — | Custom S3 endpoint (override) |
| `COMPRESS_LEVEL` | `9` | — | Level kompresi gzip (1–9) |
| `RETENTION_DAYS` | `7` | — | Hapus file lebih dari N hari (0 = nonaktif) |
| `DUMP_DIR` | `/tmp` | — | Direktori sementara file dump |
| `LOCK_WAIT_TIMEOUT` | `120s` | — | Timeout tunggu lock `pg_dump` |

### Cara Restore dari R2

```bash
# 1. Download file dump dari R2 ke lokal
rclone copy \
  ":s3,provider=Cloudflare,access_key_id=KEY,secret_access_key=SECRET,endpoint=https://ACCOUNT_ID.r2.cloudflarestorage.com:BUCKET/pg-backups/" \
  /tmp/ --include "*.dump.gz"

# 2. Decompress + restore
gunzip -c /tmp/mydb_20260509_020000.dump.gz \
  | PGPASSWORD="pass" pg_restore \
      -h 127.0.0.1 -U postgres -d mydb_restore \
      --no-owner --no-acl
```

---

## Requirements

| Tool | Versi Minimum | Keterangan |
|------|--------------|------------|
| Bash | 4.0+ | Semua script |
| PostgreSQL Client | 14+ | `pg_clone.sh`, `pg-dump-to-r2` |
| Nginx | 1.18+ | `setup-domain-nginx.sh` |
| Certbot | Latest | `setup-domain-nginx.sh` |
| Docker | 20.10+ | `pg-dump-to-r2` |
| rclone | Latest | `pg-dump-to-r2` (sudah include di image) |

---

## License

MIT
