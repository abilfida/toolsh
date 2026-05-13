# r2-to-pg Docker Publish & Documentation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create separate GitHub Actions workflow to build/publish r2-to-pg Docker image to GHCR, and add comprehensive documentation in README.md.

**Architecture:** Separate workflow file for independent trigger on r2-to-pg path changes. Documentation mirrors pg-dump-to-r2 format for consistency.

**Tech Stack:** GitHub Actions, Docker Buildx, GHCR, Markdown

---

## Prerequisites

**Existing files (already complete, no changes needed):**
- `r2-to-pg/Dockerfile` — Docker image definition
- `r2-to-pg/r2_to_pg.sh` — Streaming restore script (rclone cat → gunzip → psql)
- `r2-to-pg/.env.example` — Environment configuration template

**Files to create/modify:**
- Create: `.github/workflows/docker-publish-r2-to-pg.yml`
- Modify: `README.md` — Add r2-to-pg documentation section

---

## Task 1: Create GitHub Actions Workflow for r2-to-pg

**Files:**
- Create: `.github/workflows/docker-publish-r2-to-pg.yml`

**Step 1: Write the workflow file**

Create workflow file mirroring pg-dump-to-r2 structure but for r2-to-pg:

```yaml
name: Build & Push r2-to-pg

on:
  push:
    branches: ["main"]
    paths:
      - "r2-to-pg/**"
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/toolsh/r2-to-pg

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha,prefix=sha-,format=short
            type=ref,event=branch

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: ./r2-to-pg
          file: ./r2-to-pg/Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          platforms: linux/amd64,linux/arm64
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Step 2: Verify workflow syntax**

Run: `cat .github/workflows/docker-publish-r2-to-pg.yml`
Expected: File content matches above

**Step 3: Commit**

```bash
git add .github/workflows/docker-publish-r2-to-pg.yml
git commit -m "feat: add GitHub Actions workflow for r2-to-pg Docker image

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Add r2-to-pg Documentation to README.md

**Files:**
- Modify: `README.md` — Add documentation section after pg-dump-to-r2

**Step 1: Update tool table**

Add r2-to-pg entry in the tool table at the top of README.md (line 11-14).

Find the table section:
```markdown
| [`setup-swap.sh`](#setup-swapsh) | Shell Script | Setup swap memory di server |
| [`setup-domain-nginx.sh`](#setup-domain-nginxsh) | Shell Script | Setup domain Nginx + SSL Let's Encrypt |
| [`pg_clone.sh`](#pg_clonesh) | Shell Script | Clone database PostgreSQL antar server via remote |
| [`pg-dump-to-r2`](#pg-dump-to-r2-docker-image) | Docker Image | Dump PostgreSQL → gzip → upload ke Cloudflare R2 / S3 |
```

Replace with:
```markdown
| [`setup-swap.sh`](#setup-swapsh) | Shell Script | Setup swap memory di server |
| [`setup-domain-nginx.sh`](#setup-domain-nginxsh) | Shell Script | Setup domain Nginx + SSL Let's Encrypt |
| [`pg_clone.sh`](#pg_clonesh) | Shell Script | Clone database PostgreSQL antar server via remote |
| [`pg-dump-to-r2`](#pg-dump-to-r2-docker-image) | Docker Image | Dump PostgreSQL → gzip → upload ke Cloudflare R2 / S3 |
| [`r2-to-pg`](#r2-to-pg-docker-image) | Docker Image | Restore PostgreSQL dari Cloudflare R2 / S3 → gunzip → psql |
```

**Step 2: Add documentation section after pg-dump-to-r2**

Insert new section after the pg-dump-to-r2 documentation (after line ~312, before "Cara Restore dari R2" section).

Add this complete documentation block:

