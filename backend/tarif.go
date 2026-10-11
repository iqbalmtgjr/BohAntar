package main

import (
	"encoding/json"
	"math"
	"net/http"
	"strconv"
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
	Layanan string  `json:"layanan"`
	Base    float64 `json:"base"`   // ongkos buka pintu
	PerKM   float64 `json:"per_km"` // dikalikan jarak di luar jarak dasar; sekaligus knob kalibrasi
	// Kilometer pertama yang sudah termasuk buka pintu. 0 berarti per_km
	// dihitung sejak meter pertama, seperti sebelum kolom ini ada.
	JarakDasarKM int `json:"jarak_dasar_km"`
	// Kelipatan pembulatan ongkos dalam rupiah dan arahnya. 100 + terdekat
	// adalah perilaku lama; bohRide memakai 1000 ke atas supaya harganya jatuh
	// di angka bulat yang sama dengan aplikasi lokal.
	Pembulatan   int     `json:"pembulatan"`
	KeAtas       bool    `json:"pembulatan_ke_atas"`
	KomisiPersen float64 `json:"komisi_persen"` // bagian aplikator, sisanya untuk driver
	BiayaJasa    float64 `json:"biaya_jasa"`    // rupiah tetap dari penumpang, utuh ke aplikator
	UpdatedAt    string  `json:"updated_at"`
}

// tarifBawaan dipakai untuk mengisi tabel pertama kali, dan sebagai jaring
// pengaman kalau baris layanannya hilang — supaya order aneh tidak pernah
// jatuh ke tarif nol.
//
// biaya_jasa adalah rupiah tetap yang dibayar penumpang di luar ongkos dan
// masuk utuh ke aplikator, tidak dibagi dengan driver. Ia ada supaya pendapatan
// aplikator tidak seluruhnya bergantung pada persentase komisi, yang untuk ojek
// roda dua dibatasi 8% oleh Perpres 27/2026.
//
// Angka bohRide dicocokkan dengan harga aplikasi lokal di Sintang: 11.000 flat
// sampai 3 km, lalu naik Rp 1.000 tiap 400 m. Database yang sudah hidup tidak
// ikut berubah dari sini — INSERT IGNORE melewati baris yang sudah ada, jadi
// produksi mendapat angka ini lewat migrasi/009 atau lewat dashboard.
var tarifBawaan = []tarifLayanan{
	{Layanan: "BohRide", Base: 10000, PerKM: 2500, JarakDasarKM: 3, Pembulatan: 1000, KeAtas: true, KomisiPersen: 20, BiayaJasa: 1000},
	{Layanan: "BohCar", Base: 16000, PerKM: 3500, Pembulatan: 100, KomisiPersen: 20, BiayaJasa: 1000},
	{Layanan: "BohAntar", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 20, BiayaJasa: 1000},
	{Layanan: "BohSend", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 20, BiayaJasa: 1000},
	// Ongkir saja; harga makanannya milik warung dan tidak kena komisi.
	{Layanan: "BohFood", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 20, BiayaJasa: 1000},
	// Bukan layanan antar: cuma tempat menyimpan potongan pembayaran QR di
	// tempat, supaya super admin mengaturnya di halaman yang sama. Ongkosnya
	// nol, jadi createOrderHandler wajib menolaknya sebagai jenis pesanan.
	{Layanan: layananTagihanQR, Pembulatan: 100, KomisiPersen: 0},
}

// layananTagihanQR adalah nama baris tarif yang menyimpan persen potongan
// tagihan QR. Lihat komisiTagihan di tagihan.go.
const layananTagihanQR = "TagihanQR"

// Jaring pengaman kalau baris layanannya hilang. Sengaja tarif motor yang lama,
// bukan bohRide yang baru: baris hilang berarti ada yang salah, dan harga
// darurat sebaiknya yang paling konservatif, bukan yang paling mahal.
var tarifDefault = tarifLayanan{Layanan: "BohRide", Base: 8000, PerKM: 2000, Pembulatan: 100, KomisiPersen: 20, BiayaJasa: 1000}

