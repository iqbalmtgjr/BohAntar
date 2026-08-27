#!/bin/bash
# Rotasi kredensial produksi bohAntar.
#
# Nilai rahasianya dibangkitkan DI SINI, di VPS. Tidak ada yang perlu diketik
# dari luar kecuali dua nilai Xendit yang memang harus disalin dari dashboard
# mereka, dan itu pun dibaca tanpa ditampilkan di layar.
#
# Jalankan dari /www/wwwroot/bohantar-backend:
#   bash rotasi.sh          -> JWT_SECRET + kedua nilai Xendit
#   bash rotasi.sh --db     -> sekaligus password MySQL (baca peringatannya)

set -euo pipefail
cd "$(dirname "$0")"

RUN=run.sh
[ -f "$RUN" ] || { echo "FATAL: run.sh tidak ada di sini. Jalankan dari /www/wwwroot/bohantar-backend"; exit 1; }

CADANGAN="$RUN.bak-$(date +%Y%m%d-%H%M%S)"
cp "$RUN" "$CADANGAN"
echo "Cadangan: $CADANGAN"
echo

# Ambil nilai sebuah variabel dari run.sh tanpa menjalankan berkasnya — run.sh
# diakhiri exec, jadi men-source-nya akan menyalakan server, bukan membaca isinya.
nilai() {
  grep "^export $1=" "$RUN" | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

# Ganti satu baris export. Nilai barunya dilewatkan lewat environment supaya
# tidak ada karakter yang perlu di-escape.
setel() {
  local k="$1" v="$2"
  grep -q "^export $k=" "$RUN" || { echo "FATAL: $k tidak ada di run.sh — periksa manual"; exit 1; }
  NILAI_BARU="$v" awk -v key="$k" '
    $0 ~ "^export " key "=" { print "export " key "=\"" ENVIRON["NILAI_BARU"] "\""; next }
    { print }
  ' "$RUN" > "$RUN.tmp"
  mv "$RUN.tmp" "$RUN"
  echo "  $k diperbarui"
}

echo "== 1/3  JWT_SECRET =="
echo "Semua sesi yang sedang berjalan akan terputus. Itu wajar, bukan kerusakan."
setel JWT_SECRET "$(openssl rand -hex 32)"
echo

echo "== 2/3  Kredensial Xendit =="
echo "PERHATIAN: akun Xendit ini dipakai bersama aplikasi Kasvo Indonesia."
echo "  - Secret key boleh banyak per akun, jadi membuat key baru untuk bohAntar AMAN."
echo "  - Callback token cuma SATU untuk seluruh akun. Menggantinya mematikan"
echo "    webhook Kasvo juga, diam-diam. Kosongkan saja (tekan Enter) kecuali"
echo "    config Kasvo sedang terbuka dan siap diganti berbarengan."
echo
echo "Buka dashboard Xendit di tab lain:"
echo "  Settings > Developers > API Keys      -> buat Secret Key BARU (jangan hapus yang lama dulu)"
echo "  Settings > Developers > Webhooks      -> hanya kalau Kasvo ikut diganti"
echo
read -rsp "Tempel XENDIT_SECRET_KEY baru (tidak akan terlihat): " XSK; echo
read -rsp "Tempel XENDIT_CALLBACK_TOKEN baru (tidak akan terlihat): " XCT; echo

if [ -z "$XSK" ]; then
  echo "  Dilewati: XENDIT_SECRET_KEY dikosongkan."
else
  case "$XSK" in
    xnd_production_*|xnd_development_*) setel XENDIT_SECRET_KEY "$XSK" ;;
    *) echo "FATAL: secret key Xendit diawali xnd_production_ atau xnd_development_. Batal, tidak ada yang diubah selain JWT_SECRET."; exit 1 ;;
  esac
fi

if [ -z "$XCT" ]; then
  echo "  Dilewati: XENDIT_CALLBACK_TOKEN dikosongkan."
else
  setel XENDIT_CALLBACK_TOKEN "$XCT"
fi
echo

echo "== 3/3  Password MySQL =="
if [ "${1:-}" = "--db" ]; then
  DB_USER="$(nilai DB_USER)"
  DB_PASS_LAMA="$(nilai DB_PASSWORD)"
  echo "Mengganti password untuk pengguna MySQL: $DB_USER"
  DB_PASS_BARU="$(openssl rand -hex 24)"
  mysql -u"$DB_USER" -p"$DB_PASS_LAMA" -e \
    "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS_BARU'; FLUSH PRIVILEGES;"
  setel DB_PASSWORD "$DB_PASS_BARU"
  unset DB_PASS_BARU DB_PASS_LAMA
else
  echo "DILEWATI. Jalankan ulang dengan --db kalau memang mau."
  echo "PERINGATAN: kalau DB_USER adalah 'root', situs lain di VPS ini yang"
  echo "memakai root akan ikut kehilangan akses. Periksa dulu sebelum memakai --db."
fi
echo

echo "== Verifikasi =="
bash -n "$RUN" && echo "  Sintaks run.sh sah"
grep -c '^export ' "$RUN" | xargs echo "  Jumlah baris export:"

echo
echo "== Menyalakan ulang backend =="
pkill -f bohantar-backend || true
echo "Proses lama dihentikan. Daemon cron menyalakannya lagi dalam <60 detik."
sleep 45
for i in 1 2 3 4 5; do
  if curl -sf http://localhost:8080/api/health >/dev/null; then
    echo "BERHASIL: backend hidup kembali dengan kredensial baru."
    echo
    echo "Langkah terakhir yang HARUS Anda lakukan sendiri:"
    echo "  1. Login ulang ke dashboard admin (sesi lama sudah mati)"
    echo "  2. Pindahkan Kasvo Indonesia ke secret key barunya sendiri. Key lama"
    echo "     dipakai kedua aplikasi -- menghapusnya sekarang mematikan Kasvo."
    echo "  3. Setelah bohAntar DAN Kasvo dua-duanya terbukti jalan dengan key"
    echo "     masing-masing, baru hapus key lama yang bocor di dashboard Xendit."
    echo "  4. Hapus cadangan berisi kredensial lama: rm $CADANGAN"
    exit 0
  fi
  sleep 10
done

echo "GAGAL: backend belum menyahut setelah 95 detik."
echo "Lihat backend.log. Untuk mengembalikan: cp $CADANGAN $RUN && pkill -f bohantar-backend"
exit 1
