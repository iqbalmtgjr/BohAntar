#!/usr/bin/env bash
# rilisapp — bangun AAB bohAntar untuk Google Play: tes, nomor build +1, tanda
# tangan kunci upload. Ketik `rilisapp` di Git Bash dari folder mana pun di
# dalam repo ini. Unggah AAB-nya manual di Play Console.
#   rilisapp         -> 1.0.0+3 jadi 1.0.0+4
#   rilisapp 1.0.1   -> nama versi baru, nomor tetap naik satu
set -euo pipefail
cd "$(dirname "$0")/mobile"

# Gradle tidak berhenti kalau ini kosong, cuma memperingatkan di tengah keluaran
# yang panjang: AAB-nya jadi bertanda tangan debug (ditolak Play) atau petanya kosong.
for kunci in storeFile mapsApiKey; do
  grep -q "^$kunci=." android/key.properties 2>/dev/null ||
    { echo "android/key.properties: $kunci kosong atau tidak ada, rilis dibatalkan." >&2; exit 1; }
done

read -r nama nomor < <(sed -n 's/^version: *\([0-9.]*\)+\([0-9]*\).*/\1 \2/p' pubspec.yaml)
[ -n "${nomor:-}" ] || { echo "Baris 'version: x.y.z+N' di pubspec.yaml tidak ketemu." >&2; exit 1; }
nama=${1:-$nama}
# versionCode tidak boleh dipakai ulang di Play, termasuk yang hangus karena ditolak.
nomor=$((nomor + 1))
echo "== Versi baru: $nama+$nomor =="

flutter test
flutter build appbundle --release --build-name="$nama" --build-number="$nomor"

# Ditulis SETELAH build sukses: build yang gagal tidak melompati nomor versi.
sed -i "s/^version: *[0-9.]*+[0-9]*/version: $nama+$nomor/" pubspec.yaml

aab=$PWD/build/app/outputs/bundle/release/app-release.aab
echo
echo "SIAP UNGGAH: $aab ($(du -h "$aab" | cut -f1)), versi $nama+$nomor"
echo "Ingat: binary backend terbaru (rilis) harus sudah naik SEBELUM AAB ini dirilis."
explorer.exe "/select,$(cygpath -w "$aab")" || true
