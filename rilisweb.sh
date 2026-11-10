#!/usr/bin/env bash
# rilisweb — bangun dashboard (admin/) dan pasang di VPS tanpa zip/ekstrak
# manual. Ketik `rilisweb` di Git Bash dari folder mana pun di dalam repo ini.
#
# Folder web di server dicari dari conf nginx aaPanel untuk domain BohAntar;
# bisa dipaksa: BOHANTAR_WEB_ROOT=/www/wwwroot/xxx rilisweb
# Berkas lama di assets/ tidak dihapus: halaman yang sedang terbuka di browser
# orang masih memintanya, dan index.html lama (index.html.sebelum) tetap bisa
# dipulihkan seketika kalau rilis ini bermasalah.
# ponytail: assets/ lama menumpuk ±2-3 MB per rilis; bersihkan manual sesekali.
#
# Cara unggah, dicoba berurutan: FTP aaPanel (akun FTP_WEB_* di rilis.env),
# lalu SSH (BOHANTAR_SERVER=user@host), lalu langkah manual.
set -euo pipefail
cd "$(dirname "$0")/admin"
[ -f ../rilis.env ] && source ../rilis.env
SERVER="${BOHANTAR_SERVER:-root@103.150.194.141}"
DOMAIN=bohantar.indotechconsulting.com
PAKET=../dist-dashboard.tgz

echo "== Bangun dashboard =="
npm run build
tar -czf "$PAKET" -C dist .
bundel=$(grep -o 'index-[A-Za-z0-9_-]*\.js' dist/index.html | head -1)
echo "SIAP: $(cd .. && pwd)/dist-dashboard.tgz ($(du -h "$PAKET" | cut -f1)), bundel $bundel"

