#!/usr/bin/env bash
# rilis — bangun binary backend bohAntar untuk VPS. Ketik `rilis` di Git Bash
# dari folder mana pun di dalam repo ini (fungsi `rilis` di ~/.bashrc).
# ponytail: tidak mengunggah ke VPS; tambahkan scp + pkill di sini kalau sudah
# ada kunci SSH ke server.
set -euo pipefail
cd "$(dirname "$0")/backend"

echo "== Cek kode: go vet + go test =="
go vet ./...
go test ./...

echo "== Bangun binary Linux =="
# Sama dengan build produksi; tanpa -s -w hasilnya ±15 MB, bukan ±10,7 MB.
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o bohantar-backend .

md5=$(md5sum bohantar-backend | cut -d' ' -f1)
echo
echo "SIAP UNGGAH: $PWD/bohantar-backend ($(du -h bohantar-backend | cut -f1)), md5 $md5"
go version -m bohantar-backend | grep -E 'vcs\.(revision|modified)'
echo
echo "Di VPS, folder /www/wwwroot/bohantar-backend:"
echo "  1. cp bohantar-backend bohantar-backend.bak   (cadangan)"
echo "  2. unggah timpa bohantar-backend"
echo "  3. pkill -f /www/wwwroot/bohantar-backend/bohantar-backend   (cron menyalakan lagi <= 1 menit)"
echo "  4. md5sum /proc/\$(pgrep -f bohantar-backend)/exe   -> harus $md5"
