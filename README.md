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
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-domain-nginx.sh \\
  | sudo bash -s -- <domain> <email> [port]
```

**Contoh:**

```bash
# Reverse proxy ke aplikasi di port 3000
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-domain-nginx.sh \\
  | sudo bash -s -- myapp.com admin@myapp.com 3000

# Static file / web root (port 80)
sudo curl -fsSL https://raw.githubusercontent.com/abilfida/toolsh/main/setup-domain-nginx.sh \\
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

**✨ Fitur v5 — Zero Disk Usage:**
- **Streaming pipeline** — `pg_dump | gzip | rclone rcat` langsung ke R2 tanpa tulis ke disk
- **Disk usage: 0 bytes** (sebelumnya: ~2x ukuran database)
- **PostgreSQL 18** client support (install via PGDG official APT repo)
- TCP keepalive built-in untuk koneksi remote yang stabil
- Retensi otomatis: hapus file backup lama di R2
- Version check otomatis pg_dump vs server PostgreSQL
- Logging versi semua tools untuk diagnosis
- Support `linux/amd64` dan `linux/arm64`

**Image:**

```
ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
```

---

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

# TCP Keepalive (opsional - untuk koneksi remote)
DB_KEEPALIVES=1
DB_KEEPALIVES_IDLE=30
DB_KEEPALIVES_INTERVAL=10
DB_KEEPALIVES_COUNT=5
DB_CONNECT_TIMEOUT=30

# Cloudflare R2
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_ACCESS_KEY_ID=your_r2_access_key_id
R2_SECRET_ACCESS_KEY=your_r2_secret_access_key
R2_BUCKET=your-bucket-name
R2_PREFIX=pg-backups

# Opsi backup (opsional)
COMPRESS_LEVEL=6
RETENTION_DAYS=7
```

**2. Jalankan:**

```bash
docker run --rm --env-file .env --network host \\
  ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
```

**Atau inline dengan `-e`:**

```bash
docker run --rm \\
  -e DB_HOST=127.0.0.1 \\
  -e DB_USER=myuser \\
  -e DB_PASSWORD=mypassword \\
  -e DB_NAME=mydb \\
  -e R2_ACCOUNT_ID=xxxx \\
  -e R2_ACCESS_KEY_ID=xxxx \\
  -e R2_SECRET_ACCESS_KEY=xxxx \\
  -e R2_BUCKET=my-bucket \\
  --network host \\
  ghcr.io/abilfida/toolsh/pg-dump-to-r2:latest
```

---

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
  schedule: "0 2 * * *"  # Setiap hari jam 02:00
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

---

### Environment Variables

| Variabel | Default | Wajib | Keterangan |
|----------|---------|-------|------------|
| `DB_HOST` | `127.0.0.1` | — | Host PostgreSQL |
| `DB_PORT` | `5432` | — | Port PostgreSQL |
| `DB_USER` | — | ✅ | Username PostgreSQL |
| `DB_PASSWORD` | — | ✅ | Password PostgreSQL |
| `DB_NAME` | — | ✅ | Nama database |
| `DB_KEEPALIVES` | `1` | — | Enable TCP keepalive |
| `DB_KEEPALIVES_IDLE` | `30` | — | Idle time (detik) sebelum kirim probe |
| `DB_KEEPALIVES_INTERVAL` | `10` | — | Interval (detik) antar probe |
| `DB_KEEPALIVES_COUNT` | `5` | — | Jumlah probe gagal sebelum putus |
| `DB_CONNECT_TIMEOUT` | `30` | — | Timeout koneksi (detik) |
| `DB_TCP_USER_TIMEOUT` | `60000` | — | TCP user timeout (milidetik) |
| `R2_ACCOUNT_ID` | — | ✅ | Cloudflare Account ID |
| `R2_ACCESS_KEY_ID` | — | ✅ | R2 API Access Key ID |
| `R2_SECRET_ACCESS_KEY` | — | ✅ | R2 API Secret Access Key |
| `R2_BUCKET` | — | ✅ | Nama bucket R2 |
| `R2_PREFIX` | `pg-backups` | — | Subfolder di dalam bucket |
| `COMPRESS_LEVEL` | `6` | — | Level kompresi gzip (1–9) |
| `RETENTION_DAYS` | `7` | — | Hapus file lebih dari N hari (0 = nonaktif) |

---

### Build dengan Versi PostgreSQL Spesifik

Jika server PostgreSQL kamu versi 16 atau 17, rebuild image dengan `PG_MAJOR` build arg:

```bash
# PostgreSQL 16
docker build --build-arg PG_MAJOR=16 -t pg-dump-to-r2:pg16 ./pg-dump-to-r2

# PostgreSQL 17
docker build --build-arg PG_MAJOR=17 -t pg-dump-to-r2:pg17 ./pg-dump-to-r2

# PostgreSQL 18 (default)
docker build -t pg-dump-to-r2:pg18 ./pg-dump-to-r2
```

---

### Cara Restore dari R2

```bash
# 1. Download file dump dari R2 ke lokal
rclone copy \\
  ":s3,provider=Cloudflare,access_key_id=KEY,secret_access_key=SECRET,endpoint=https://ACCOUNT_ID.r2.cloudflarestorage.com:BUCKET/pg-backups/" \\
  /tmp/ --include "*.dump.gz"

# 2. Decompress + restore
gunzip -c /tmp/mydb_20260511_020000.dump.gz \\
  | PGPASSWORD="pass" psql \\
      -h 127.0.0.1 -U postgres -d mydb_restore
```

---

### Performance & Disk Usage

**v5 menggunakan streaming pipeline — tidak ada file temporary di disk:**

```
pg_dump stdout  →  gzip stdin/stdout  →  rclone rcat stdin  →  R2
                                                             ^
                                                             └─ upload langsung
```

| Database Size | Terkompresi | Bandwidth | Estimasi Durasi | Disk Usage |
|---------------|-------------|-----------|-----------------|------------|
| 1 GB | ~300 MB | 100 Mbps | ~30 detik | **0 bytes** |
| 5 GB | ~1.5 GB | 100 Mbps | ~2 menit | **0 bytes** |
| 10 GB | ~3 GB | 100 Mbps | ~4 menit | **0 bytes** |
| 10 GB | ~3 GB | 500 Mbps | ~50 detik | **0 bytes** |

---

### Troubleshooting

#### Error: `pg_dump GAGAL dengan exit code: 1`

**Cek log error:**
```bash
kubectl logs -n <namespace> <pod-name>
```

Kemungkinan penyebab:
1. **Version mismatch** — `pg_dump` client < server PostgreSQL
   - Solusi: Rebuild image dengan `--build-arg PG_MAJOR=<versi-server>`
2. **TCP timeout** — koneksi putus di tengah dump (database besar)
   - Solusi: Sudah di-fix di v5 dengan TCP keepalive di DSN
3. **Permission denied** — user tidak punya akses ke database
   - Solusi: Grant privilege `pg_dump` ke user

#### Progress tidak tampil

Normal untuk streaming mode — `rclone rcat` tidak tahu total size karena baca dari stdin. Yang penting: **speed tidak 0** berarti data mengalir.

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
