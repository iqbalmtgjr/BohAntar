#!/bin/bash
# ganti-binary.sh — tukar binary backend BohAntar TANPA jeda layanan.
#
# Dipanggil otomatis oleh `rilis` di laptop (lewat SSH). Bisa juga manual:
# unggah binary baru sebagai bohantar-backend.baru ke folder ini, lalu
#     bash /www/wwwroot/bohantar-backend/ganti-binary.sh
#
# Urutannya: binary baru dinyalakan DULU di port yang sama (SO_REUSEPORT, lihat
# backend/berhenti_rapi.go). Setelah terbukti mendengarkan, yang lama diberi
# SIGTERM: ia menolak koneksi baru, menuntaskan permintaan yang sedang berjalan
# (maks 25 dtk), lalu keluar. Kalau yang baru gagal menyala, yang lama tetap
# melayani dan berkas binary lama dikembalikan — tidak ada yang mati.
#
# Binary lama yang belum punya SO_REUSEPORT (sebelum rilis 9 Nov 2026) membuat
# yang baru gagal membuka port; untuk kali itu saja skrip jatuh ke cara lama
# yang dipercepat: hentikan yang lama, langsung nyalakan yang baru (jeda ±1-2
# detik, bukan menunggu cron satu menit).
set -u
DIR=/www/wwwroot/bohantar-backend
BIN="$DIR/bohantar-backend"
BARU="$DIR/bohantar-backend.baru"
cd "$DIR" || { echo "GAGAL: folder $DIR tidak ada"; exit 1; }
PORT=$(sed -n 's/^export PORT=["]*\([0-9]*\).*/\1/p' run.sh | head -1)
PORT=${PORT:-8080}

[ -s "$BARU" ] || { echo "GAGAL: $BARU belum diunggah"; exit 1; }
if [ "$(head -c4 "$BARU" | od -An -c | tr -d ' ')" != "177ELF" ]; then
  echo "GAGAL: $BARU bukan binary Linux (salah berkas?)"; exit 1
fi
chmod +x "$BARU"

pid_baru() { # pid binary yang bukan bagian dari $LAMA
  for p in $(pgrep -xf "$BIN"); do
    case " $LAMA " in *" $p "*) ;; *) echo "$p" ;; esac
  done
}
mendengar() { ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -q "pid=$1,"; }
nyalakan() {
  [ -f backend.log ] && mv -f backend.log backend.log.1 # proses lama terus menulis ke berkas lamanya
  setsid nohup bash run.sh > backend.log 2>&1 < /dev/null &
}
tunggu_menyala() { # gema pid baru yang sudah mendengarkan port, maks $1 detik
  for _ in $(seq 1 "$1"); do
    sleep 1
    for p in $(pid_baru); do mendengar "$p" && { echo "$p"; return 0; }; done
    [ -z "$(pid_baru)" ] && grep -q "address already in use" backend.log 2>/dev/null && return 1
  done
  return 1
}
berhenti_rapi() { # SIGTERM lalu tunggu, SIGKILL kalau lewat 35 dtk
  [ -z "$*" ] && return 0
  kill -TERM "$@" 2>/dev/null
  for _ in $(seq 1 35); do
    local sisa=""
    for p in "$@"; do kill -0 "$p" 2>/dev/null && sisa="$sisa $p"; done
    [ -z "$sisa" ] && return 0
    sleep 1
  done
  kill -9 $sisa 2>/dev/null
}

LAMA=$(pgrep -xf "$BIN" | tr '\n' ' ')
cp -p "$BIN" "$BIN.bak" 2>/dev/null
mv -f "$BARU" "$BIN" # proses lama tetap memakai isi lamanya (inode lama)
echo "Menyalakan binary baru di port $PORT..."
nyalakan
BARU_PID=$(tunggu_menyala 60)

if [ -z "$BARU_PID" ] && [ -n "$LAMA" ] && grep -q "address already in use" backend.log 2>/dev/null; then
  echo "Binary lama belum mendukung pergantian tanpa jeda (rilis pertama). Pakai cara cepat: jeda ±1-2 detik."
  berhenti_rapi $LAMA
  LAMA=""
  nyalakan
  BARU_PID=$(tunggu_menyala 60)
fi

if [ -z "$BARU_PID" ]; then
  echo "GAGAL: binary baru tidak menyala dalam 60 detik. Isi backend.log:"
  tail -20 backend.log
  for p in $(pid_baru); do kill -9 "$p" 2>/dev/null; done
  cp -p "$BIN.bak" "$BIN"
  if [ -n "$(pgrep -xf "$BIN")" ]; then
    echo "Binary lama tetap melayani; berkasnya sudah dikembalikan. Tidak ada gangguan."
  else
    echo "Menyalakan lagi binary lama..."
    nyalakan
    tunggu_menyala 60 > /dev/null && echo "Binary lama menyala lagi." || echo "PERIKSA SEGERA: backend tidak berjalan (cron akan mencoba tiap menit)."
  fi
  exit 1
fi
echo "Binary baru menyala (pid $BARU_PID)."

if [ -n "$LAMA" ]; then
  echo "Menghentikan binary lama dengan rapi (pid $LAMA)..."
  berhenti_rapi $LAMA
fi
# Sisa lain (mis. cron sempat menyalakan satu di sela cara cepat): cukup satu.
for p in $(pgrep -xf "$BIN"); do [ "$p" != "$BARU_PID" ] && berhenti_rapi "$p"; done

echo "Selesai. md5 binary yang berjalan: $(md5sum "/proc/$BARU_PID/exe" | cut -d' ' -f1)"
curl -s -o /dev/null -w "Cek /api/health: %{http_code}\n" "http://127.0.0.1:$PORT/api/health"
