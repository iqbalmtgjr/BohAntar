#!/usr/bin/env bash
#
# uji-asap-pesanan.sh — menjalankan satu pesanan sungguhan dari lahir sampai
# selesai, lalu memeriksa uangnya berpindah persis sebanyak yang seharusnya.
#
# Kenapa ada: tes unit tidak pernah melihat uang berpindah di database
# sungguhan, dan `dbSaveUser` sudah membuktikan sebuah fungsi bisa rusak
# total selama tiga hari sementara seluruh tes hijau dan log bersih.
#
# JALANKAN DI VPS (butuh mysql lokal):
#   bash uji-asap-pesanan.sh
#
# Dua akun sekali pakai dibuat sendiri lewat API, jadi tidak ada akun
# sungguhan yang disentuh dan tidak ada kata sandi yang perlu kamu ketik
# selain kata sandi database. Semuanya dihapus lagi di akhir, sukses maupun
# gagal.
set -uo pipefail

API=${API:-https://bohantar.indotechconsulting.com}
DB_NAME=${DB_NAME:-bohantar}
DB_USER=${DB_USER:-bohantar}

CAP="uji$(date +%H%M%S)"
RIDER_PHONE="0899${RANDOM:0:3}${RANDOM:0:4}"
DRIVER_PHONE="0898${RANDOM:0:3}${RANDOM:0:4}"
SANDI="ujiasap12345"
ORDER_ID=""
lulus=0
gagal=0

# Kata sandi database ditanyakan sekali lalu dititipkan ke MYSQL_PWD, supaya
# tidak pernah muncul di daftar proses seperti kalau ditulis `mysql -pRAHASIA`.
read -rsp "Kata sandi database untuk $DB_USER: " MYSQL_PWD; echo
export MYSQL_PWD
sql() { mysql -u "$DB_USER" "$DB_NAME" -N -B -e "$1"; }

if ! sql "SELECT 1" >/dev/null 2>&1; then
  echo "Tidak bisa menyambung ke database. Berhenti."
  exit 1
fi

# Dibersihkan lewat trap, bukan di akhir skrip: kalau sebuah pemeriksaan
# gagal di tengah jalan, akun dan pesanan ujinya tetap tidak boleh
# tertinggal di produksi.
bersihkan() {
  [ -n "$ORDER_ID" ] && sql "DELETE FROM order_ratings WHERE order_id='$ORDER_ID';
                             DELETE FROM chat_messages WHERE order_id='$ORDER_ID';
                             DELETE FROM orders WHERE id='$ORDER_ID';" >/dev/null 2>&1
  sql "DELETE FROM users WHERE phone_number IN ('+62${RIDER_PHONE#0}','+62${DRIVER_PHONE#0}');" >/dev/null 2>&1
  echo
  echo "Dibersihkan. Lulus: $lulus, gagal: $gagal"
  [ "$gagal" -eq 0 ] || exit 1
}
trap bersihkan EXIT

periksa() { # periksa "nama" "yang diharapkan" "yang didapat"
  if [ "$2" = "$3" ]; then
    lulus=$((lulus + 1)); printf '  OK   %s\n' "$1"
  else
    gagal=$((gagal + 1)); printf '  GAGAL %s — diharapkan %s, dapat %s\n' "$1" "$2" "$3"
  fi
}

# Mengambil satu nilai dari JSON tanpa jq, yang belum tentu ada di server.
ambil() { sed -n 's/.*"'"$1"'":"\{0,1\}\([^,"}]*\)"\{0,1\}.*/\1/p' <<<"$2" | head -1; }

# Status pesanan perlu pembaca sendiri: setiap balasan dibungkus amplop
# {"status":"success", ...}, jadi pembaca biasa akan menangkap amplopnya dan
# melaporkan "success" untuk setiap langkah — lolos tanpa memeriksa apa pun.
status_pesanan() { grep -o '"status":"[^"]*"' <<<"$1" | sed 's/.*:"//;s/"$//' | grep -v '^success$' | head -1; }

daftar() { # daftar <nomor> <nama> -> token
  curl -s -X POST "$API/api/auth/register" -H 'Content-Type: application/json' \
    -d "{\"phone_number\":\"$1\",\"name\":\"$2\",\"email\":\"$1@uji.test\",\"role\":\"rider\",\"password\":\"$SANDI\"}"
}

echo "== 1. Menyiapkan dua akun sekali pakai =="
tok_rider=$(ambil token "$(daftar "$RIDER_PHONE" "Uji Penumpang $CAP")")
tok_driver_awal=$(daftar "$DRIVER_PHONE" "Uji Driver $CAP")
periksa "penumpang dapat token" "ada" "$([ -n "$tok_rider" ] && echo ada || echo kosong)"
periksa "driver terdaftar" "ada" "$([ -n "$(ambil token "$tok_driver_awal")" ] && echo ada || echo kosong)"

# Peran driver hanya bisa diberikan admin, jadi di sini lewat database — dan
# tokennya diambil ulang supaya memuat peran yang baru.
sql "UPDATE users SET role='driver', is_driver_active=1 WHERE phone_number='+62${DRIVER_PHONE#0}';"
tok_driver=$(ambil token "$(curl -s -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$DRIVER_PHONE@uji.test\",\"password\":\"$SANDI\"}")")
periksa "driver bisa masuk" "ada" "$([ -n "$tok_driver" ] && echo ada || echo kosong)"
[ -n "$tok_rider" ] && [ -n "$tok_driver" ] || { echo "Tidak bisa lanjut tanpa dua token."; exit 1; }

echo "== 2. Membuat pesanan =="
# Saldo diisi lebih dulu: pemesanan dengan dompet ditolak kalau saldonya
# kurang, dan ongkosnya sendiri baru diketahui setelah pesanan lahir.
sql "UPDATE users SET balance=200000 WHERE phone_number='+62${RIDER_PHONE#0}';"
saldo_rider_awal=$(sql "SELECT balance FROM users WHERE phone_number='+62${RIDER_PHONE#0}';")
saldo_driver_awal=$(sql "SELECT balance FROM users WHERE phone_number='+62${DRIVER_PHONE#0}';")

# Dua titik sungguhan di Sintang, berjarak sekitar satu kilometer.
buat=$(curl -s -X POST "$API/api/orders" -H "Authorization: Bearer $tok_rider" \
  -H 'Content-Type: application/json' -d '{
    "pickup":"Titik uji asap A","dropoff":"Titik uji asap B",
    "pickup_lat":-0.0784,"pickup_lng":111.4933,
    "dropoff_lat":-0.0700,"dropoff_lng":111.4980,
    "service":"BohRide","payment_method":"wallet"}')
ORDER_ID=$(ambil id "$buat")
fare=$(ambil fare "$buat")
komisi=$(ambil komisi "$buat")
periksa "pesanan lahir" "ada" "$([ -n "$ORDER_ID" ] && echo ada || echo kosong)"
periksa "status awal" "pending" "$(status_pesanan "$buat")"
[ -n "$ORDER_ID" ] || { echo "Tidak ada pesanan untuk diuji. Balasan: $buat"; exit 1; }

# Ongkos wajib datang dari server, bukan dari aplikasi: kalau nol, seseorang
# bisa memesan gratis dan driver yang menanggung.
periksa "ongkos di atas nol" "ya" "$(awk -v f="$fare" 'BEGIN{print (f>0)?"ya":"tidak"}')"
periksa "komisi 20% dari ongkos" "$(awk -v f="$fare" 'BEGIN{printf "%.0f", (f*20/100)+0.5}')" \
        "$(awk -v k="$komisi" 'BEGIN{printf "%.0f", k}')"

echo "== 3. Driver menerima, menjemput, menyelesaikan =="
terima=$(curl -s -X POST "$API/api/orders/$ORDER_ID/accept" -H "Authorization: Bearer $tok_driver")
periksa "diterima driver" "accepted" "$(status_pesanan "$terima")"

# Pesanan yang sudah diambil tidak boleh bisa diambil lagi — inilah yang
# dijaga syarat status di dalam UPDATE, bukan pengecekan di aplikasi.
ulang=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/api/orders/$ORDER_ID/accept" \
  -H "Authorization: Bearer $tok_driver")
periksa "tidak bisa diterima dua kali" "ya" "$([ "$ulang" != "200" ] && echo ya || echo tidak)"

periksa "dijemput" "picked_up" "$(status_pesanan "$(curl -s -X POST "$API/api/orders/$ORDER_ID/pickup" -H "Authorization: Bearer $tok_driver")")"
selesai=$(curl -s -X POST "$API/api/orders/$ORDER_ID/complete" -H "Authorization: Bearer $tok_driver")
periksa "diselesaikan" "completed" "$(status_pesanan "$selesai")"

echo "== 4. Uangnya berpindah persis =="
saldo_rider_akhir=$(sql "SELECT balance FROM users WHERE phone_number='+62${RIDER_PHONE#0}';")
saldo_driver_akhir=$(sql "SELECT balance FROM users WHERE phone_number='+62${DRIVER_PHONE#0}';")
periksa "saldo penumpang berkurang sebesar ongkos" \
  "$(awk -v a="$saldo_rider_awal" -v f="$fare" 'BEGIN{printf "%.2f", a-f}')" \
  "$(awk -v b="$saldo_rider_akhir" 'BEGIN{printf "%.2f", b}')"
periksa "saldo driver bertambah sebesar ongkos dikurangi komisi" \
  "$(awk -v a="$saldo_driver_awal" -v f="$fare" -v k="$komisi" 'BEGIN{printf "%.2f", a+f-k}')" \
  "$(awk -v b="$saldo_driver_akhir" 'BEGIN{printf "%.2f", b}')"

# Status akhir dibaca ulang dari database, bukan dipercaya dari balasan HTTP:
# balasan bisa saja benar sementara barisnya tidak pernah tersimpan — persis
# yang terjadi pada dbSaveUser.
periksa "status tersimpan di database" "completed" "$(sql "SELECT status FROM orders WHERE id='$ORDER_ID';")"
periksa "komisi tercatat di pesanan" "$(awk -v k="$komisi" 'BEGIN{printf "%.2f", k}')" \
        "$(sql "SELECT komisi FROM orders WHERE id='$ORDER_ID';")"
