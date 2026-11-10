package main

import (
	"bytes"
	"compress/zlib"
	"crypto/hmac"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"fmt"
	"image/png"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Kuitansi pesanan selesai, supaya penumpang bisa mengklaim ongkos perjalanan
// dinas (atau makan, untuk BohFood) ke bendahara kantornya.
//
// Dua langkah, karena browser tidak membawa token aplikasi:
//  1. GET /api/orders/{id}/kuitansi (bertoken, hanya pemesan, hanya pesanan
//     selesai) membalas jalur bertanda tangan.
//  2. Aplikasi membuka jalur itu di browser: GET /api/kuitansi/{id}/{tanda}
//     tanpa token membalas PDF-nya.
//
// Jalur yang sama tercetak di kuitansi sebagai "cek keaslian": pemeriksa yang
// membukanya mendapat PDF yang dibuat ulang dari database, jadi angka yang
// diedit di berkasnya ketahuan. Karena itu isinya hanya kolom yang tidak
// berubah lagi setelah pesanan selesai — plat motor sengaja tidak dicetak,
// karena dibaca dari pengajuan driver yang bisa diganti admin kapan saja.
// Jalurnya di bawah /api/ karena proxy hanya meneruskan /api/* ke backend
// (lihat /api/privasi di main.go).
//
// PDF-nya ditulis tangan: A4 (bersambung kalau menunya panjang), Helvetica bawaan setiap
// pembaca PDF, tanpa library — sama seperti admin/src/pages/bohrental/pdf.js.

const alamatPublik = "https://bohantar.indotechconsulting.com"

// tandaKuitansi: 80 bit HMAC atas id pesanan.
// ponytail: memakai kunci JWT, jadi mengganti JWT_SECRET mematikan tautan cek
// keaslian di kuitansi lama — pisahkan ke KUITANSI_SECRET kalau rotasi itu terjadi.
func tandaKuitansi(id string) string {
	m := hmac.New(sha256.New, jwtKey)
	m.Write([]byte("kuitansi:" + id))
	return hex.EncodeToString(m.Sum(nil))[:20]
}

func jalurKuitansi(id string) string { return "/api/kuitansi/" + id + "/" + tandaKuitansi(id) }

func kuitansiTautanHandler(w http.ResponseWriter, r *http.Request, orderID string) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	o, ada := dbGetOrder(orderID)
	// Pesanan orang lain dijawab sama dengan yang tidak ada: tidak membocorkan id.
	if !ada || o.RiderPhone != phone {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}
	if !bisaDikuitansi(o) {
		writeJSONResponse(w, 409, map[string]string{"error": "Kuitansi tersedia setelah pesanan selesai"})
		return
	}
	// nomor: nama berkas saat aplikasi membagikan PDF/gambarnya ke WhatsApp.
	writeJSONResponse(w, 200, map[string]string{"path": jalurKuitansi(o.ID), "nomor": nomorKuitansi(o)})
}

// bisaDikuitansi: hanya pesanan selesai. Pengantaran yang diminta kasir toko
// Kasvo dikecualikan — akun pemesannya toko, sedangkan yang membayar ongkir
// adalah penerima, dan menunya tercatat Rp0 karena sudah lunas di kasir.
func bisaDikuitansi(o Order) bool { return o.Status == "completed" && o.KasvoPengantaranID == 0 }

func kuitansiPDFHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "Method not allowed", 405)
		return
	}
	bagian := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/kuitansi/"), "/")
	var o Order
	sah := len(bagian) == 2 && hmac.Equal([]byte(bagian[1]), []byte(tandaKuitansi(bagian[0])))
	if sah {
		var ada bool
		o, ada = dbGetOrder(bagian[0])
		sah = ada && bisaDikuitansi(o)
	}
	if !sah {
		http.Error(w, "Kuitansi tidak ditemukan. Tautan ini tidak dikenal sistem BohAntar.", 404)
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", `inline; filename="Kuitansi-`+nomorKuitansi(o)+`.pdf"`)
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Robots-Tag", "noindex")
	w.Write(kuitansiPDF(o))
}

// nomorKuitansi: tanggal pesan + 8 karakter terakhir id (acak, lihat newID).
func nomorKuitansi(o Order) string {
	id := strings.ToUpper(o.ID)
	if len(id) > 8 {
		id = id[len(id)-8:]
	}
	if t, err := time.Parse(time.RFC3339, o.CreatedAt); err == nil {
		return "BA-" + t.In(zonaWIB).Format("20060102") + "-" + id
	}
	return "BA-" + id
}

