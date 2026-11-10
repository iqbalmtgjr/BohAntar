#!/usr/bin/env bash
# rilis — bangun binary backend BohAntar dan (kalau kunci SSH ke server sudah
# terpasang) langsung pasang di VPS tanpa jeda layanan. Ketik `rilis` di Git
# Bash dari folder mana pun di dalam repo ini (fungsi `rilis` di ~/.bashrc).
#
# Cara unggah, dicoba berurutan:
#   1. FTP aaPanel — kalau rilis.env (salinan rilis.env.example) berisi akun
#      FTP backend. Cron server (daemon.sh) yang menukar binary-nya.
#   2. SSH — kalau kunci SSH ke server terpasang (BOHANTAR_SERVER=user@host).
#   3. Tidak keduanya: berhenti setelah build dan mencetak langkah manual.
set -euo pipefail
cd "$(dirname "$0")/backend"
[ -f ../rilis.env ] && source ../rilis.env
SERVER="${BOHANTAR_SERVER:-root@103.150.194.141}"
DIR_VPS=/www/wwwroot/bohantar-backend

echo "== Cek kode: go vet + go test =="
go vet ./...
go test ./...

echo "== Bangun binary Linux =="
# Sama dengan build produksi; tanpa -s -w hasilnya ±15 MB, bukan ±10,7 MB.
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o bohantar-backend .

md5=$(md5sum bohantar-backend | cut -d' ' -f1)
echo
echo "SIAP: $PWD/bohantar-backend ($(du -h bohantar-backend | cut -f1)), md5 $md5"
go version -m bohantar-backend | grep -E 'vcs\.(revision|modified)'
echo

if [ -n "${FTP_BACKEND_USER:-}" ]; then
  read -r -p "Unggah ke server produksi lewat FTP ($FTP_HOST) sekarang? [y/N] " jawab
  [[ "$jawab" =~ ^[yY]$ ]] || { echo "Batal. Binary tetap ada di $PWD."; exit 0; }
  tls=(); [ "${FTP_TLS:-0}" = 1 ] && tls=(--ssl-reqd)
  kirim() { curl -sS --fail "${tls[@]}" --user "$FTP_BACKEND_USER:$FTP_BACKEND_PASS" "$@"; }
  url="ftp://$FTP_HOST"
  echo "== Unggah lewat FTP =="
  kirim -T ganti-binary.sh "$url/ganti-binary.sh"
  # .part dulu lalu ganti nama: cron server tidak pernah melihat binary setengah
  # terunggah. Laporan rilis sebelumnya dihapus supaya tidak terbaca sebagai hasil.
  kirim -Q "*DELE ganti-binary.log" -T bohantar-backend "$url/bohantar-backend.baru.part" \
    -Q "-RNFR bohantar-backend.baru.part" -Q "-RNTO bohantar-backend.baru"
  echo "Terunggah. Menunggu cron server menukar binary tanpa jeda (<= 1 menit)..."
  for _ in $(seq 1 36); do
    sleep 5
    laporan=$(kirim "$url/ganti-binary.log" 2>/dev/null || true)
    if grep -q "$md5" <<<"$laporan"; then echo "$laporan"; echo "BERHASIL: binary baru berjalan."; exit 0; fi
    if grep -q "GAGAL" <<<"$laporan"; then echo "$laporan"; echo "GAGAL — lihat laporan di atas."; exit 1; fi
  done
  echo "Belum ada laporan dari server setelah 3 menit. Pastikan daemon.sh di server"
  echo "sudah versi baru (isi backend/cron-daemon.sh.example) — cron itulah yang menukar binary."
  exit 1
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" true 2>/dev/null; then
  echo "Kunci SSH ke $SERVER belum terpasang, jadi unggah manual:"
  echo "  1. unggah bohantar-backend + ganti-binary.sh ke $DIR_VPS,"
  echo "     binary-nya diberi nama bohantar-backend.baru"
  echo "  2. di server: bash $DIR_VPS/ganti-binary.sh   (tanpa jeda, tanpa pkill)"
  echo "Pasang kunci SSH sekali saja supaya langkah ini otomatis (lihat ganti-binary.sh)."
  exit 0
fi

read -r -p "Pasang ke server produksi $SERVER sekarang? [y/N] " jawab
[[ "$jawab" =~ ^[yY]$ ]] || { echo "Batal. Binary tetap ada di $PWD."; exit 0; }

echo "== Unggah =="
scp -q bohantar-backend "$SERVER:$DIR_VPS/bohantar-backend.baru"
scp -q ganti-binary.sh "$SERVER:$DIR_VPS/ganti-binary.sh"
echo "== Tukar binary tanpa jeda =="
ssh "$SERVER" "bash $DIR_VPS/ganti-binary.sh"
echo "(md5 lokal $md5 — harus sama dengan baris \"md5 binary yang berjalan\" di atas)"
