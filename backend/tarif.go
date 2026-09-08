package main

import (
	"math"
	"net/http"
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

// ==================== LAPORAN BAGI HASIL ====================

type barisKomisi struct {
	DriverPhone string  `json:"driver_phone"`
	DriverName  string  `json:"driver_name"`
	OrderCount  int     `json:"order_count"`
	TotalOngkos float64 `json:"total_ongkos"`
	Komisi      float64 `json:"komisi"`
	KomisiTunai float64 `json:"komisi_tunai"`
	SaldoDriver float64 `json:"saldo_driver"`
}

// adminKomisiHandler melaporkan bagian aplikator dari pesanan yang selesai,
// dirinci per driver.
//
// Angkanya dijumlahkan dari kolom orders.komisi yang sudah terkunci sejak
// pesanan dibuat, bukan dihitung ulang dari persentase tarif hari ini —
// menaikkan komisi bulan depan tidak boleh menulis ulang pendapatan bulan lalu.
//
// Tunai dipisah karena uangnya belum tentu ada di tangan kami: penumpang
// membayar langsung ke driver dan komisinya cuma memotong saldo driver, jadi
// baru jadi uang setelah driver menyetor. Saldo driver ikut dikirim supaya yang
// masih berutang (saldo minus) kelihatan di baris yang sama.
func adminKomisiHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	now := time.Now()
	from := r.URL.Query().Get("from")
	to := r.URL.Query().Get("to")
	if from == "" {
		from = now.Format("2006-01") + "-01" // bawaan: bulan berjalan
	}
	if to == "" {
		to = now.Format("2006-01-02")
	}
	for _, d := range []string{from, to} {
		if _, err := time.Parse("2006-01-02", d); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Tanggal harus berformat YYYY-MM-DD"})
			return
		}
	}
	if from > to {
		writeJSONResponse(w, 400, map[string]string{"error": "Tanggal awal melewati tanggal akhir"})
		return
	}

	rows, err := db.Query(`
		SELECT o.driver_phone, COALESCE(o.driver_name, ''), COUNT(*),
		       COALESCE(SUM(o.fare), 0), COALESCE(SUM(o.komisi), 0),
		       COALESCE(SUM(CASE WHEN o.payment_method = 'cash' THEN o.komisi ELSE 0 END), 0),
		       COALESCE(MAX(u.balance), 0)
		FROM orders o
		LEFT JOIN users u ON u.phone_number = o.driver_phone
		WHERE o.status = 'completed' AND o.driver_phone IS NOT NULL AND o.driver_phone <> ''
		  AND o.created_at >= ? AND o.created_at < DATE_ADD(?, INTERVAL 1 DAY)
		GROUP BY o.driver_phone, o.driver_name
		ORDER BY SUM(o.komisi) DESC`, from, to)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca laporan bagi hasil"})
		return
	}
	defer rows.Close()

	daftar := make([]barisKomisi, 0)
	var totalKomisi, totalTunai, totalOngkos float64
	totalOrder := 0
	for rows.Next() {
		var b barisKomisi
		if err := rows.Scan(&b.DriverPhone, &b.DriverName, &b.OrderCount, &b.TotalOngkos, &b.Komisi, &b.KomisiTunai, &b.SaldoDriver); err != nil {
			continue
		}
		daftar = append(daftar, b)
		totalKomisi += b.Komisi
		totalTunai += b.KomisiTunai
		totalOngkos += b.TotalOngkos
		totalOrder += b.OrderCount
	}

	writeJSONResponse(w, 200, map[string]interface{}{
		"status":        "success",
		"from":          from,
		"to":            to,
		"total_komisi":  totalKomisi,
		"komisi_tunai":  totalTunai, // dipotong dari saldo driver, belum tentu disetor
		"komisi_wallet": totalKomisi - totalTunai,
		"total_ongkos":  totalOngkos,
		"total_order":   totalOrder,
		"drivers":       daftar,
	})
}