var bulanIndo = [...]string{"Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"}

func waktuIndo(mentah string, jam bool) string {
	t, err := time.Parse(time.RFC3339, mentah)
	if err != nil {
		return mentah
	}
	t = t.In(zonaWIB)
	s := fmt.Sprintf("%d %s %d", t.Day(), bulanIndo[t.Month()-1], t.Year())
	if jam {
		s += fmt.Sprintf(", %02d.%02d WIB", t.Hour(), t.Minute())
	}
	return s
}

// terbilang: 37000 -> "tiga puluh tujuh ribu". Wajib di kuitansi kantor.
func terbilang(n int64) string {
	if n == 0 {
		return "nol"
	}
	var eja func(n int64) string
	eja = func(n int64) string {
		satuan := [...]string{"", "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "delapan", "sembilan", "sepuluh", "sebelas"}
		switch {
		case n < 12:
			return satuan[n]
		case n < 20:
			return eja(n-10) + " belas"
		case n < 100:
			return eja(n/10) + " puluh " + eja(n%10)
		case n < 200:
			return "seratus " + eja(n-100)
		case n < 1000:
			return eja(n/100) + " ratus " + eja(n%100)
		case n < 2000:
			return "seribu " + eja(n-1000)
		case n < 1_000_000:
			return eja(n/1000) + " ribu " + eja(n%1000)
		case n < 1_000_000_000:
			return eja(n/1_000_000) + " juta " + eja(n%1_000_000)
		}
		return eja(n/1_000_000_000) + " miliar " + eja(n%1_000_000_000)
	}
	return strings.Join(strings.Fields(eja(n)), " ")
}

func keteranganLayanan(o Order) string {
	switch o.Service {
	case "BohFood":
		return "Pesan-antar makanan dari " + o.MerchantName + " (BohFood)"
	case "BohCar":
		return "Jasa perjalanan mobil (BohCar)"
	case "BohSend", "BohAntar":
		return "Jasa pengiriman barang (" + o.Service + ")"
	}
	return "Jasa perjalanan ojek motor (" + o.Service + ")"
}

func kuitansiPDF(o Order) []byte {
	h := &halamanPDF{kepala: "Kuitansi BohAntar No. " + nomorKuitansi(o) + " (lanjutan)"}
	const kiri, kanan, kolomNilai = 50.0, 545.0, 170.0
	barang := o.Service == "BohSend" || o.Service == "BohAntar" || o.Service == "BohFood"
	abu := func() { h.warna(0.42, 0.45, 0.5) }
	hitam := func() { h.warna(0.07, 0.09, 0.15) }

	logo := logoKuitansi()
	const lebarLogo, atasLogo = 165.0, 40.0
	tinggiLogo := lebarLogo * float64(logo.tinggi) / float64(logo.lebar)
	h.gambar("Logo", kiri, atasLogo, lebarLogo, tinggiLogo)
	hitam()
	h.kanan(kanan, 66, 18, true, "KUITANSI")
	y := atasLogo + tinggiLogo + 14
	h.teks(kiri, y, 10, true, "PT Indo Tech Consulting")
	h.kanan(kanan, y, 10, false, "No. "+nomorKuitansi(o))
	y += 13
	abu()
	h.teks(kiri, y, 9, false, "Pengelola aplikasi BohAntar · Sintang, Kalimantan Barat")
	h.kanan(kanan, y, 10, false, waktuIndo(o.UpdatedAt, false))
	y += 16
	h.garis(kiri, kanan, y, 0.8)
	y += 24

	baris := func(label, nilai string) {
		potongan := bungkus(nilai, kanan-kolomNilai, 10)
		h.ruang(&y, float64(len(potongan))*14)
		abu()
		h.teks(kiri, y, 10, false, label)
		hitam()
		for _, potong := range potongan {
			h.teks(kolomNilai, y, 10, false, potong)
			y += 14
		}
		y += 3
	}
	baris("Diterima dari", o.RiderName)
	baris("Untuk pembayaran", keteranganLayanan(o))
	baris("Waktu pesan", waktuIndo(o.CreatedAt, true))
	baris("Selesai", waktuIndo(o.UpdatedAt, true))
	if barang {
		baris("Diambil di", o.PickupAddress)
		baris("Diantar ke", o.DropoffAddress)
	} else {
		baris("Dijemput di", o.PickupAddress)
		baris("Diantar ke", o.DropoffAddress)
	}
	baris("Driver", o.DriverName)
	if o.PaymentMethod == "wallet" {
		baris("Pembayaran", "Saldo akun BohAntar")
	} else {
		baris("Pembayaran", "Tunai kepada driver")
	}

	y += 12
	abu()
	h.teks(kiri, y, 9, true, "RINCIAN")
	h.kanan(kanan, y, 9, true, "JUMLAH")
	y += 7
	h.garis(kiri, kanan, y, 0.5)
	y += 16
	hitam()
	rincian := func(label string, nilai float64) {
		potongan := bungkus(label, 360, 10)
		h.ruang(&y, float64(len(potongan))*14)
		h.kanan(kanan, y, 10, false, rupiahKuitansi(nilai))
		for _, potong := range potongan {
			h.teks(kiri, y, 10, false, potong)
			y += 14
		}
		y += 3
	}
	for _, it := range o.Items {
		nama := it.Name
		for _, op := range it.Options {
			nama += " · " + op.Name
		}
		rincian(fmt.Sprintf("%d × %s @ %s", it.Qty, nama, rupiahKuitansi(it.Price)), it.Price*float64(it.Qty))
	}
	if o.FoodTotal > 0 {
		rincian("Ongkos antar", o.Fare)
	} else {
		rincian("Ongkos "+o.Service, o.Fare)
	}
	if o.BiayaJasa > 0 {
		rincian("Biaya jasa aplikasi", o.BiayaJasa)
	}
	if o.Diskon > 0 {
		rincian("Diskon voucher", -o.Diskon)
	}
	// Total, terbilang, cap, dan kaki tidak dipisah ke dua halaman (±140 pt).
	h.ruang(&y, 140)
	y -= 3
	h.garis(kiri, kanan, y, 0.5)
	y += 20
	total := totalBayar(o)
	h.teks(kiri, y, 12, true, "Total dibayar")
	h.kanan(kanan, y, 12, true, rupiahKuitansi(total))
	y += 18
	eja := terbilang(int64(total+0.5)) + " rupiah"
	abu()
	for _, potong := range bungkus("Terbilang: "+strings.ToUpper(eja[:1])+eja[1:], kanan-kiri-90, 10) {
		h.teks(kiri, y, 10, false, potong)
		y += 14
	}
	// Cap LUNAS: kuitansi baru dibuat untuk pesanan selesai, saat uangnya sudah dibayar.
	h.warna(0.09, 0.6, 0.3)
	h.kotak(kanan-72, y-22, 72, 26, 1.5)
	h.kanan(kanan-12, y-4, 14, true, "LUNAS")

	// Kaki langsung setelah isi, bukan di dasar halaman, supaya tidak tertimpa.
	y += 36
	abu()
	h.garis(kiri, kanan, y, 0.5)
	y += 16
	h.teks(kiri, y, 8, false, "Kuitansi ini dibuat otomatis oleh sistem BohAntar dan sah tanpa tanda tangan.")
	y += 12
	h.teks(kiri, y, 8, false, "Cek keaslian kuitansi ini di:")
	y += 12
	h.warna(0.118, 0.498, 1)
	h.teks(kiri, y, 8, false, alamatPublik+jalurKuitansi(o.ID))

	var halaman []string
	for _, isi := range h.halaman {
		halaman = append(halaman, isi.String())
	}
	return susunPDF(halaman, "Kuitansi BohAntar "+nomorKuitansi(o), logo.objek)
}

// Logo BohAntar di kop kuitansi: salinan admin/src/assets/logo.png yang
// dipotong ke isinya dan dikecilkan ke 660 px (±290 dpi pada lebar 165 pt).
// Disalin ke sini karena go:embed tidak bisa menjangkau folder induk — kalau
// logo diganti, potong dan salin ulang berkas ini juga.
//
//go:embed kuitansi_logo.png
var logoKuitansiPNG []byte

type gambarPDF struct {
	objek         string // objek XObject PDF siap pakai
	lebar, tinggi int    // piksel
}

// logoKuitansi didekode sekali: piksel RGB di atas latar putih (bagian
// transparan logo diputihkan — kertasnya memang putih), dikompres zlib.
var logoKuitansi = sync.OnceValue(func() gambarPDF {
	img, err := png.Decode(bytes.NewReader(logoKuitansiPNG))
	if err != nil {
		panic("kuitansi_logo.png rusak: " + err.Error()) // dijaga TestKuitansiPDFUtuh
	}
	b := img.Bounds()
	var isi bytes.Buffer
	z, _ := zlib.NewWriterLevel(&isi, zlib.BestCompression)
	px := make([]byte, 0, b.Dx()*3)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		px = px[:0]
		for x := b.Min.X; x < b.Max.X; x++ {
			r, g, bl, a := img.At(x, y).RGBA() // 16 bit, sudah dikali alfa
			putih := 0xffff - a
			px = append(px, byte((r+putih)>>8), byte((g+putih)>>8), byte((bl+putih)>>8))
		}
		z.Write(px)
	}
	z.Close()
	return gambarPDF{
		objek: fmt.Sprintf("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n%s\nendstream",
			b.Dx(), b.Dy(), isi.Len(), isi.String()),
		lebar: b.Dx(), tinggi: b.Dy(),
	}
})

