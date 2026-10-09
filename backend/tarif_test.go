package main

import (
	"encoding/json"
	"math"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Dua titik di Sintang berjarak kira-kira 3,3 km garis lurus.
const (
	sintangLat1, sintangLng1 = -0.0630, 111.4900
	sintangLat2, sintangLng2 = -0.0850, 111.5100
)

var (
	ride = tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 20}
	car  = tarifLayanan{Layanan: "BohCar", Base: 16000, PerKM: 3500, Pembulatan: 100, KomisiPersen: 20}
)

func TestJarakKM(t *testing.T) {
	got := jarakKM(sintangLat1, sintangLng1, sintangLat2, sintangLng2)
	if math.Abs(got-3.3) > 0.3 {
		t.Errorf("jarak = %.2f km, harusnya sekitar 3,3 km", got)
	}
	if d := jarakKM(1, 1, 1, 1); d != 0 {
		t.Errorf("titik yang sama harus berjarak 0, dapat %v", d)
	}
}

func TestHitungTarifIkutJarakDanLayanan(t *testing.T) {
	tarifRide := hitungTarif(ride, sintangLat1, sintangLng1, sintangLat2, sintangLng2)
	tarifCar := hitungTarif(car, sintangLat1, sintangLng1, sintangLat2, sintangLng2)

	if tarifRide <= ride.Base {
		t.Errorf("BohRide %v tidak boleh sama dengan atau di bawah tarif buka pintu %v", tarifRide, ride.Base)
	}
	if tarifCar <= tarifRide {
		t.Errorf("BohCar (%v) harus lebih mahal dari BohRide (%v)", tarifCar, tarifRide)
	}
	if math.Mod(tarifRide, 100) != 0 || math.Mod(tarifCar, 100) != 0 {
		t.Errorf("tarif harus bulat ke ratusan, dapat %v dan %v", tarifRide, tarifCar)
	}

	jauh := hitungTarif(ride, sintangLat1, sintangLng1, sintangLat2+0.05, sintangLng2)
	if jauh <= tarifRide {
		t.Errorf("tujuan lebih jauh (%v) harus lebih mahal dari yang dekat (%v)", jauh, tarifRide)
	}
}

// Harga bohRide dicocokkan dengan aplikasi lokal di Sintang: flat sampai 3 km,
// lalu naik Rp 1.000 tiap 400 m. Tabel ini yang menentukan benar atau tidaknya
// rumus baru; kalau ada baris meleset, tersangkanya pembulatan jarak atau
// pembulatan ongkos ke atas.
func TestOngkosBohRideCocokDenganHargaLokal(t *testing.T) {
	tr := tarifLayanan{
		Layanan: "BohRide", Base: 10000, PerKM: 2500, JarakDasarKM: 3,
		Pembulatan: 1000, KeAtas: true, KomisiPersen: 20, BiayaJasa: 1000,
	}
	// Kolom total adalah harga lokal yang ditiru dan tidak ikut komisi. Kolom
	// driver dan bohAntar mengikuti komisi 20% (keputusan user 9 Okt 2026); kalau
	// komisi diubah, cukup dua kolom itu yang dihitung ulang.
	kasus := []struct {
		meter                    float64
		total, driver, aplikator float64
	}{
		{1000, 11000, 8000, 3000},
		{3000, 11000, 8000, 3000},
		{3004, 11000, 8000, 3000}, // empat meter tidak boleh menambah seribu rupiah
		{3049, 11000, 8000, 3000},
		{3050, 12000, 8800, 3200},
		{3100, 12000, 8800, 3200},
		{3500, 13000, 9600, 3400},
		{4000, 14000, 10400, 3600},
		{5000, 16000, 12000, 4000},
		{6000, 19000, 14400, 4600},
		{10000, 29000, 22400, 6600},
	}
	for _, k := range kasus {
		ongkos := hitungOngkos(tr, k.meter)
		komisi := hitungKomisi(tr, ongkos)
		total := ongkos + tr.BiayaJasa
		driver := ongkos - komisi
		aplikator := komisi + tr.BiayaJasa

		if total != k.total || driver != k.driver || aplikator != k.aplikator {
			t.Errorf("%.0f m: total %.0f/%.0f, driver %.0f/%.0f, bohAntar %.0f/%.0f",
				k.meter, total, k.total, driver, k.driver, aplikator, k.aplikator)
		}
	}
}