// seedTarif mengisi tabel dengan nilai awal. INSERT IGNORE membuatnya idempoten:
// menjalankan ulang tidak menimpa angka yang sudah diubah super admin.
func seedTarif() {
	for _, t := range tarifBawaan {
		_, _ = db.Exec(
			"INSERT IGNORE INTO tarif (layanan, base, per_km, jarak_dasar_km, pembulatan, pembulatan_ke_atas, komisi_persen, biaya_jasa, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			t.Layanan, t.Base, t.PerKM, t.JarakDasarKM, t.Pembulatan, t.KeAtas, t.KomisiPersen, t.BiayaJasa, waktuKeDB(time.Now().Format(time.RFC3339)),
		)
	}
}

// ambilTarif membaca satu baris tarif. Sengaja tanpa cache: satu query empat
// kolom per pemesanan tidak terasa, dan cache berarti satu sumber basi lagi
// yang harus diingat untuk disegarkan setiap super admin menyimpan.
func ambilTarif(layanan string) tarifLayanan {
	var t tarifLayanan
	err := db.QueryRow(
		"SELECT "+kolomTarif+" FROM tarif WHERE layanan = ?",
		layanan,
	).Scan(&t.Layanan, &t.Base, &t.PerKM, &t.JarakDasarKM, &t.Pembulatan, &t.KeAtas, &t.KomisiPersen, &t.BiayaJasa, &t.UpdatedAt)
	if err != nil {
		return tarifDefault
	}
	return t
}

const kolomTarif = "layanan, base, per_km, COALESCE(jarak_dasar_km, 0), COALESCE(pembulatan, 100), COALESCE(pembulatan_ke_atas, 0), komisi_persen, COALESCE(biaya_jasa, 0), COALESCE(updated_at, '')"

func ambilSemuaTarif() ([]tarifLayanan, error) {
	rows, err := db.Query("SELECT " + kolomTarif + " FROM tarif ORDER BY layanan")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var hasil []tarifLayanan
	for rows.Next() {
		var t tarifLayanan
		if err := rows.Scan(&t.Layanan, &t.Base, &t.PerKM, &t.JarakDasarKM, &t.Pembulatan, &t.KeAtas, &t.KomisiPersen, &t.BiayaJasa, &t.UpdatedAt); err != nil {
			return nil, err
		}
		hasil = append(hasil, t)
	}
	return hasil, rows.Err()
}

