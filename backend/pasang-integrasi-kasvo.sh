#!/bin/bash
# Pasang token integrasi Kasvo <-> BohFood di bohAntar DAN Kasvo sekaligus.
#
# Kedua server saling memanggil dengan satu token rahasia yang sama:
#   bohAntar run.sh : KASVO_URL, KASVO_INTEGRASI_TOKEN
#   Kasvo .env      : BOHANTAR_URL, BOHANTAR_INTEGRASI_TOKEN
# Token dibangkitkan di sini dan tidak pernah tampil di layar.
#
#   bash pasang-integrasi-kasvo.sh          # pasang (dilewati kalau sudah ada)
#   bash pasang-integrasi-kasvo.sh --ganti  # ganti token lama dengan yang baru
#
# Tidak me-restart bohAntar: token baru dibaca saat binary start, jadi jalankan
# SEBELUM pkill di langkah tukar binary.

set -euo pipefail

BOH=/www/wwwroot/bohantar-backend/run.sh
KAS=/www/wwwroot/orderkuy.indotechconsulting.com/.env
URL_KASVO=https://orderkuy.indotechconsulting.com
URL_BOHANTAR=https://bohantar.indotechconsulting.com

[ -f "$BOH" ] || { echo "FATAL: $BOH tidak ada"; exit 1; }
[ -f "$KAS" ] || { echo "FATAL: $KAS tidak ada"; exit 1; }
# Baris export di bawah `exec` tidak pernah dijalankan, jadi token harus
# disisipkan tepat sebelum exec.
grep -q '^exec ' "$BOH" || { echo "FATAL: run.sh tidak punya baris exec"; exit 1; }

sidik() { md5sum | cut -c1-12; }
lama_boh="$(grep '^export KASVO_INTEGRASI_TOKEN=' "$BOH" | cut -d'"' -f2 || true)"
lama_kas="$(grep '^BOHANTAR_INTEGRASI_TOKEN=' "$KAS" | cut -d= -f2- || true)"
if [ "${1:-}" != "--ganti" ] && [ -n "$lama_boh" ] && [ "$lama_boh" = "$lama_kas" ]; then
  echo "Token sudah terpasang dan sama di kedua sisi. Tidak ada yang diubah."
  echo "Pakai --ganti untuk merotasinya."
  exit 0
fi
unset lama_boh lama_kas

TOK="$(openssl rand -hex 32)"
[ ${#TOK} -eq 64 ] || { echo "FATAL: openssl gagal membangkitkan token"; exit 1; }

CAD="/root/cadangan-integrasi-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CAD"; chmod 700 "$CAD"
cp -p "$BOH" "$CAD/run.sh"
cp -p "$KAS" "$CAD/kasvo.env"
echo "Cadangan: $CAD"

# Ditulis BALIK lewat `cat >`, bukan `mv`: mv mengganti inode dan .env Kasvo
# berpindah kepemilikan ke root, sehingga PHP-FPM tidak bisa membacanya.
TMP="$(mktemp)"; chmod 600 "$TMP"

NILAI="$TOK" URL="$URL_KASVO" awk '
  /^export KASVO_URL=/ || /^export KASVO_INTEGRASI_TOKEN=/ { next }
  /^exec / && !sudah {
    print "export KASVO_URL=\"" ENVIRON["URL"] "\""
    print "export KASVO_INTEGRASI_TOKEN=\"" ENVIRON["NILAI"] "\""
    sudah = 1
  }
  { print }' "$BOH" > "$TMP"
cat "$TMP" > "$BOH"

NILAI="$TOK" URL="$URL_BOHANTAR" awk '
  /^BOHANTAR_URL=/ || /^BOHANTAR_INTEGRASI_TOKEN=/ { next }
  { print }
  END {
    print "BOHANTAR_URL=" ENVIRON["URL"]
    print "BOHANTAR_INTEGRASI_TOKEN=" ENVIRON["NILAI"]
  }' "$KAS" > "$TMP"
cat "$TMP" > "$KAS"

rm -f "$TMP"
unset TOK NILAI

echo
echo "== Verifikasi =="
bash -n "$BOH" && echo "  sintaks run.sh sah"
echo "  bohAntar: $(grep -c '^export KASVO_INTEGRASI_TOKEN=' "$BOH") baris token, sebelum exec: $(awk '/^export KASVO_INTEGRASI_TOKEN=/{t=NR} /^exec /{e=NR} END{print (t && t<e) ? "ya" : "TIDAK"}' "$BOH")"
echo "  Kasvo   : $(grep -c '^BOHANTAR_INTEGRASI_TOKEN=' "$KAS") baris token"
# Sidik jari, bukan isinya. Kedua nilai wajib sama.
echo "  sidik jari bohAntar: $(grep '^export KASVO_INTEGRASI_TOKEN=' "$BOH" | cut -d'"' -f2 | sidik)"
echo "  sidik jari Kasvo   : $(grep '^BOHANTAR_INTEGRASI_TOKEN=' "$KAS" | cut -d= -f2- | sidik)"

echo
echo "== Menerapkan di Kasvo =="
cd "$(dirname "$KAS")" && php artisan config:clear

echo
echo "bohAntar belum di-restart. Token terbaca begitu binary dinyalakan ulang"
echo "(langkah pkill di runbook). Setelah terbukti jalan: rm -rf $CAD"
