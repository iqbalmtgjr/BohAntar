package main

import (
	"html/template"
	"net/http"
	"strconv"
)

// Halaman syarat & ketentuan.
//
// Google Play meminta URL Terms of Service untuk tiap aplikasi trader, dan link
// "Syarat & Ketentuan" di footer halaman depan selama ini cuma menunjuk ke "#".
// Disajikan backend dengan alasan yang sama seperti /privasi: tidak ada layanan
// lain yang harus ikut hidup.
//
// Seperti kebijakan privasi, isinya ditulis dari perilaku kode ini, bukan dari
// contoh syarat umum. Angka yang punya konstanta dibaca langsung dari
// konstantanya supaya halaman ini tidak tertinggal saat aturannya diubah. Yang
// masih ditulis tangan, dan WAJIB ikut diubah kalau kodenya berubah:
//   - 17 tahun: batas usia di kebijakan privasi.
//   - 2 jam tenggang permintaan sewa: kedaluwarsakanSewa (rental_penyewa.go).
//   - 14 hari masa percobaan dan perpanjangan 1 bulan: startTrialSubscription
//     dan webhook Xendit (main.go).
//   - Pembayaran pesanan selalu tunai: createOrderHandler.
//   - Saldo driver tidak bisa dicairkan: rute /api/pencairan ditutup (main.go).
//
// Kalau aturannya berubah tanpa halaman ini ikut berubah, pengguna memegang
// janji yang tidak lagi ditepati aplikasi — dan itulah yang dipakai saat ada
// sengketa.

// tanggalSyarat adalah tanggal pembaruan yang tampil di halaman. Ubah setiap
// kali isi syaratnya diubah, bukan setiap kali file ini disentuh.
const tanggalSyarat = "9 November 2026"

// formatRupiah menulis nominal dengan titik ribuan: 2000000 -> "Rp2.000.000".
func formatRupiah(n int64) string {
	s := strconv.FormatInt(n, 10)
	awal := len(s) % 3
	if awal == 0 {
		awal = 3
	}
	hasil := s[:awal]
	for i := awal; i < len(s); i += 3 {
		hasil += "." + s[i:i+3]
	}
	return "Rp" + hasil
}

