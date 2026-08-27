package main

import (
	"html/template"
	"net/http"
)

// Halaman kebijakan privasi dan permintaan hapus akun.
//
// Google Play menuntut dua URL yang bisa dibuka tanpa memasang aplikasi: satu
// untuk kebijakan privasi, satu untuk cara menghapus akun. Keduanya digabung di
// halaman ini, disajikan langsung backend supaya tidak ada layanan lain yang
// harus ikut hidup untuk memenuhi syarat rilis.
//
// Isinya ditulis dari apa yang benar-benar dikumpulkan kode ini, bukan dari
// contoh kebijakan umum. Kalau nanti ada data baru yang dikumpulkan, daftar di
// bawah ikut diperbarui — kebijakan yang tidak cocok dengan perilaku aplikasi
// lebih berbahaya daripada tidak punya kebijakan.

// kontakPrivasi bisa diganti lewat environment variable tanpa build ulang.
func kontakPrivasi() string {
	return getEnv("PRIVACY_CONTACT_EMAIL", "admin@bohantar.com")
}

var tmplPrivasi = template.Must(template.New("privasi").Parse(`<!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kebijakan Privasi &amp; Hapus Akun — bohAntar</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
         line-height: 1.7; max-width: 44rem; margin: 0 auto; padding: 2rem 1.25rem 4rem; }
  h1 { font-size: 1.6rem; margin-bottom: .25rem; }
  h2 { font-size: 1.15rem; margin-top: 2.25rem; }
  .sub { color: #6b7280; margin-top: 0; }
  ul { padding-left: 1.25rem; }
  li { margin: .35rem 0; }
  .kotak { border-left: 4px solid #1E7FFF; background: rgba(30,127,255,.07);
           padding: .9rem 1.1rem; border-radius: 0 8px 8px 0; margin: 1.25rem 0; }
  code { background: rgba(127,127,127,.15); padding: .1rem .35rem; border-radius: 4px; }
  footer { margin-top: 3rem; color: #6b7280; font-size: .9rem; }
</style>
</head>
<body>
<h1>Kebijakan Privasi bohAntar</h1>
<p class="sub">Berlaku untuk aplikasi bohAntar dan layanan bohFood serta bohRental.</p>

<h2>Data yang kami kumpulkan</h2>
<ul>
  <li><strong>Identitas akun</strong> — nama, alamat email, dan nomor handphone yang Anda isi saat mendaftar, atau yang diberikan Google kalau Anda masuk lewat akun Google.</li>
  <li><strong>Lokasi</strong> — titik jemput dan tujuan yang Anda pilih saat memesan. Untuk driver, posisi GPS dikirim selama Anda menyalakan status online, supaya penumpang bisa melihat Anda mendekat.</li>
  <li><strong>Riwayat pesanan</strong> — alamat, jarak, ongkos, metode pembayaran, dan waktu setiap pesanan.</li>
  <li><strong>Saldo dan transaksi</strong> — saldo dompet PayAntar serta catatan pemasukan dan pengeluarannya.</li>
  <li><strong>Percakapan</strong> — pesan antara penumpang dan driver selama satu pesanan berlangsung.</li>
  <li><strong>Dokumen driver</strong> — bagi calon driver: foto KTP, SIM, dan STNK, dipakai hanya untuk memverifikasi kelayakan berkendara.</li>
</ul>

<h2>Kenapa kami memerlukannya</h2>
<p>Untuk mempertemukan penumpang dengan driver, menghitung ongkos, memproses pembayaran, menampilkan posisi driver di peta selama perjalanan, dan menjawab keluhan bila terjadi masalah dalam sebuah pesanan.</p>

<h2>Siapa yang bisa melihatnya</h2>
<ul>
  <li><strong>Driver dan penumpang yang sedang terhubung</strong> saling melihat nama, nomor handphone, dan lokasi masing-masing selama pesanan berjalan — dan berhenti melihatnya setelah pesanan selesai.</li>
  <li><strong>OpenStreetMap</strong> menerima koordinat yang Anda cari untuk menampilkan peta, mencari alamat, dan menghitung rute.</li>
  <li><strong>Google</strong> menerima permintaan verifikasi bila Anda memilih masuk dengan akun Google.</li>
  <li><strong>Xendit</strong> memproses pembayaran langganan mitra.</li>
</ul>
<p>Kami tidak menjual data Anda, dan tidak membaginya untuk keperluan iklan.</p>

<h2>Berapa lama disimpan</h2>
<ul>
  <li>Posisi driver hanya disimpan satu titik terakhir dan ditimpa setiap kali diperbarui — kami tidak menyimpan jejak perjalanan.</li>
  <li>Riwayat pesanan disimpan selama akun aktif, dan tetap disimpan dalam bentuk anonim setelah akun dihapus karena dibutuhkan untuk pembukuan.</li>
  <li>Percakapan dan alamat tersimpan dihapus bersama akun Anda.</li>
</ul>

<h2>Menghapus akun Anda</h2>
<div class="kotak">
  <p><strong>Dari dalam aplikasi:</strong> buka tab <strong>Akun</strong> → <strong>Hapus akun</strong>, lalu konfirmasi.</p>
  <p><strong>Tanpa aplikasi:</strong> kirim email ke <code>{{.Kontak}}</code> dari alamat email yang terdaftar, dengan subjek <em>Hapus Akun</em>. Permintaan diproses dalam 7 hari kerja.</p>
</div>
<p><strong>Yang ikut terhapus:</strong> nama, email, nomor handphone, alamat tersimpan, isi percakapan, dan saldo dompet yang tersisa.</p>
<p><strong>Yang tetap disimpan:</strong> catatan pesanan tanpa nama dan nomor Anda — hanya tanggal, jarak, dan nominalnya — karena diperlukan untuk pembukuan usaha.</p>
<p>Akun tidak bisa dihapus selagi ada pesanan yang sedang berjalan, atau bila masih ada komisi yang belum disetor.</p>

<h2>Hak Anda</h2>
<p>Anda berhak meminta salinan data Anda, memperbaiki data yang keliru, atau menarik izin lokasi kapan saja lewat pengaturan perangkat. Menarik izin lokasi membuat pemesanan dan penerimaan orderan tidak lagi berfungsi.</p>

<h2>Anak-anak</h2>
<p>bohAntar tidak ditujukan untuk pengguna di bawah 17 tahun dan kami tidak sengaja mengumpulkan data mereka.</p>

<h2>Menghubungi kami</h2>
<p>Pertanyaan tentang privasi bisa dikirim ke <code>{{.Kontak}}</code>.</p>

<footer>bohAntar — Sintang, Kalimantan Barat.</footer>
</body>
</html>`))

func kebijakanPrivasiHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = tmplPrivasi.Execute(w, map[string]string{"Kontak": kontakPrivasi()})
}
