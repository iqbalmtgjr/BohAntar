package main

import (
	"math"
	"time"
)

// ==================== TARIF & BAGI HASIL ====================
//
// Ongkos dihitung di sini, bukan diterima dari aplikasi. Sebelumnya
// createOrderHandler memakai angka `fare` kiriman HP apa adanya, jadi siapa pun
// yang bisa mengirim HTTP bisa memesan seharga satu rupiah dan driver yang
// menanggung.
//
// Angkanya tinggal di tabel `tarif`, bukan di kode, supaya super admin bisa
// mengubah ongkos dan persentase komisi lewat dashboard tanpa build ulang
// binary — harga BBM naik tidak seharusnya menuntut deploy.

type tarifLayanan struct {
	Layanan      string  `json:"layanan"`
	Base         float64 `json:"base"`          // ongkos buka pintu
	PerKM        float64 `json:"per_km"`        // dikalikan jarak; sekaligus knob kalibrasi
	KomisiPersen float64 `json:"komisi_persen"` // bagian aplikator, sisanya untuk driver
	UpdatedAt    string  `json:"updated_at"`
}

// tarifBawaan dipakai untuk mengisi tabel pertama kali, dan sebagai jaring
// pengaman kalau baris layanannya hilang — supaya order aneh tidak pernah
// jatuh ke tarif nol.
var tarifBawaan = []tarifLayanan{
	{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 20},
	{Layanan: "BohCar", Base: 16000, PerKM: 3500, KomisiPersen: 20},
	{Layanan: "BohAntar", Base: 8000, PerKM: 2000, KomisiPersen: 20},
	{Layanan: "BohSend", Base: 8000, PerKM: 2000, KomisiPersen: 20},
}

var tarifDefault = tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, KomisiPersen: 20}

// seedTarif mengisi tabel dengan nilai awal. INSERT IGNORE membuatnya idempoten:
// menjalankan ulang tidak menimpa angka yang sudah diubah super admin.
func seedTarif() {
	for _, t := range tarifBawaan {
		_, _ = db.Exec(
			"INSERT IGNORE INTO tarif (layanan, base, per_km, komisi_persen, updated_at) VALUES (?, ?, ?, ?, ?)",
			t.Layanan, t.Base, t.PerKM, t.KomisiPersen, time.Now().Format(time.RFC3339),
		)
	}
}

// ambilTarif membaca satu baris tarif. Sengaja tanpa cache: satu query empat
// kolom per pemesanan tidak terasa, dan cache berarti satu sumber basi lagi
// yang harus diingat untuk disegarkan setiap super admin menyimpan.
func ambilTarif(layanan string) tarifLayanan {
	var t tarifLayanan
	err := db.QueryRow(
		"SELECT layanan, base, per_km, komisi_persen, COALESCE(updated_at, '') FROM tarif WHERE layanan = ?",
		layanan,
	).Scan(&t.Layanan, &t.Base, &t.PerKM, &t.KomisiPersen, &t.UpdatedAt)
	if err != nil {
		return tarifDefault
	}
	return t
}

func ambilSemuaTarif() ([]tarifLayanan, error) {
	rows, err := db.Query("SELECT layanan, base, per_km, komisi_persen, COALESCE(updated_at, '') FROM tarif ORDER BY layanan")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var hasil []tarifLayanan
	for rows.Next() {
		var t tarifLayanan
		if err := rows.Scan(&t.Layanan, &t.Base, &t.PerKM, &t.KomisiPersen, &t.UpdatedAt); err != nil {
			return nil, err
		}
		hasil = append(hasil, t)
	}
	return hasil, rows.Err()
}

func simpanTarif(t tarifLayanan) error {
	_, err := db.Exec(`
		INSERT INTO tarif (layanan, base, per_km, komisi_persen, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE base = VALUES(base), per_km = VALUES(per_km),
			komisi_persen = VALUES(komisi_persen), updated_at = VALUES(updated_at)
	`, t.Layanan, t.Base, t.PerKM, t.KomisiPersen, time.Now().Format(time.RFC3339))
	return err
}