// Layanan selain bohRide tidak ikut berubah. Angka di bawah adalah keluaran
// rumus lama (base + km x per_km, dibulatkan ke ratusan terdekat) yang direkam
// sebelum jarak dasar dan pembulatan ditambahkan.
func TestOngkosLayananLainTidakBergeser(t *testing.T) {
	lama := map[string][]float64{
		"BohAntar": {9000, 10000, 14000, 18000, 28000, 48000},
		"BohCar":   {17800, 19500, 26500, 33500, 51000, 86000},
		"BohFood":  {9000, 10000, 14000, 18000, 28000, 48000},
		"BohSend":  {9000, 10000, 14000, 18000, 28000, 48000},
	}
	jarakKM := []float64{0.5, 1, 3, 5, 10, 20}

	for _, tr := range tarifBawaan {
		harap, diuji := lama[tr.Layanan]
		if !diuji {
			continue
		}
		for i, km := range jarakKM {
			if got := hitungOngkos(tr, km*1000); got != harap[i] {
				t.Errorf("%s %.1f km = %.0f, sebelum perubahan %.0f", tr.Layanan, km, got, harap[i])
			}
		}
	}
}

// Rupiah tidak boleh hilang atau tercipta di pembulatan: apa pun persentasenya,
// bagian driver ditambah komisi harus sama persis dengan yang dibayar penumpang.
func TestKomisiDanBagianDriverSelaluGenap(t *testing.T) {
	persenUji := []float64{0, 12.5, 20, 33.33, 99.9, 100}
	fareUji := []float64{8000, 12300, 15700, 100000}

	for _, p := range persenUji {
		for _, fare := range fareUji {
			tr := tarifLayanan{Layanan: "BohRide", KomisiPersen: p}
			komisi := hitungKomisi(tr, fare)
			driver := fare - komisi

			if komisi < 0 || komisi > fare {
				t.Errorf("komisi %v di luar akal untuk fare %v pada %v%%", komisi, fare, p)
			}
			if driver < 0 {
				t.Errorf("driver dibayar minus (%v) untuk fare %v pada %v%%", driver, fare, p)
			}
			if komisi+driver != fare {
				t.Errorf("komisi %v + driver %v != fare %v pada %v%%", komisi, driver, fare, p)
			}
		}
	}
}

// Apa pun metode pembayarannya, aplikator harus mendapat tepat sebesar komisi
// — tidak lebih, tidak kurang. Ini invarian yang menjaga tunai dan dompet tetap
// setara secara pembukuan.
func TestBagiPembayaranSelaluMenyisakanKomisiUntukAplikator(t *testing.T) {
	kasus := []struct{ fare, komisi, biayaJasa float64 }{
		{18000, 3600, 1000},
		{8000, 0, 1000},
		{25000, 25000, 0},
		{12300, 4100, 2000},
		{15000, 1200, 1000}, // komisi 8% sesuai Perpres 27/2026
	}
	for _, k := range kasus {
		for _, metode := range []string{"wallet", "cash", "", "entah-apa"} {
			for _, talangan := range []float64{0, 45000} {
				debit, kredit := bagiPembayaran(metode, k.fare, k.komisi, talangan, k.biayaJasa)
				mau := k.komisi + k.biayaJasa
				if debit-kredit != mau {
					t.Errorf("metode %q fare %v komisi %v biayaJasa %v talangan %v: debit %v - kredit %v = %v, mau %v",
						metode, k.fare, k.komisi, k.biayaJasa, talangan, debit, kredit, debit-kredit, mau)
				}
			}
		}
	}
}