```markdown
---

## r2-to-pg (Docker Image)

Docker image untuk restore PostgreSQL secara otomatis: download dari **Cloudflare R2** / S3-compatible Object Storage → gunzip → restore ke PostgreSQL.

### ✨ Fitur v1 — Zero Disk Usage

- **Streaming pipeline** — `rclone cat | gunzip | psql` langsung tanpa tulis ke disk
- **Disk usage: 0 bytes** — tidak ada file temporary
- **Auto-select backup** — pilih file *.dump.gz terbaru dari R2 prefix
- **Explicit file option** — restore file tertentu via `R2_OBJECT`
- **Clean restore mode** — drop & recreate database sebelum restore
- **Post-restore ANALYZE** — optional VACUUM ANALYZE untuk optimasi
- **PostgreSQL 18** client support (override via build arg)
- **TCP keepalive built-in** untuk koneksi stabil
- Support `linux/amd64` dan `linux/arm64`

**Image:**

```
ghcr.io/abilfida/toolsh/r2-to-pg:latest
```

---

### Cara Pakai

**1. Buat file `.env`:**

```bash
cp r2-to-pg/.env.example .env
# Edit .env sesuai konfigurasi
```

```env
# Database Target
DB_HOST=127.0.0.1
DB_PORT=5432
DB_USER=your_db_user
DB_PASSWORD=your_db_password
DB_NAME=your_db_name
DB_ADMIN_DB=postgres

# Cloudflare R2
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_ACCESS_KEY_ID=your_r2_access_key_id
R2_SECRET_ACCESS_KEY=your_r2_secret_access_key
R2_BUCKET=your-bucket-name
R2_PREFIX=pg-backups

# Opsional: restore file tertentu (kosong = auto-select terbaru)
R2_OBJECT=mydb_20260513_020000.dump.gz

# Opsi restore
CLEAN_BEFORE_RESTORE=true
CREATE_DB_IF_NOT_EXISTS=true
POST_RESTORE_ANALYZE=false
```

**2. Jalankan:**

```bash
docker run --rm --env-file .env --network host \
  ghcr.io/abilfida/toolsh/r2-to-pg:latest
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
  ghcr.io/abilfida/toolsh/r2-to-pg:latest
```

---

### Restore Mode

| Mode | `CLEAN_BEFORE_RESTORE` | Behavior |
|------|:----------------------:|----------|
| Clean | `true` | Drop database, terminate koneksi aktif, recreate, restore |
| Append | `false` | Restore ke database existing (data bisa duplicate) |

**Rekomendasi:** Gunakan `CLEAN_BEFORE_RESTORE=true` untuk restore penuh dari backup.

---

### Kubernetes Job (One-shot Restore)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: r2-to-pg-secret
  namespace: default
type: Opaque
stringData:
  DB_HOST: "127.0.0.1"
  DB_PORT: "5432"
  DB_USER: "your_db_user"
  DB_PASSWORD: "your_db_password"
  DB_NAME: "your_db_name"
  DB_ADMIN_DB: "postgres"
  R2_ACCOUNT_ID: "your_cf_account_id"
  R2_ACCESS_KEY_ID: "your_r2_key_id"
  R2_SECRET_ACCESS_KEY: "your_r2_secret"
  R2_BUCKET: "your-bucket"
  R2_PREFIX: "pg-backups"
  CLEAN_BEFORE_RESTORE: "true"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: r2-to-pg-restore
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      hostNetwork: true
      containers:
      - name: r2-to-pg
        image: ghcr.io/abilfida/toolsh/r2-to-pg:latest
        envFrom:
        - secretRef:
            name: r2-to-pg-secret
```

---

### Environment Variables

