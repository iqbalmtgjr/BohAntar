#!/bin/bash
# Rotasi XENDIT_CALLBACK_TOKEN untuk bohAntar DAN Kasvo sekaligus.
#
# Token ini SATU untuk seluruh akun Xendit dan dipakai kedua aplikasi. Kalau
# hanya satu sisi yang diganti, sisi yang tertinggal menolak setiap webhook
# dengan 401 -- diam-diam, karena Xendit menganggapnya masalah kita.
#
# Kedua aplikasi kebetulan berada di VPS yang sama, jadi keduanya bisa diganti
# dalam satu tarikan napas. Tokennya diketik sekali.
#
# Jalankan SETELAH menekan regenerate di:
#   Xendit -> Settings -> Developers -> Webhooks -> Webhook verification token
#
#   bash rotasi-token.sh

set -euo pipefail

BOH=/www/wwwroot/bohantar-backend/run.sh
KAS=/www/wwwroot/orderkuy.indotechconsulting.com/.env

# Semua syarat diperiksa SEBELUM ada satu berkas pun disentuh. Gagal di tengah
# berarti satu aplikasi punya token baru dan satunya tidak.
[ -f "$BOH" ] || { echo "FATAL: $BOH tidak ada"; exit 1; }
[ -f "$KAS" ] || { echo "FATAL: $KAS tidak ada"; exit 1; }
grep -q '^export XENDIT_CALLBACK_TOKEN=' "$BOH" || { echo "FATAL: baris token tidak ada di run.sh"; exit 1; }
grep -q '^XENDIT_CALLBACK_TOKEN='        "$KAS" || { echo "FATAL: baris token tidak ada di .env Kasvo"; exit 1; }

read -rsp "Tempel callback token BARU dari dashboard (tidak akan terlihat): " TOK; echo
[ -n "$TOK" ] || { echo "Kosong. Batal, tidak ada yang diubah."; exit 1; }
case "$TOK" in
  *[!A-Za-z0-9_-]*) echo "FATAL: token memuat karakter di luar huruf/angka. Periksa tempelannya. Batal."; exit 1 ;;
esac

CAD="/root/cadangan-token-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CAD"; chmod 700 "$CAD"
cp -p "$BOH" "$CAD/run.sh"
cp -p "$KAS" "$CAD/kasvo.env"
echo "Cadangan: $CAD"

# Hasil awk ditulis BALIK ke berkas aslinya lewat `cat >`, bukan `mv`. mv
# mengganti inode-nya, dan .env Kasvo akan berpindah kepemilikan ke root
# sehingga PHP-FPM tidak bisa membacanya lagi.
TMP="$(mktemp)"; chmod 600 "$TMP"

NILAI="$TOK" awk '/^export XENDIT_CALLBACK_TOKEN=/ { print "export XENDIT_CALLBACK_TOKEN=\"" ENVIRON["NILAI"] "\""; next } { print }' "$BOH" > "$TMP"
cat "$TMP" > "$BOH"

NILAI="$TOK" awk '/^XENDIT_CALLBACK_TOKEN=/ { print "XENDIT_CALLBACK_TOKEN=" ENVIRON["NILAI"]; next } { print }' "$KAS" > "$TMP"
cat "$TMP" > "$KAS"

rm -f "$TMP"
unset TOK NILAI

echo
echo "== Verifikasi =="
bash -n "$BOH" && echo "  sintaks run.sh sah"
echo "  bohAntar: $(grep -c '^export XENDIT_CALLBACK_TOKEN=' "$BOH") baris token"
echo "  Kasvo   : $(grep -c '^XENDIT_CALLBACK_TOKEN=' "$KAS") baris token"
# Sidik jari, bukan isinya. Kedua nilai wajib sama.
echo "  sidik jari bohAntar: $(grep '^export XENDIT_CALLBACK_TOKEN=' "$BOH" | cut -d'"' -f2 | md5sum | cut -c1-12)"
echo "  sidik jari Kasvo   : $(grep '^XENDIT_CALLBACK_TOKEN='        "$KAS" | cut -d= -f2- | md5sum | cut -c1-12)"

echo
echo "== Menerapkan =="
cd "$(dirname "$KAS")" && php artisan config:clear
pkill -f bohantar-backend || true
echo "bohAntar dihentikan; daemon cron menyalakannya lagi dalam <60 detik."

echo
echo "Langkah terakhir yang HARUS Anda lakukan sendiri:"
echo "  1. Tunggu semenit, lalu buat satu tagihan langganan percobaan dan bayar,"
echo "     atau kirim ulang webhook lama dari Xendit -> Webhook Logs -> Resend."
echo "  2. Setelah terbukti jalan, hapus cadangan: rm -rf $CAD"