var tmplSyarat = template.Must(template.New("syarat").Parse(`<!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Syarat &amp; Ketentuan — bohAntar</title>
` + gayaHalamanPublik + `
</head>
<body>
<h1>Syarat &amp; Ketentuan bohAntar</h1>
<p class="sub">Berlaku untuk aplikasi bohAntar beserta layanan bohRide, bohCar, bohSend, bohFood, dan bohRental. Dikelola oleh PT Indo Tech Consulting. Terakhir diperbarui {{.Tanggal}}.</p>

<p>Dengan mendaftar atau memakai bohAntar, Anda menyetujui ketentuan di halaman ini dan <a href="/api/privasi">Kebijakan Privasi</a> kami. Kalau Anda tidak setuju, mohon jangan memakai aplikasi ini.</p>

<h2>1. Peran bohAntar</h2>
<p>bohAntar adalah aplikasi yang mempertemukan Anda dengan driver mitra untuk mengantar penumpang dan barang, dengan warung mitra untuk pesan makanan, dan dengan usaha rental mitra untuk sewa kendaraan. Perjalanan dan pengantaran dikerjakan oleh driver, makanan disediakan oleh warung, dan kendaraan sewa disediakan oleh usaha rental yang bersangkutan.</p>

<h2>2. Akun</h2>
<ul>
  <li>Anda harus berusia minimal 17 tahun.</li>
  <li>Isi nama, email, dan nomor handphone yang benar dan masih aktif. Satu akun untuk satu orang; jangan meminjamkan akun Anda atau memakai akun orang lain.</li>
  <li>Jaga kerahasiaan kata sandi Anda. Aktivitas yang dilakukan dari akun Anda menjadi tanggung jawab Anda.</li>
</ul>

<h2>3. Memesan perjalanan dan kirim barang</h2>
<ul>
  <li><strong>Ongkos</strong> dihitung sistem dari titik jemput dan tujuan yang Anda pilih di peta, memakai tarif yang berlaku saat itu, dan ditampilkan sebelum Anda memesan bersama <strong>biaya jasa aplikasi</strong>. Keduanya dikunci saat pesanan dibuat: perubahan tarif sesudahnya tidak mengubah pesanan Anda.</li>
  <li><strong>Pembayaran tunai</strong> langsung kepada driver saat pesanan selesai. bohAntar tidak menyimpan saldo penumpang dan tidak menerima pembayaran pesanan dari penumpang lewat aplikasi.</li>
  <li>Pesanan yang belum diambil driver dalam {{.MenitMenunggu}} menit dibatalkan otomatis.</li>
  <li>Anda bisa membatalkan pesanan selama driver belum menjemput Anda atau belum mengambil barang dan makanan pesanan Anda. Setelah itu pembatalan hanya bisa dilakukan admin.</li>
  <li>Kalau driver berhalangan sebelum menjemput, pesanan Anda dikembalikan ke daftar orderan dan dicarikan driver lain.</li>
  <li>Pastikan Anda berada di titik jemput. Fitur chat hanya untuk keperluan pesanan yang sedang berjalan.</li>
  <li>Penilaian dan ulasan untuk driver harus jujur dan sopan.</li>
</ul>

<h2>4. Kirim barang (bohSend)</h2>
<ul>
  <li>Tulis jenis barang, nama penerima, dan nomor penerima dengan benar, dan kemas barang dengan layak.</li>
  <li>Dilarang mengirim barang yang melanggar hukum, berbahaya, atau mudah meledak dan terbakar. Driver boleh menolak barang yang tidak sesuai keterangan atau termasuk yang dilarang.</li>
  <li>Foto barang saat diambil dan diserahkan, beserta nama penerimanya, disimpan sebagai bukti pengantaran.</li>
  <li><strong>bohAntar tidak menyediakan asuransi barang.</strong> Tanda "barang berharga" pada pesanan hanya meminta driver lebih berhati-hati, bukan jaminan ganti rugi.</li>
</ul>

<h2>5. Pesan makanan (bohFood)</h2>
<ul>
  <li>Menu dan harga ditetapkan warung. Harga yang Anda lihat saat memesan adalah harga yang ditagihkan, walaupun warung mengubahnya kemudian.</li>
  <li>Driver datang ke warung, membeli pesanan Anda dengan uangnya sendiri, lalu mengantarkannya. Saat makanan diterima, Anda membayar tunai kepada driver: harga makanan, ongkos antar, dan biaya jasa aplikasi.</li>
  <li>Karena driver menalangi uang makanan, batalkan pesanan hanya bila benar-benar perlu, sebelum driver tiba di warung.</li>
  <li>Rasa, porsi, kebersihan, dan kehalalan makanan menjadi tanggung jawab warung.</li>
</ul>

<h2>6. Sewa kendaraan (bohRental)</h2>
<ul>
  <li>Kendaraan di katalog milik usaha rental mitra. Permintaan sewa baru berlaku setelah disetujui mitra. Permintaan yang belum ditanggapi sampai 2 jam lewat jam ambil dibatalkan otomatis.</li>
  <li>Harga sewa, persyaratan penyewa, cara pembayaran, dan denda keterlambatan ditentukan oleh mitra rental. Pembayaran sewa dilakukan langsung kepada mitra, tidak lewat bohAntar.</li>
  <li>Bila mitra menerapkan denda, denda dihitung per hari keterlambatan setelah masa toleransi yang ditetapkan mitra.</li>
  <li>Kerusakan atau kehilangan kendaraan selama masa sewa diselesaikan antara penyewa dan mitra rental sesuai kesepakatan sewa mereka.</li>
</ul>

<h2>7. Ketentuan bagi driver</h2>
<ul>
  <li>Calon driver mendaftar dengan KTP, SIM, STNK, dan data kendaraan yang masih berlaku. Akun baru bisa menerima pesanan setelah disetujui admin.</li>
  <li>Driver hanya menerima pesanan yang sesuai kendaraan terdaftar: bohCar untuk mobil, bohRide untuk motor.</li>
  <li>Selama status online, lokasi Anda dikirim ke sistem supaya bisa dipertemukan dengan pemesan dan diikuti selama perjalanan.</li>
  <li><strong>Setoran.</strong> Untuk setiap pesanan, driver menyetor komisi (persentase dari ongkos, tidak termasuk harga makanan) dan biaya jasa aplikasi kepada bohAntar. Setoran dipotong dari saldo driver saat pesanan selesai. Saldo yang minus berarti ada setoran yang belum dilunasi.</li>
  <li>Untuk menerima pesanan, saldo Anda harus cukup menutup setoran pesanan itu ditambah setoran pesanan lain yang belum selesai.</li>
  <li><strong>Top up saldo</strong> lewat QRIS, minimal {{.TopUpMin}} dan maksimal {{.TopUpMaks}} per transaksi. Biaya QRIS ditambahkan ke tagihan, sehingga saldo bertambah sebesar nominal yang Anda pilih.</li>
  <li><strong>Setor tunai</strong> kepada petugas bohAntar: petugas membuat kode QR sebesar uang yang diterima, lalu Anda memindainya dari aplikasi. Setoran tunai tidak bisa melebihi setoran yang belum dilunasi.</li>
  <li>Saldo hanya dipakai untuk setoran dan tidak bisa dicairkan atau dipindahkan lewat aplikasi. Bila Anda berhenti menjadi driver, sisa saldo dikembalikan admin setelah identitas Anda diperiksa.</li>
  <li>Bersikap sopan, berkendara dengan aman, dan mematuhi peraturan lalu lintas. bohAntar dapat menonaktifkan akun driver yang melanggar ketentuan ini.</li>
</ul>

<h2>8. Ketentuan bagi mitra warung dan rental</h2>
<ul>
  <li>Pendaftaran mitra diperiksa admin. Data usaha dan pemiliknya harus benar.</li>
  <li>Warung bertanggung jawab atas menu, harga, dan status buka-tutup yang tampil di aplikasi. Bagi warung yang memakai kasir Kasvo, menu dan jam buka dibaca dari Kasvo.</li>
  <li>Mitra rental mendapat masa percobaan 14 hari. Setelah itu diperlukan langganan bulanan yang dibayar lewat Xendit. Biayanya ditampilkan sebelum Anda membayar, dan setiap pembayaran memperpanjang masa aktif satu bulan.</li>
  <li>Selama langganan tidak aktif, kendaraan Anda disembunyikan dari katalog dan pesanan sewa yang masuk tidak bisa dibuka sampai langganan diperpanjang.</li>
</ul>

<h2>9. Yang dilarang</h2>
<ul>
  <li>Membuat pesanan palsu, menipu, atau sengaja merugikan driver, penumpang, maupun mitra.</li>
  <li>Kekerasan, ancaman, atau pelecehan dalam bentuk apa pun, termasuk lewat chat.</li>
  <li>Mengakali aplikasi: memalsukan lokasi, memakai program otomatis, atau mencoba mengakses data dan akun orang lain.</li>
  <li>Memakai bohAntar untuk kegiatan yang melanggar hukum.</li>
</ul>
<p>Pelanggaran dapat membuat akun dinonaktifkan atau dihapus, dan pelanggaran hukum dapat kami laporkan kepada pihak berwenang.</p>

<h2>10. Batas tanggung jawab</h2>
<p>Kami berusaha menjaga aplikasi tetap berjalan, tetapi tidak dapat menjamin bebas gangguan. Peta, rute, perkiraan waktu, dan notifikasi bergantung pada GPS, jaringan seluler, serta layanan pihak ketiga seperti Google Maps dan OpenStreetMap, sehingga hasilnya bisa meleset.</p>
<p>Sejauh diizinkan hukum, bohAntar tidak bertanggung jawab atas kerugian akibat perbuatan pengguna, driver, atau mitra yang berada di luar kendali kami. Keluhan atas sebuah pesanan tetap kami terima dan tindak lanjuti.</p>

<h2>11. Bantuan dan keluhan</h2>
<p>Kirim keluhan ke <code>{{.Kontak}}</code> dengan menyebutkan nomor handphone akun Anda, serta tanggal dan layanan pesanan yang dimaksud. Kami memeriksa riwayat dan bukti pengantaran pesanan tersebut untuk menindaklanjutinya.</p>

<h2>12. Menghapus akun</h2>
<p>Anda bisa menghapus akun kapan saja; caranya dijelaskan di <a href="/api/privasi">Kebijakan Privasi</a>. Akun belum bisa dihapus selama masih ada pesanan berjalan atau setoran yang belum dilunasi. Driver dan mitra yang masih memiliki saldo perlu menghubungi admin untuk pengembaliannya lebih dulu.</p>

<h2>13. Perubahan ketentuan</h2>
<p>Ketentuan ini dapat kami ubah mengikuti perkembangan layanan dan peraturan. Tanggal pembaruan tercantum di bagian atas halaman ini. Dengan tetap memakai bohAntar setelah perubahan, Anda dianggap menyetujui ketentuan yang baru.</p>

<h2>14. Hukum yang berlaku</h2>
<p>Ketentuan ini tunduk pada hukum Republik Indonesia. Perselisihan diselesaikan lebih dulu secara musyawarah. Bila tidak tercapai kesepakatan, perselisihan diselesaikan melalui jalur hukum yang berlaku.</p>

<h2>15. Menghubungi kami</h2>
<p>PT Indo Tech Consulting, pengelola bohAntar, Sintang, Kalimantan Barat. Email: <code>{{.Kontak}}</code>.</p>

<footer>bohAntar — Sintang, Kalimantan Barat. · <a href="/api/privasi">Kebijakan Privasi</a></footer>
</body>
</html>`))

func syaratKetentuanHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = tmplSyarat.Execute(w, map[string]any{
		"Tanggal":       tanggalSyarat,
		"Kontak":        kontakPrivasi(),
		"MenitMenunggu": int(batasPesananMenunggu.Minutes()),
		"TopUpMin":      formatRupiah(topUpMinimal),
		"TopUpMaks":     formatRupiah(topUpMaksimal),
	})
}