if [ -n "${FTP_WEB_USER:-}" ]; then
  tls=(); [ "${FTP_TLS:-0}" = 1 ] && tls=(--ssl-reqd)
  kirim() { curl -sS --fail "${tls[@]}" --user "$FTP_WEB_USER:$FTP_WEB_PASS" "$@"; }
  url="ftp://$FTP_HOST"
  sebelum=$(mktemp)
  # Sekaligus memastikan akun FTP ini memang membuka folder dashboard.
  kirim -o "$sebelum" "$url/index.html" || { echo "GAGAL: tidak ada index.html di folder akun FTP $FTP_WEB_USER — benar akun folder dashboard?"; exit 1; }
  read -r -p "Pasang dashboard lewat FTP ($FTP_WEB_USER@$FTP_HOST) sekarang? [y/N] " jawab
  [[ "$jawab" =~ ^[yY]$ ]] || { echo "Batal."; exit 0; }
  echo "== Unggah lewat FTP =="
  # Nama berkas di assets/ memuat hash isinya: yang namanya sudah ada di server
  # pasti sama isinya, jadi dilewati. Dulu semuanya ditimpa ulang, dan berkas
  # milik root (hasil ekstrak manual) menjawab 553 untuk berkas yang sudah benar.
  # || true: server baru yang belum punya assets/ — semuanya diunggah.
  sudah=$(kirim -l "$url/assets/" | tr -d '\r' || true)
  gagal=(); naik=0
  while IFS= read -r f; do
    [[ $f == assets/* ]] && grep -qxF "${f#assets/}" <<<"$sudah" && continue
    # Satu curl per berkas: curl berisi banyak -T hanya melaporkan status
    # berkas TERAKHIR, jadi kegagalan di tengah dulu lolos tanpa ketahuan.
    if kirim --ftp-create-dirs -T "dist/$f" "$url/$f" 2>/dev/null; then naik=$((naik+1)); else gagal+=("$f"); fi
  done < <(cd dist && find . -type f ! -path ./index.html | sed 's|^\./||')
  # index.html baru menunjuk berkas assets baru. Satu saja gagal naik lalu
  # index.html tetap diganti = dashboard layar putih. Jadi berhenti di sini.
  # Loop, bukan `printf | grep -q`: dengan pipefail, grep -q yang keluar lebih
  # dulu bisa membuat printf kena SIGPIPE dan pemeriksaannya diam-diam lolos.
  assets_gagal=0
  for f in "${gagal[@]}"; do [[ $f == assets/* ]] && assets_gagal=1; done
  if [ "$assets_gagal" = 1 ]; then
    printf 'GAGAL unggah: %s\n' "${gagal[@]}"
    echo "index.html TIDAK diganti — dashboard lama tetap jalan. Biasanya berkas/folder milik root:"
    echo "aaPanel → Files → folder dashboard → Permission → Owner www, centang 'Apply to subdirectories', lalu rilisweb lagi."
    exit 1
  fi
  # Kalau index.html di server sudah build ini juga, cadangan lama jangan ditimpa
  # salinan dirinya sendiri — nanti tidak ada lagi yang bisa dipulihkan.
  cmp -s "$sebelum" dist/index.html || kirim -T "$sebelum" "$url/index.html.sebelum"
  kirim -T dist/index.html "$url/index.html"
  rm -f "$sebelum"
  echo "Terpasang: $bundel ($((naik + 1)) berkas baru diunggah, sisanya sudah ada)."
  if [ ${#gagal[@]} -gt 0 ]; then
    printf 'PERINGATAN — tidak bisa ditimpa (milik root?), versi lama tetap dipakai: %s\n' "${gagal[@]}"
  fi
  echo "Batalkan kalau bermasalah: ganti nama index.html.sebelum jadi index.html (FTP / File Manager aaPanel)."
  exit 0
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SERVER" true 2>/dev/null; then
  echo "Kunci SSH ke $SERVER belum terpasang: unggah isi admin/dist ke folder web secara manual."
  exit 0
fi

WEB_ROOT="${BOHANTAR_WEB_ROOT:-}"
if [ -z "$WEB_ROOT" ]; then
  WEB_ROOT=$(ssh "$SERVER" "conf=\$(grep -l '$DOMAIN' /www/server/panel/vhost/nginx/*.conf 2>/dev/null | head -1); [ -n \"\$conf\" ] && sed -n 's/^[[:space:]]*root[[:space:]]\\+\\([^;]*\\);.*/\\1/p' \"\$conf\" | head -1")
fi
[ -n "$WEB_ROOT" ] || { echo "GAGAL: folder web untuk $DOMAIN tidak ketemu. Jalankan ulang dengan BOHANTAR_WEB_ROOT=/www/wwwroot/..."; exit 1; }
ssh "$SERVER" "test -f '$WEB_ROOT/index.html'" || { echo "GAGAL: $WEB_ROOT tidak berisi index.html — benar folder dashboard?"; exit 1; }

read -r -p "Pasang dashboard ke $SERVER:$WEB_ROOT sekarang? [y/N] " jawab
[[ "$jawab" =~ ^[yY]$ ]] || { echo "Batal. Paket tetap ada di dist-dashboard.tgz."; exit 0; }

echo "== Unggah & pasang =="
scp -q "$PAKET" "$SERVER:/tmp/dist-dashboard-bohantar.tgz"
# assets/ dan berkas lain dulu, index.html PALING AKHIR: selama ekstrak,
# pengunjung tetap mendapat index.html lama yang menunjuk assets lama yang masih
# ada — tidak pernah ada halaman yang setengah jadi.
ssh "$SERVER" "set -e
  cd '$WEB_ROOT'
  cp -p index.html index.html.sebelum
  tar -xzf /tmp/dist-dashboard-bohantar.tgz --no-same-owner --anchored --exclude=./index.html
  tar -xzf /tmp/dist-dashboard-bohantar.tgz --no-same-owner ./index.html
  rm -f /tmp/dist-dashboard-bohantar.tgz
  echo \"Terpasang di $WEB_ROOT: \$(grep -o 'index-[A-Za-z0-9_-]*\.js' index.html | head -1)\""
echo "Batalkan kalau bermasalah: ssh $SERVER \"cp $WEB_ROOT/index.html.sebelum $WEB_ROOT/index.html\""