func TestBagiPembayaranTunaiTidakMenyentuhPenumpang(t *testing.T) {
	// Penumpang menyerahkan ongkos DAN biaya jasa tunai ke tangan driver, jadi
	// yang dipotong dari saldo driver adalah dua-duanya.
	debit, kredit := bagiPembayaran("cash", 20000, 4000, 0, 1000)
	if debit != 0 {
		t.Errorf("tunai tidak boleh mendebit saldo penumpang, dapat %v", debit)
	}
	if kredit != -5000 {
		t.Errorf("tunai harus mendebit komisi + biaya jasa dari driver (-5000), dapat %v", kredit)
	}

	// Metode kosong dari aplikasi versi lama harus diperlakukan sebagai tunai,
	// bukan diam-diam mendebit saldo penumpang.
	debitKosong, kreditKosong := bagiPembayaran("", 20000, 4000, 0, 1000)
	if debitKosong != debit || kreditKosong != kredit {
		t.Errorf("metode kosong harus sama dengan tunai, dapat debit %v kredit %v", debitKosong, kreditKosong)
	}
}

func TestBagiPembayaranDompetMemindahkanPenuh(t *testing.T) {
	debit, kredit := bagiPembayaran("wallet", 20000, 4000, 0, 1000)
	if debit != 21000 {
		t.Errorf("dompet harus mendebit ongkos + biaya jasa = 21000, dapat %v", debit)
	}
	// Biaya jasa tidak pernah jadi milik driver: bagiannya tetap fare - komisi.
	if kredit != 16000 {
		t.Errorf("driver harus menerima 16000, dapat %v", kredit)
	}
}

// Uang makanan BohFood lewat utuh dari penumpang ke driver yang sudah
// menalanginya — tidak dipotong komisi, dan tunai tidak menyentuh saldo siapa
// pun karena uangnya sudah berpindah tangan di pintu.
func TestBagiPembayaranTalanganLewatUtuh(t *testing.T) {
	debit, kredit := bagiPembayaran("wallet", 20000, 4000, 45000, 1000)
	if debit != 66000 || kredit != 61000 {
		t.Errorf("dompet: debit %v kredit %v, mau 66000 / 61000", debit, kredit)
	}
	if debit-kredit != 5000 {
		t.Errorf("aplikator dapat %v, harusnya komisi 4000 + biaya jasa 1000", debit-kredit)
	}
	debit, kredit = bagiPembayaran("cash", 20000, 4000, 45000, 1000)
	if debit != 0 || kredit != -5000 {
		t.Errorf("tunai: debit %v kredit %v, mau 0 / -5000", debit, kredit)
	}
}

func TestKomisiNolBerartiDriverDapatSemua(t *testing.T) {
	tr := tarifLayanan{Layanan: "BohRide", KomisiPersen: 0}
	if got := hitungKomisi(tr, 25000); got != 0 {
		t.Errorf("komisi 0%% harus menghasilkan 0, dapat %v", got)
	}
}

func TestTarifMasukAkalMenolakAngkaMerugikan(t *testing.T) {
	kasus := []struct {
		nama string
		in   tarifLayanan
		mau  bool
	}{
		{"wajar", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 20}, true},
		{"komisi 0 boleh", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 0}, true},
		{"komisi 100 boleh", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 100}, true},
		{"jarak dasar 3 km", tarifLayanan{Layanan: "BohRide", Base: 10000, PerKM: 2500, JarakDasarKM: 3, Pembulatan: 1000, KomisiPersen: 10}, true},
		{"jarak dasar negatif", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, JarakDasarKM: -1, Pembulatan: 100, KomisiPersen: 20}, false},
		{"pembulatan nol", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, Pembulatan: 0, KomisiPersen: 20}, false},
		{"komisi di atas 100", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 120}, false},
		{"komisi negatif", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: -5}, false},
		{"ongkos negatif", tarifLayanan{Layanan: "BohRide", Base: -1, PerKM: 2000, KomisiPersen: 20}, false},
		{"per km negatif", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: -2000, KomisiPersen: 20}, false},
		{"tanpa nama layanan", tarifLayanan{Base: 8000, PerKM: 2000, KomisiPersen: 20}, false},
	}
	for _, k := range kasus {
		if _, ok := tarifMasukAkal(k.in); ok != k.mau {
			t.Errorf("%s: tarifMasukAkal = %v, mau %v", k.nama, ok, k.mau)
		}
	}
}