func rupiahKuitansi(n float64) string {
	if n < 0 {
		return "-" + formatRupiah(int64(-n+0.5))
	}
	return formatRupiah(int64(n + 0.5))
}

// ==================== PDF TULIS TANGAN ====================

const tinggiA4 = 841.89

type halamanPDF struct {
	halaman []*strings.Builder // satu content stream per halaman
	kepala  string             // dicetak di atas halaman lanjutan
}

func (h *halamanPDF) tulis(format string, a ...any) {
	if len(h.halaman) == 0 {
		h.halaman = append(h.halaman, &strings.Builder{})
	}
	fmt.Fprintf(h.halaman[len(h.halaman)-1], format, a...)
}

// ruang: kalau `butuh` pt berikutnya tidak muat lagi, lanjut ke halaman baru.
// Warna kembali hitam (halaman baru mulai dari keadaan grafis bawaan).
func (h *halamanPDF) ruang(y *float64, butuh float64) {
	if *y+butuh <= tinggiA4-50 {
		return
	}
	h.halaman = append(h.halaman, &strings.Builder{})
	h.warna(0.42, 0.45, 0.5)
	h.teks(50, 50, 9, false, h.kepala)
	h.warna(0.07, 0.09, 0.15)
	*y = 84
}

// teks di (x, y) dengan y diukur dari ATAS halaman (PDF mengukur dari bawah).
func (h *halamanPDF) teks(x, y, ukuran float64, tebal bool, s string) {
	huruf := "F1"
	if tebal {
		huruf = "F2"
	}
	h.tulis("BT /%s %.1f Tf %.2f %.2f Td (%s) Tj ET\n", huruf, ukuran, x, tinggiA4-y, escapePDF(winAnsi(s)))
}

