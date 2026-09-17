package main

import (
	"math"
	"testing"
)

// Dua titik di Sintang berjarak kira-kira 3,3 km garis lurus.
const (
	sintangLat1, sintangLng1 = -0.0630, 111.4900
	sintangLat2, sintangLng2 = -0.0850, 111.5100
)

var (
	ride = tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 20}
	car  = tarifLayanan{Layanan: "BohCar", Base: 16000, PerKM: 3500, KomisiPersen: 20}
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
		{"wajar", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 20}, true},
		{"komisi 0 boleh", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 0}, true},
		{"komisi 100 boleh", tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 100}, true},
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