func TestKoordinatValidMenolakNolDanLuarBumi(t *testing.T) {
	kasus := []struct {
		nama     string
		lat, lng float64
		mau      bool
	}{
		{"titik nol", 0, 0, false},
		{"lat di luar batas", 91, 100, false},
		{"lng di luar batas", -1, 181, false},
		{"sintang", sintangLat1, sintangLng1, true},
		{"khatulistiwa dengan lng sah", 0, 111.49, true},
	}
	for _, k := range kasus {
		if got := koordinatValid(k.lat, k.lng); got != k.mau {
			t.Errorf("%s: koordinatValid(%v, %v) = %v, mau %v", k.nama, k.lat, k.lng, got, k.mau)
		}
	}
}

// Gerbang saldo driver. Pesanan tunai menagih komisi dengan memotong saldo,
// jadi saldo yang tidak cukup berarti pesanannya tidak boleh diterima.
func TestSaldoCukupUntukKomisi(t *testing.T) {
	kasus := []struct {
		nama                    string
		metode                  string
		saldo, tertahan, komisi float64
		mau                     bool
	}{
		{"tunai saldo lebih", "cash", 50000, 0, 2800, true},
		{"tunai saldo pas", "cash", 2800, 0, 2800, true},
		{"tunai saldo kurang", "cash", 2000, 0, 2800, false},
		{"tunai saldo minus", "cash", -5000, 0, 2800, false},
		{"tunai saldo nol", "cash", 0, 0, 2800, false},
		{"tunai sisa habis oleh pesanan berjalan", "cash", 5000, 2800, 2800, false},
		{"tunai sisa masih cukup", "cash", 8000, 2800, 2800, true},
		{"dompet walau saldo nol", "wallet", 0, 0, 2800, true},
		{"dompet walau saldo minus", "wallet", -50000, 0, 2800, true},
		// Aplikasi versi lama mengirim metode kosong; itu berarti tunai, dan
		// harus ikut dijaga — bukan diam-diam lolos.
		{"metode kosong diperlakukan tunai", "", 2000, 0, 2800, false},
	}
	for _, k := range kasus {
		if got := saldoCukupUntukKomisi(k.metode, k.saldo, k.tertahan, k.komisi); got != k.mau {
			t.Errorf("%s: saldoCukupUntukKomisi(%q, %v, %v, %v) = %v, mau %v",
				k.nama, k.metode, k.saldo, k.tertahan, k.komisi, got, k.mau)
		}
	}
}

// Komisi nol (misalnya layanan yang digratiskan lewat tabel tarif) tidak boleh
// mengunci driver yang saldonya kosong.
func TestSaldoCukupUntukKomisiNolSelaluBoleh(t *testing.T) {
	if !saldoCukupUntukKomisi("cash", 0, 0, 0) {
		t.Error("komisi 0 harus selalu boleh diterima walau saldo kosong")
	}
}

// Waktu yang dikirim ke database harus berupa time.Time, bukan string RFC3339.
//
// Kolom updated_at jadi DATETIME sejak migrasi 002. String seperti
// "2026-09-19T10:16:04+07:00" diterima MySQL 8 (yang mendukung literal berzona
// waktu sejak 8.0.19) tapi DITOLAK MariaDB, yang dipakai produksi. Akibatnya
// menyimpan tarif dari dashboard gagal 500 di produksi sementara lolos mulus di
// lokal — persis jenis selisih yang paling lama ketahuan.
//
// Tes ini menjaga sifat yang diandalkan perbaikannya. Penolakan MariaDB-nya
// sendiri tidak bisa direproduksi di sini karena mesin ini cuma punya MySQL.
func TestWaktuUntukDBBukanStringMentah(t *testing.T) {
	v := waktuKeDB(time.Now().Format(time.RFC3339))
	if _, ok := v.(time.Time); !ok {
		t.Fatalf("waktuKeDB mengembalikan %T, harusnya time.Time — MariaDB menolak string berzona waktu", v)
	}
}