func (h *halamanPDF) kanan(xKanan, y, ukuran float64, tebal bool, s string) {
	h.teks(xKanan-lebarTeks(s, ukuran, tebal), y, ukuran, tebal, s)
}

func (h *halamanPDF) garis(x1, x2, y, tebal float64) {
	h.tulis("%.2f w %.2f %.2f m %.2f %.2f l S\n", tebal, x1, tinggiA4-y, x2, tinggiA4-y)
}

// gambar menempelkan XObject bernama `nama` dengan sudut kiri atas di (x, y).
func (h *halamanPDF) gambar(nama string, x, y, lebar, tinggi float64) {
	h.tulis("q %.2f 0 0 %.2f %.2f %.2f cm /%s Do Q\n", lebar, tinggi, x, tinggiA4-y-tinggi, nama)
}

func (h *halamanPDF) kotak(x, y, lebar, tinggi, tebal float64) {
	h.tulis("%.2f w %.2f %.2f %.2f %.2f re S\n", tebal, x, tinggiA4-y-tinggi, lebar, tinggi)
}

func (h *halamanPDF) warna(r, g, b float64) {
	h.tulis("%.3f %.3f %.3f rg %.3f %.3f %.3f RG\n", r, g, b, r, g, b)
}

// winAnsi: font bawaan PDF hanya mengenal WinAnsiEncoding (≈ Latin-1). Tanda
// baca tipografis dipetakan; huruf lain (emoji, aksara non-Latin) jadi "?".
func winAnsi(s string) []byte {
	khusus := map[rune]byte{'–': 0x96, '—': 0x97, '‘': 0x91, '’': 0x92, '“': 0x93, '”': 0x94, '•': 0x95, '…': 0x85}
	var b []byte
	for _, r := range s {
		switch {
		case r == '\n' || r == '\r' || r == '\t':
			b = append(b, ' ')
		case r >= 0x20 && r < 0x7f, r >= 0xa0 && r <= 0xff:
			b = append(b, byte(r))
		case khusus[r] != 0:
			b = append(b, khusus[r])
		default:
			b = append(b, '?')
		}
	}
	return b
}