// simpanTarif menulis satu baris tarif.
//
// Waktunya WAJIB lewat waktuKeDB. Kolom updated_at jadi DATETIME sejak migrasi
// 002, dan string RFC3339 mentah ("2026-09-19T10:16:04+07:00") diterima MySQL 8
// tapi DITOLAK MariaDB — yang dipakai produksi. Akibatnya menyimpan tarif dari
// dashboard gagal dengan 500 di produksi sementara lolos mulus di lokal.
func simpanTarif(t tarifLayanan) error {
	_, err := db.Exec(`
		INSERT INTO tarif (layanan, base, per_km, jarak_dasar_km, pembulatan, pembulatan_ke_atas, komisi_persen, biaya_jasa, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE base = VALUES(base), per_km = VALUES(per_km),
			jarak_dasar_km = VALUES(jarak_dasar_km), pembulatan = VALUES(pembulatan),
			pembulatan_ke_atas = VALUES(pembulatan_ke_atas),
			komisi_persen = VALUES(komisi_persen), biaya_jasa = VALUES(biaya_jasa),
			updated_at = VALUES(updated_at)
	`, t.Layanan, t.Base, t.PerKM, t.JarakDasarKM, t.Pembulatan, t.KeAtas, t.KomisiPersen, t.BiayaJasa, waktuKeDB(time.Now().Format(time.RFC3339)))
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
	if t.BiayaJasa < 0 {
		return "Biaya jasa aplikasi tidak boleh negatif", false
	}
	if t.JarakDasarKM < 0 {
		return "Jarak dasar tidak boleh negatif", false
	}
	// Nol akan jadi pembagian dengan nol di hitungOngkos. Fungsinya sendiri
	// tetap menjaga diri, tapi angkanya ditolak di sini supaya tidak pernah
	// sampai tersimpan dan membingungkan orang berikutnya yang membaca tabel.
	if t.Pembulatan < 1 {
		return "Pembulatan minimal 1 rupiah", false
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

// pembulatanJarakMeter membuang selisih beberapa meter yang tidak berarti
// sebelum jarak dipakai menghitung. Tanpa ini rute 3.004 m terbaca melewati
// jarak dasar 3 km dan menambah satu langkah tarif penuh untuk empat meter.
//
// Angkanya rekomendasi, belum dicocokkan dengan rute sungguhan di Sintang.
const pembulatanJarakMeter = 100

// hitungOngkos adalah satu-satunya tempat ongkos dihitung. Estimasi di aplikasi
// penumpang, pratinjau di dashboard, dan angka yang dikunci ke pesanan semuanya
// bermuara ke sini — kalau tidak, penumpang melihat satu angka lalu ditagih
// angka lain.
//
// Semuanya bilangan bulat. Versi float sempat menghasilkan 11000.000000000002
// yang naik jadi 12.000 begitu dibulatkan ke atas.
func hitungOngkos(t tarifLayanan, meter float64) float64 {
	if meter < 0 {
		meter = 0
	}
	m := int64(math.Round(meter))
	perKM := int64(math.Round(t.PerKM))
	kelipatan := int64(t.Pembulatan)
	if kelipatan < 1 {
		kelipatan = 1
	}

	// Pembulatan jarak hanya untuk layanan yang membulatkan ongkos ke atas.
	// Layanan lain dibiarkan seperti dulu supaya harganya tidak bergeser.
	if t.KeAtas {
		m = (m + pembulatanJarakMeter/2) / pembulatanJarakMeter * pembulatanJarakMeter
	}
	ekstra := m - int64(t.JarakDasarKM)*1000
	if ekstra < 0 {
		ekstra = 0
	}
	ongkos := int64(math.Round(t.Base)) + ekstra*perKM/1000
	if t.KeAtas {
		return float64((ongkos + kelipatan - 1) / kelipatan * kelipatan)
	}
	return float64((ongkos + kelipatan/2) / kelipatan * kelipatan)
}

// hitungTarif adalah hitungOngkos untuk dua titik koordinat: jaraknya garis
// lurus, bukan panjang jalan. Dipakai saat pesanan dibuat, jadi jarak yang
// sama harus dipakai juga oleh estimasi di aplikasi — lihat tarifEstimasiHandler.
func hitungTarif(t tarifLayanan, pickupLat, pickupLng, dropoffLat, dropoffLng float64) float64 {
	return hitungOngkos(t, jarakKM(pickupLat, pickupLng, dropoffLat, dropoffLng)*1000)
}

// bagiPembayaran menentukan perpindahan saldo saat pesanan ditutup: berapa yang
// didebit dari penumpang, dan berapa yang ditambahkan ke saldo driver — nilai
// negatif berarti saldo driver justru berkurang.
//
//	dompet — penumpang didebit penuh, driver dikredit ongkos dikurangi komisi.
//	tunai  — penumpang tidak disentuh karena sudah membayar langsung di jalan,
//	         dan driver didebit komisi yang kini ia utang ke aplikator.
//
// talangan adalah uang makanan BohFood yang sudah dibayar driver ke warung.
// Ia lewat begitu saja: penumpang membayarnya dan driver menerimanya utuh,
// tanpa komisi — aplikator tidak ikut memiliki sotonya.
//
// biayaJasa dibayar penumpang di luar ongkos dan tidak pernah jadi milik driver.
// Pada pesanan tunai penumpang menyerahkannya ke tangan driver bersama ongkos,
// jadi driver menampungnya sebentar dan menyetorkannya lewat saldo — sama
// seperti komisi.
//
// Apa pun metodenya, bagian aplikator selalu tepat sebesar tagihannya:
// debitPenumpang - kreditDriver == komisi + biayaJasa.
func bagiPembayaran(metode string, fare, komisi, talangan, biayaJasa float64) (debitPenumpang, kreditDriver float64) {
	if metode == "wallet" {
		return fare + biayaJasa + talangan, fare - komisi + talangan
	}
	return 0, -tagihanAplikator(komisi, biayaJasa)
}

// tagihanAplikator adalah total yang harus sampai ke bohAntar dari satu pesanan.
// Dipakai di tiga tempat yang harus selalu sepakat: pembagian saat pesanan
// ditutup, gerbang saldo saat driver menerima, dan jumlah yang tertahan oleh
// pesanan yang sedang berjalan.
func tagihanAplikator(komisi, biayaJasa float64) float64 {
	return komisi + biayaJasa
}

// saldoCukupUntukKomisi memutuskan apakah driver boleh menerima satu pesanan.
//
// Pesanan dompet selalu boleh: uangnya lewat aplikasi, dan saldo driver justru
// bertambah saat pesanan ditutup. Yang dijaga pesanan tunai — penumpang membayar
// langsung ke tangan driver, jadi komisinya hanya bisa ditagih dengan memotong
// saldo. Tanpa gerbang ini saldo driver bisa terus minus tanpa batas, dan
// menagihnya kembali berubah jadi urusan manusia, bukan urusan aplikasi.
func saldoCukupUntukKomisi(metode string, saldo, tertahan, tagihan float64) bool {
	if metode == "wallet" {
		return true
	}
	return saldo-tertahan >= tagihan
}

// hitungKomisi mengembalikan bagian aplikator, dibulatkan ke bawah ke rupiah
// utuh. Bagian driver selalu fare dikurangi angka ini, jadi tidak ada rupiah
// yang hilang atau tercipta di pembulatan.
//
// Persennya dikalikan seratus dulu supaya seluruh hitungan jadi bilangan bulat:
// 33,33% dari 100.000 sama dengan 33.330 tepat, sedangkan lewat float ia jatuh
// di 33.329,999999 dan pembulatan ke bawah mencuri satu rupiah.
func hitungKomisi(t tarifLayanan, fare float64) float64 {
	if t.KomisiPersen <= 0 {
		return 0
	}
	if t.KomisiPersen >= 100 {
		return fare
	}
	return float64(int64(math.Round(fare)) * int64(math.Round(t.KomisiPersen*100)) / 10000)
}

// ==================== RINCIAN UNTUK LAYAR ====================

// rincianTarif adalah satu hasil hitung yang siap ditampilkan: dipakai layar
// estimasi di aplikasi penumpang dan kolom contoh di dashboard, supaya tidak
// ada satu pun rumus yang perlu ditulis ulang di sisi klien.
type rincianTarif struct {
	KM        float64 `json:"km"`
	Ongkos    float64 `json:"ongkos"`
	BiayaJasa float64 `json:"biaya_jasa"`
	Total     float64 `json:"total"`    // yang dibayar penumpang
	Driver    float64 `json:"driver"`   // ongkos dikurangi komisi
	Platform  float64 `json:"platform"` // komisi ditambah biaya jasa
}

func hitungRincian(t tarifLayanan, meter float64) rincianTarif {
	ongkos := hitungOngkos(t, meter)
	komisi := hitungKomisi(t, ongkos)
	return rincianTarif{
		KM:        meter / 1000,
		Ongkos:    ongkos,
		BiayaJasa: t.BiayaJasa,
		Total:     ongkos + t.BiayaJasa,
		Driver:    ongkos - komisi,
		Platform:  komisi + t.BiayaJasa,
	}
}

// tarifEstimasiHandler: GET /api/tarif/estimasi?layanan=&from_lat=&from_lng=&to_lat=&to_lng=
//
// Aplikasi mengirim koordinat, bukan jarak, dan tidak menghitung apa pun
// sendiri. Jaraknya pun harus datang dari sini: Geolocator di HP memakai model
// bumi yang berbeda dari jarakKM dan melenceng ratusan meter di angka besar —
// cukup untuk menggeser satu langkah Rp 1.000 di dekat batas jarak dasar, dan
// penumpang melihat angka yang bukan angka yang ditagih.
func tarifEstimasiHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	fLat, fLng, ok1 := bacaKoordinat(r, "from_lat", "from_lng")
	tLat, tLng, ok2 := bacaKoordinat(r, "to_lat", "to_lng")
	if !ok1 || !ok2 {
		writeJSONResponse(w, 400, map[string]string{"error": "Titik jemput dan tujuan harus dipilih dari peta"})
		return
	}
	t := ambilTarif(r.URL.Query().Get("layanan"))
	writeJSONResponse(w, 200, map[string]interface{}{
		"status":  "success",
		"rincian": hitungRincian(t, jarakKM(fLat, fLng, tLat, tLng)*1000),
	})
}

// tarifPublikHandler: GET /api/tarif/publik?layanan=&km=
//
// Untuk kalkulator di halaman depan, yang dibuka tanpa login. Kalkulator itu
// dulu menyimpan angkanya sendiri dan langsung tertinggal begitu tarif diubah
// di dashboard. Yang dikirim cuma total yang dibayar penumpang — pembagian
// dengan driver bukan urusan pengunjung.
func tarifPublikHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	km, err := strconv.ParseFloat(r.URL.Query().Get("km"), 64)
	if err != nil || km <= 0 || km > 100 {
		writeJSONResponse(w, 400, map[string]string{"error": "Jarak harus di atas 0 dan paling jauh 100 km"})
		return
	}
	t := ambilTarif(r.URL.Query().Get("layanan"))
	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"km":     km,
		"total":  hitungRincian(t, km*1000).Total,
	})
}