// Simpan lalu baca lagi, lewat jalur yang sama dengan tombol Simpan di
// dashboard. Yang dijaga: perubahannya benar-benar mendarat di database, dan
// updated_at terisi waktu yang masuk akal, bukan kosong atau nol.
func TestSimpanTarifBenarBenarTersimpan(t *testing.T) {
	bukaDBTes(t)
	const layanan = "BohRide"
	asli := ambilTarif(layanan)
	if asli.Layanan != layanan {
		t.Skip("baris tarif BohRide tidak ada di database ini")
	}
	t.Cleanup(func() { simpanTarif(asli) })

	ubah := asli
	ubah.KomisiPersen = 8 // batas Perpres 27/2026 untuk ojek roda dua
	if err := simpanTarif(ubah); err != nil {
		t.Fatalf("simpanTarif gagal: %v", err)
	}

	hasil := ambilTarif(layanan)
	if hasil.KomisiPersen != 8 {
		t.Fatalf("komisi tersimpan %v, harusnya 8", hasil.KomisiPersen)
	}
	if hasil.BiayaJasa != asli.BiayaJasa {
		t.Fatalf("biaya jasa berubah jadi %v padahal tidak disentuh, harusnya %v", hasil.BiayaJasa, asli.BiayaJasa)
	}
	if strings.TrimSpace(hasil.UpdatedAt) == "" {
		t.Fatal("updated_at kosong setelah disimpan")
	}
}

// Halaman tarif dan aplikasi penumpang tidak boleh punya rumusnya sendiri, jadi
// keduanya bergantung pada bentuk balasan endpoint ini. Yang diuji: angka yang
// BELUM disimpan benar-benar terbaca (struct tarif disematkan di badan JSON
// bersama km), dan hasilnya sama dengan hitungOngkos langsung.
func TestContohTarifMenghitungAngkaYangBelumDisimpan(t *testing.T) {
	badan := `{"layanan":"BohRide","base":10000,"per_km":2500,"jarak_dasar_km":3,
		"pembulatan":1000,"pembulatan_ke_atas":true,"komisi_persen":10,"biaya_jasa":1000,"km":5}`
	w := httptest.NewRecorder()
	adminTarifContohHandler(w, httptest.NewRequest("POST", "/api/admin/tarif/contoh", strings.NewReader(badan)))

	if w.Code != 200 {
		t.Fatalf("kode %d: %s", w.Code, w.Body.String())
	}
	var balasan struct {
		Rincian rincianTarif `json:"rincian"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &balasan); err != nil {
		t.Fatalf("balasan tidak terbaca: %s", w.Body.String())
	}
	// 5 km pada tarif bohRide: 10.000 + 2 km x 2.500 = 15.000, komisi 10%.
	if balasan.Rincian.Total != 16000 || balasan.Rincian.Driver != 13500 || balasan.Rincian.Platform != 2500 {
		t.Errorf("total %v driver %v platform %v, mau 16000 / 13500 / 2500",
			balasan.Rincian.Total, balasan.Rincian.Driver, balasan.Rincian.Platform)
	}
}

func TestContohTarifMenolakPembulatanNol(t *testing.T) {
	w := httptest.NewRecorder()
	adminTarifContohHandler(w, httptest.NewRequest("POST", "/api/admin/tarif/contoh",
		strings.NewReader(`{"layanan":"BohRide","base":8000,"per_km":2000,"pembulatan":0,"komisi_persen":20}`)))
	if w.Code != 400 {
		t.Fatalf("pembulatan 0 harus ditolak, dapat %d: %s", w.Code, w.Body.String())
	}
}