func escapePDF(b []byte) string {
	var s strings.Builder
	for _, c := range b {
		if c == '\\' || c == '(' || c == ')' {
			s.WriteByte('\\')
		}
		s.WriteByte(c)
	}
	return s.String()
}

// Lebar glyph (1/1000 em) untuk ASCII 32..126, dari AFM Adobe. Tebal punya
// tabel sendiri: judul huruf kapital tebal ("KUITANSI", "JUMLAH") ±2 pt lebih
// lebar dan menjorok melewati garis kanan kalau diukur dengan tabel biasa.
var lebarHelvetica = [95]int{
	278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
	556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
	1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
	667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
	333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
	556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
}

var lebarHelveticaTebal = [95]int{
	278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
	556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
	975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
	667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
	333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
	611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
}

// ponytail: huruf di luar ASCII (é, ×, ·) dihitung 556 — cukup untuk nama
// dan alamat; ambil tabel WinAnsi lengkap kalau ada yang rata kanan memakainya.
func lebarTeks(s string, ukuran float64, tebal bool) float64 {
	tabel := &lebarHelvetica
	if tebal {
		tabel = &lebarHelveticaTebal
	}
	total := 0
	for _, c := range winAnsi(s) {
		if c >= 32 && c <= 126 {
			total += tabel[c-32]
		} else {
			total += 556
		}
	}
	return float64(total) * ukuran / 1000
}

// bungkus memecah teks per kata supaya tiap baris muat selebar `lebar`.
func bungkus(s string, lebar, ukuran float64) []string {
	var hasil []string
	baris := ""
	for _, kata := range strings.Fields(s) {
		coba := strings.TrimSpace(baris + " " + kata)
		if baris != "" && lebarTeks(coba, ukuran, false) > lebar {
			hasil = append(hasil, baris)
			coba = kata
		}
		baris = coba
	}
	if baris != "" || len(hasil) == 0 {
		hasil = append(hasil, baris)
	}
	return hasil
}

// susunPDF: objek 1 katalog, 2 daftar halaman, 3-4 huruf, 5 info, 6 logo
// (dipanggil /Logo), lalu sepasang (halaman, isi) untuk tiap halaman.
func susunPDF(halaman []string, judul, logo string) []byte {
	objek := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"", // daftar halaman, diisi setelah nomor objek halamannya diketahui
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
		"<< /Title (" + escapePDF(winAnsi(judul)) + ") /Producer (BohAntar) >>",
		logo,
	}
	var anak []string
	for _, isi := range halaman {
		// Latar putih eksplisit: aplikasi merender PDF ini jadi gambar (printing →
		// PdfRenderer Android) di atas bitmap TRANSPARAN, dan WhatsApp menampilkan
		// transparan sebagai hitam — teks hitam di atas hitam.
		isi = "1 1 1 rg 0 0 595.28 841.89 re f\n" + isi
		n := len(objek) + 1
		anak = append(anak, fmt.Sprintf("%d 0 R", n))
		objek = append(objek,
			fmt.Sprintf("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> /XObject << /Logo 6 0 R >> >> /Contents %d 0 R >>", n+1),
			fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(isi), isi))
	}
	objek[1] = fmt.Sprintf("<< /Type /Pages /Kids [%s] /Count %d >>", strings.Join(anak, " "), len(halaman))
	var b bytes.Buffer
	b.WriteString("%PDF-1.4\n")
	posisi := make([]int, len(objek))
	for i, o := range objek {
		posisi[i] = b.Len()
		fmt.Fprintf(&b, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	xref := b.Len()
	fmt.Fprintf(&b, "xref\n0 %d\n0000000000 65535 f \n", len(objek)+1)
	for _, p := range posisi {
		fmt.Fprintf(&b, "%010d 00000 n \n", p)
	}
	fmt.Fprintf(&b, "trailer\n<< /Size %d /Root 1 0 R /Info 5 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objek)+1, xref)
	return b.Bytes()
}