// adminTarifContohHandler: POST /api/admin/tarif/contoh
//
// Pratinjau untuk angka yang BELUM disimpan, supaya super admin bisa mencari
// harga yang pas tanpa menerbitkan tarif percobaan ke penumpang yang sedang
// memesan. Tidak menyentuh database sama sekali.
func adminTarifContohHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input struct {
		tarifLayanan
		KM float64 `json:"km"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Data tarif tidak valid"})
		return
	}
	if pesan, ok := tarifMasukAkal(input.tarifLayanan); !ok {
		writeJSONResponse(w, 400, map[string]string{"error": pesan})
		return
	}
	if input.KM <= 0 {
		input.KM = 5
	}
	writeJSONResponse(w, 200, map[string]interface{}{
		"status":  "success",
		"rincian": hitungRincian(input.tarifLayanan, input.KM*1000),
	})
}

// ==================== LAPORAN BAGI HASIL ====================

type barisKomisi struct {
	DriverPhone string  `json:"driver_phone"`
	DriverName  string  `json:"driver_name"`
	OrderCount  int     `json:"order_count"`
	TotalOngkos float64 `json:"total_ongkos"`
	Komisi      float64 `json:"komisi"`
	BiayaJasa   float64 `json:"biaya_jasa"`   // pendapatan aplikator di luar komisi
	KomisiTunai float64 `json:"komisi_tunai"` // komisi + biaya jasa dari order tunai: belum di tangan
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
		       COALESCE(SUM(o.biaya_jasa), 0),
		       COALESCE(SUM(CASE WHEN o.payment_method = 'cash' THEN o.komisi + o.biaya_jasa ELSE 0 END), 0),
		       COALESCE(MAX(u.balance), 0)
		FROM orders o
		LEFT JOIN users u ON u.phone_number = o.driver_phone
		WHERE o.status = 'completed' AND o.driver_phone IS NOT NULL AND o.driver_phone <> ''
		  AND o.created_at >= ? AND o.created_at < DATE_ADD(?, INTERVAL 1 DAY)
		GROUP BY o.driver_phone, o.driver_name
		ORDER BY SUM(o.komisi + o.biaya_jasa) DESC`, from, to)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca laporan bagi hasil"})
		return
	}
	defer rows.Close()

	daftar := make([]barisKomisi, 0)
	var totalKomisi, totalBiayaJasa, totalTunai, totalOngkos float64
	totalOrder := 0
	for rows.Next() {
		var b barisKomisi
		if err := rows.Scan(&b.DriverPhone, &b.DriverName, &b.OrderCount, &b.TotalOngkos, &b.Komisi, &b.BiayaJasa, &b.KomisiTunai, &b.SaldoDriver); err != nil {
			continue
		}
		daftar = append(daftar, b)
		totalKomisi += b.Komisi
		totalBiayaJasa += b.BiayaJasa
		totalTunai += b.KomisiTunai
		totalOngkos += b.TotalOngkos
		totalOrder += b.OrderCount
	}

	tagihan, totalTagihan, komisiTagihan, err := laporanTagihanQR(from, to)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca laporan tagihan QR"})
		return
	}

	writeJSONResponse(w, 200, map[string]interface{}{
		"status":           "success",
		"from":             from,
		"to":               to,
		"total_komisi":     totalKomisi,
		"total_biaya_jasa": totalBiayaJasa,
		// Yang benar-benar jadi pendapatan bohAntar: komisi, biaya jasa, dan
		// potongan tagihan QR mitra.
		"total_pendapatan": totalKomisi + totalBiayaJasa + komisiTagihan,
		// Dari order tunai, jadi uangnya masih di tangan driver sampai ia setor.
		"komisi_tunai": totalTunai,
		// Potongan tagihan QR selalu di sini: tagihannya dibayar pakai saldo.
		"komisi_wallet":        (totalKomisi + totalBiayaJasa + komisiTagihan) - totalTunai,
		"total_ongkos":         totalOngkos,
		"total_order":          totalOrder,
		"drivers":              daftar,
		"total_komisi_tagihan": komisiTagihan,
		"total_tagihan":        totalTagihan,
		"tagihan_qr":           tagihan,
	})
}