// tarifMasukAkal menjaga super admin dari salah ketik yang merugikan: ongkos
// negatif, atau komisi di luar 0–100% yang membuat driver dibayar minus.
func tarifMasukAkal(t tarifLayanan) (string, bool) {
	if t.Layanan == "" {
		return "Nama layanan tidak boleh kosong", false
	}
	if t.Base < 0 || t.PerKM < 0 {
		return "Ongkos tidak boleh negatif", false
	}
	if t.KomisiPersen < 0 || t.KomisiPersen > 100 {
		return "Komisi harus antara 0 dan 100 persen", false
	}
	return "", true
}

// jarakKM mengembalikan jarak lingkaran besar antara dua titik dalam kilometer.
//
// ponytail: garis lurus, bukan panjang jalan sungguhan. Selisihnya diserap
// per_km yang bisa diatur super admin — mengalikan jarak dengan 1,3 sama saja
// dengan menaikkan per_km 30%, jadi tidak perlu knob kedua. Ganti fungsi ini
// dengan jarak dari server rute sendiri begitu ada yang boleh dipakai produksi.
func jarakKM(lat1, lng1, lat2, lng2 float64) float64 {
	const radiusBumiKM = 6371.0
	const rad = math.Pi / 180
	dLat := (lat2 - lat1) * rad
	dLng := (lng2 - lng1) * rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLng/2)*math.Sin(dLng/2)
	return radiusBumiKM * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// koordinatValid menolak titik di luar bumi dan titik nol. Nol dipakai aplikasi
// lama sebagai "tidak diketahui", dan pernah juga muncul dari tujuan karangan
// ketika penumpang mengetik alamat tanpa memilih saran — order tanpa koordinat
// sungguhan tidak boleh punya harga.
func koordinatValid(lat, lng float64) bool {
	if lat == 0 && lng == 0 {
		return false
	}
	return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
}

// hitungTarif mengembalikan ongkos yang dibulatkan ke ratusan terdekat.
// Rumusnya harus sama persis dengan penaksir di
// mobile/lib/screens/order_ride_screen.dart supaya harga yang dilihat penumpang
// sebelum memesan sama dengan yang ditagih.
func hitungTarif(t tarifLayanan, pickupLat, pickupLng, dropoffLat, dropoffLng float64) float64 {
	km := jarakKM(pickupLat, pickupLng, dropoffLat, dropoffLng)
	return math.Round((t.Base+km*t.PerKM)/100) * 100
}

// bagiPembayaran menentukan perpindahan saldo saat pesanan ditutup: berapa yang
// didebit dari penumpang, dan berapa yang ditambahkan ke saldo driver — nilai
// negatif berarti saldo driver justru berkurang.
//
//	dompet — penumpang didebit penuh, driver dikredit ongkos dikurangi komisi.
//	tunai  — penumpang tidak disentuh karena sudah membayar langsung di jalan,
//	         dan driver didebit komisi yang kini ia utang ke aplikator.
//
// Apa pun metodenya, bagian aplikator selalu tepat sebesar komisi:
// debitPenumpang - kreditDriver == komisi.
func bagiPembayaran(metode string, fare, komisi float64) (debitPenumpang, kreditDriver float64) {
	if metode == "wallet" {
		return fare, fare - komisi
	}
	return 0, -komisi
}

// hitungKomisi mengembalikan bagian aplikator, dibulatkan ke rupiah utuh.
// Bagian driver selalu fare dikurangi angka ini, jadi tidak ada rupiah yang
// hilang atau tercipta di pembulatan.
func hitungKomisi(t tarifLayanan, fare float64) float64 {
	if t.KomisiPersen <= 0 {
		return 0
	}
	if t.KomisiPersen >= 100 {
		return fare
	}
	return math.Round(fare * t.KomisiPersen / 100)
}