| Variabel | Default | Wajib | Keterangan |
|----------|---------|:-----:|------------|
| `DB_HOST` | `127.0.0.1` | — | Host PostgreSQL target |
| `DB_PORT` | `5432` | — | Port PostgreSQL target |
| `DB_USER` | `postgres` | ✅ | Username PostgreSQL |
| `DB_PASSWORD` | — | ✅ | Password PostgreSQL |
| `DB_NAME` | — | ✅ | Nama database target |
| `DB_ADMIN_DB` | `postgres` | — | Database untuk admin ops (drop/create) |
| `R2_ACCOUNT_ID` | — | ✅ | Cloudflare Account ID |
| `R2_ACCESS_KEY_ID` | — | ✅ | R2 API Access Key ID |
| `R2_SECRET_ACCESS_KEY` | — | ✅ | R2 API Secret Access Key |
| `R2_BUCKET` | — | ✅ | Nama bucket R2 |
| `R2_PREFIX` | `pg-backups` | — | Subfolder di dalam bucket |
| `R2_OBJECT` | — | — | File spesifik (kosong = auto-select terbaru) |
| `CLEAN_BEFORE_RESTORE` | `true` | — | Drop/recreate DB sebelum restore |
| `CREATE_DB_IF_NOT_EXISTS` | `true` | — | Buat DB jika belum ada (mode append) |
| `POST_RESTORE_ANALYZE` | `false` | — | Jalankan VACUUM ANALYZE setelah restore |
| `DB_CONNECT_TIMEOUT` | `30` | — | Timeout koneksi (detik) |

---

### Build dengan Versi PostgreSQL Spesifik

```bash
# PostgreSQL 16
docker build --build-arg PG_MAJOR=16 -t r2-to-pg:pg16 ./r2-to-pg

# PostgreSQL 17
docker build --build-arg PG_MAJOR=17 -t r2-to-pg:pg17 ./r2-to-pg

# PostgreSQL 18 (default)
docker build -t r2-to-pg:pg18 ./r2-to-pg
```

---

### Performance & Disk Usage

**Streaming pipeline — tidak ada file temporary di disk:**

```
R2 object → rclone cat stdout → gunzip stdin → psql stdin → PostgreSQL
                                          ^
                                          └─ restore langsung
```

| Backup Size (compressed) | Bandwidth | Estimasi Durasi | Disk Usage |
|--------------------------|-----------|-----------------|:----------:|
| 300 MB | 100 Mbps | ~30 detik | **0 bytes** |
| 1.5 GB | 100 Mbps | ~2 menit | **0 bytes** |
| 3 GB | 100 Mbps | ~4 menit | **0 bytes** |
| 3 GB | 500 Mbps | ~50 detik | **0 bytes** |

---

### Troubleshooting

#### Error: `Restore pipeline GAGAL`

**Cek log error:**

```bash
kubectl logs -n <namespace> <pod-name>
```

**Kemungkinan penyebab:**

1. **File tidak ditemukan di R2** — cek `R2_PREFIX` dan `R2_OBJECT`
2. **Koneksi DB gagal** — cek `DB_HOST`, `DB_USER`, `DB_PASSWORD`
3. **Permission denied** — user tidak punya hak drop/create database

#### Error: `dropdb gagal / createdb gagal`

**Solusi:** Pastikan `DB_USER` punya hak superuser atau minimal `CREATEDB` role.

```sql
ALTER USER your_user CREATEDB;
```

#### Error: `pg_terminate_backend gagal`

**Solusi:** Jalankan dari pod dengan `hostNetwork: true` agar bisa terminate koneksi lokal.

---

```

**Step 3: Verify README structure**

Run: `grep -n "r2-to-pg" README.md`
Expected: Multiple matches showing new documentation added

**Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add r2-to-pg documentation in README

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Push and Verify

**Step 1: Push to remote**

```bash
git push origin main
```

Expected: Push successful, GitHub Actions triggers for r2-to-pg workflow

**Step 2: Verify workflow runs**

Check GitHub Actions page at: `https://github.com/abilfida/toolsh/actions`

Expected: New workflow "Build & Push r2-to-pg" running or completed

**Step 3: Verify Docker image published**

After workflow completes, check: `https://github.com/abilfida/toolsh/pkgs/container/toolsh%2Fr2-to-pg`

Expected: Package `r2-to-pg` visible with `latest` tag

---

## Summary

| Task | Action | Commit Message |
|------|--------|----------------|
| 1 | Create workflow | `feat: add GitHub Actions workflow for r2-to-pg Docker image` |
| 2 | Add docs | `docs: add r2-to-pg documentation in README` |
| 3 | Push & verify | Manual verification |

**Total commits: 2**