type barisTagihanQR struct {
	PenerimaPhone string  `json:"penerima_phone"`
	PenerimaNama  string  `json:"penerima_nama"`
	Jumlah        int     `json:"jumlah"`
	Total         float64 `json:"total"`  // dibayar pemesan
	Komisi        float64 `json:"komisi"` // potongan bohAntar; mitra menerima total - komisi
}

// laporanTagihanQR menjumlah tagihan QR warung/rental yang DIBAYAR di rentang
// ini, per mitra penerima. Dihitung menurut paid_at, bukan created_at: tagihan
// yang kedaluwarsa tanpa dibayar tidak menghasilkan apa-apa. Potongannya
// dibaca dari tagihan_qr.komisi yang terkunci saat tagihan dibuat, jadi
// mengubah persen TagihanQR tidak menulis ulang bulan lalu.
func laporanTagihanQR(from, to string) ([]barisTagihanQR, float64, float64, error) {
	rows, err := db.Query(`
		SELECT penerima_phone, penerima_nama, COUNT(*), COALESCE(SUM(amount), 0), COALESCE(SUM(komisi), 0)
		FROM tagihan_qr
		WHERE paid_at >= ? AND paid_at < DATE_ADD(?, INTERVAL 1 DAY)
		GROUP BY penerima_phone, penerima_nama
		ORDER BY SUM(komisi) DESC, SUM(amount) DESC`, from, to)
	if err != nil {
		return nil, 0, 0, err
	}
	defer rows.Close()
	daftar := make([]barisTagihanQR, 0)
	var total, komisi float64
	for rows.Next() {
		var b barisTagihanQR
		if err := rows.Scan(&b.PenerimaPhone, &b.PenerimaNama, &b.Jumlah, &b.Total, &b.Komisi); err != nil {
			continue
		}
		daftar = append(daftar, b)
		total += b.Total
		komisi += b.Komisi
	}
	return daftar, total, komisi, rows.Err()
}
