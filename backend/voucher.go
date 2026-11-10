package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Voucher diskon: dibuat super admin dari dashboard (halaman Voucher Diskon),
// dipakai OTOMATIS saat penumpang memesan — tanpa kode yang harus diketik.
// Kalau beberapa voucher cocok, yang diskonnya paling besar yang dipakai;
// satu pesanan satu voucher.
//
// Diskon ditanggung BohAntar, bukan driver. Penumpang membayar tunai lebih
// sedikit, dan potongan saldo driver saat pesanan selesai berkurang sebesar
// diskonnya (lihat completeOrder), jadi pendapatan driver tetap ongkos dikurangi
// komisi. Diskon yang melebihi komisi + biaya jasa jadi kredit di saldo komisi
// driver.
//
// Hanya pesanan dari aplikasi penumpang (createOrderHandler). Pesanan manual
// admin dan kurir toko Kasvo tidak pernah kena voucher.

type Voucher struct {
	ID          string  `json:"id"`
	Judul       string  `json:"judul"`        // tampil di aplikasi: "Diskon <judul>"
	Layanan     string  `json:"layanan"`      // "" = semua layanan
	Jenis       string  `json:"jenis"`        // "persen" | "nominal"
	Nilai       float64 `json:"nilai"`        // persen (0–100] atau rupiah
	MaksDiskon  float64 `json:"maks_diskon"`  // batas rupiah untuk jenis persen; 0 = tanpa batas
	MinBelanja  float64 `json:"min_belanja"`  // dibanding total sebelum diskon (ongkos + biaya jasa + makanan)
	Kuota       int     `json:"kuota"`        // pesanan seluruhnya; 0 = tanpa batas
	PerPengguna int     `json:"per_pengguna"` // kali per penumpang; 0 = tanpa batas
	Mulai       string  `json:"mulai"`        // YYYY-MM-DD; "" = sejak dibuat
	Selesai     string  `json:"selesai"`      // YYYY-MM-DD, hari itu masih berlaku; "" = tanpa akhir
	Aktif       bool    `json:"aktif"`
	Terpakai    int     `json:"terpakai"` // hanya dibaca: pesanan yang tidak batal/kedaluwarsa
}

const skemaVoucher = `CREATE TABLE IF NOT EXISTS voucher (
	id VARCHAR(64) PRIMARY KEY,
	judul VARCHAR(80) NOT NULL,
	layanan VARCHAR(20) NOT NULL DEFAULT '',
	jenis VARCHAR(10) NOT NULL DEFAULT 'nominal',
	nilai DECIMAL(12,2) NOT NULL DEFAULT 0,
	maks_diskon DECIMAL(12,2) NOT NULL DEFAULT 0,
	min_belanja DECIMAL(12,2) NOT NULL DEFAULT 0,
	kuota INT NOT NULL DEFAULT 0,
	per_pengguna INT NOT NULL DEFAULT 1,
	mulai DATE NULL,
	selesai DATE NULL,
	aktif TINYINT(1) NOT NULL DEFAULT 1,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) DEFAULT CHARSET=utf8mb4`

// migrasiVoucher: tabel voucher dan dua kolom di orders. Dipanggil initDB dan
// bukaDBTes — orders.diskon dibaca semua kueri pesanan.
func migrasiVoucher() {
	migrasiSkema("ALTER TABLE orders ADD COLUMN diskon DECIMAL(12,2) NOT NULL DEFAULT 0")
	migrasiSkema("ALTER TABLE orders ADD COLUMN voucher_id VARCHAR(64) NULL")
	migrasiSkema("ALTER TABLE orders ADD COLUMN voucher_pemakai CHAR(64) NULL") // lihat kunciPemakai
	migrasiSkema("ALTER TABLE orders ADD INDEX idx_orders_voucher (voucher_id)")
	migrasiSkema(skemaVoucher)
}

var layananVoucher = map[string]bool{"": true, "BohRide": true, "BohCar": true, "BohFood": true, "BohSend": true, "BohAntar": true}

// periksaVoucher merapikan isian dan mengembalikan pesan galat untuk admin.
func periksaVoucher(v *Voucher) string {
	v.Judul = strings.TrimSpace(v.Judul)
	v.Mulai = strings.TrimSpace(v.Mulai)
	v.Selesai = strings.TrimSpace(v.Selesai)
	tanggalOK := func(s string) bool {
		if s == "" {
			return true
		}
		_, err := time.Parse("2006-01-02", s)
		return err == nil
	}
	switch {
	case v.Judul == "" || utf8.RuneCountInString(v.Judul) > 80:
		return "Nama voucher wajib diisi, maksimal 80 karakter"
	case !layananVoucher[v.Layanan]:
		return "Layanan tidak dikenal"
	case v.Jenis != "persen" && v.Jenis != "nominal":
		return "Jenis diskon harus persen atau nominal"
	case v.Nilai <= 0:
		return "Besar diskon harus lebih dari 0"
	case v.Jenis == "persen" && v.Nilai > 100:
		return "Diskon persen maksimal 100"
	case v.MaksDiskon < 0 || v.MinBelanja < 0:
		return "Maks. diskon dan min. belanja tidak boleh negatif"
	case v.Kuota < 0 || v.PerPengguna < 0:
		return "Kuota tidak boleh negatif"
	case !tanggalOK(v.Mulai) || !tanggalOK(v.Selesai):
		return "Tanggal harus berformat YYYY-MM-DD"
	case v.Mulai != "" && v.Selesai != "" && v.Mulai > v.Selesai:
		return "Tanggal mulai melewati tanggal selesai"
	}
	if v.Jenis == "nominal" {
		v.MaksDiskon = 0
	}
	return ""
}

// hitungDiskon: berapa rupiah yang dipotong voucher dari total sebelum diskon.
// Persen dihitung dengan bilangan bulat seperti hitungKomisi, dibulatkan ke
// bawah, dan diskon tidak pernah melebihi totalnya sendiri.
func hitungDiskon(v Voucher, dasar float64) float64 {
	if dasar <= 0 || dasar < v.MinBelanja {
		return 0
	}
	d := v.Nilai
	if v.Jenis == "persen" {
		d = float64(int64(math.Round(dasar)) * int64(math.Round(v.Nilai*100)) / 10000)
		if v.MaksDiskon > 0 && d > v.MaksDiskon {
			d = v.MaksDiskon
		}
	}
	return math.Min(math.Floor(d), dasar)
}

const kolomVoucher = "id, judul, layanan, jenis, nilai, maks_diskon, min_belanja, kuota, per_pengguna, COALESCE(DATE_FORMAT(mulai, '%Y-%m-%d'), ''), COALESCE(DATE_FORMAT(selesai, '%Y-%m-%d'), ''), aktif"

func scanVoucher(rows *sql.Rows) ([]Voucher, error) {
	defer rows.Close()
	daftar := []Voucher{}
	for rows.Next() {
		var v Voucher
		if err := rows.Scan(&v.ID, &v.Judul, &v.Layanan, &v.Jenis, &v.Nilai, &v.MaksDiskon, &v.MinBelanja, &v.Kuota, &v.PerPengguna, &v.Mulai, &v.Selesai, &v.Aktif); err != nil {
			return nil, err
		}
		daftar = append(daftar, v)
	}
	return daftar, rows.Err()
}

// Pesanan yang batal atau kedaluwarsa mengembalikan kuotanya.
const pesananVoucherSah = "voucher_id = ? AND status NOT IN ('cancelled', 'expired')"

// voucherMasihAda memeriksa kuota total dan jatah per penumpang. Dihitung dari
// tabel orders (bukan kolom penghitung) supaya pembatalan mengembalikan kuota
// tanpa kode tambahan. Kueri terpisah dengan parameter, bukan JOIN: tabel baru
// di produksi bisa beda collation dengan orders (MariaDB galat 1267).
func voucherMasihAda(v Voucher, phone string) bool {
	var n int
	if v.Kuota > 0 {
		if db.QueryRow("SELECT COUNT(*) FROM orders WHERE "+pesananVoucherSah, v.ID).Scan(&n) != nil || n >= v.Kuota {
			return false
		}
	}
	if v.PerPengguna > 0 {
		if db.QueryRow("SELECT COUNT(*) FROM orders WHERE "+pesananVoucherSah+" AND voucher_pemakai = ?", v.ID, kunciPemakai(phone)).Scan(&n) != nil || n >= v.PerPengguna {
			return false
		}
	}
	return true
}

// kunciPemakai: sidik nomor HP untuk menghitung jatah per pelanggan, disimpan
// di orders.voucher_pemakai saat pesanan bervoucher dibuat. Bukan rider_phone:
// hapusAkun mengosongkan rider_phone, jadi hapus akun lalu daftar ulang dengan
// nomor yang sama akan mendapat jatah baru. HMAC dengan kunci token, bukan
// nomor mentah, supaya tidak ada nomor HP yang tertinggal setelah akun dihapus.
//
// ponytail: mengganti JWT_SECRET ikut mengatur ulang jatah per pelanggan.
func kunciPemakai(phone string) string {
	m := hmac.New(sha256.New, jwtKey)
	m.Write([]byte(phone))
	return hex.EncodeToString(m.Sum(nil))
}

// pilihVoucher mencari voucher dengan diskon terbesar untuk satu pesanan.
// Galat database tidak pernah menggagalkan pesanan — paling buruk penumpang
// membayar harga penuh, sama seperti sebelum fitur ini ada.
//
// dasar = ongkos + biaya jasa + makanan (untuk min. belanja dan persen);
// batas = ongkos + biaya jasa. Diskon tidak boleh memakan uang makanan
// BohFood: driver sudah menalanginya tunai ke warung, dan kelebihannya hanya
// bisa dikembalikan sebagai saldo komisi yang tidak bisa dicairkan.
func pilihVoucher(phone, layanan string, dasar, batas float64) (Voucher, float64) {
	hariIni := time.Now().Format("2006-01-02")
	rows, err := db.Query("SELECT "+kolomVoucher+" FROM voucher WHERE aktif = 1 AND (layanan = '' OR layanan = ?)"+
		" AND (mulai IS NULL OR mulai <= ?) AND (selesai IS NULL OR selesai >= ?)", layanan, hariIni, hariIni)
	if err != nil {
		log.Printf("Voucher gagal dibaca, pesanan tanpa diskon: %v", err)
		return Voucher{}, 0
	}
	calon, err := scanVoucher(rows)
	if err != nil {
		log.Printf("Voucher gagal dibaca, pesanan tanpa diskon: %v", err)
		return Voucher{}, 0
	}
	var terbaik Voucher
	var diskon float64
	for _, v := range calon {
		if d := math.Min(hitungDiskon(v, dasar), batas); d > diskon && voucherMasihAda(v, phone) {
			terbaik, diskon = v, d
		}
	}
	return terbaik, diskon
}

// voucherMu menyerialkan "periksa kuota lalu simpan pesanan". Tanpa ini dua
// pesanan di milidetik yang sama sama-sama melihat sisa satu kuota, atau satu
// penumpang mengirim dua pesanan sekaligus untuk memakai voucher sekali-pakai
// dua kali.
//
// ponytail: satu kunci untuk semua pemesanan, hanya di proses ini — backend
// memang satu binary di satu mesin (sama seperti gerbangSaldoMu). Isinya
// beberapa kueri singkat. Ganti dengan SELECT ... FOR UPDATE kalau ada lebih
// dari satu instance.
var voucherMu sync.Mutex

func daftarVoucher() ([]Voucher, error) {
	rows, err := db.Query("SELECT " + kolomVoucher + " FROM voucher ORDER BY created_at DESC")
	if err != nil {
		return nil, err
	}
	daftar, err := scanVoucher(rows)
	if err != nil {
		return nil, err
	}
	// Satu GROUP BY di orders, bukan subkueri ke tabel voucher (collation).
	pakai, err := db.Query("SELECT voucher_id, COUNT(*) FROM orders WHERE voucher_id IS NOT NULL AND status NOT IN ('cancelled', 'expired') GROUP BY voucher_id")
	if err != nil {
		return nil, err
	}
	defer pakai.Close()
	jumlah := map[string]int{}
	for pakai.Next() {
		var id string
		var n int
		if pakai.Scan(&id, &n) == nil {
			jumlah[id] = n
		}
	}
	for i := range daftar {
		daftar[i].Terpakai = jumlah[daftar[i].ID]
	}
	return daftar, pakai.Err()
}

func simpanVoucher(id string, v Voucher) error {
	_, err := db.Exec(`INSERT INTO voucher (id, judul, layanan, jenis, nilai, maks_diskon, min_belanja, kuota, per_pengguna, mulai, selesai, aktif)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE judul = VALUES(judul), layanan = VALUES(layanan), jenis = VALUES(jenis), nilai = VALUES(nilai),
			maks_diskon = VALUES(maks_diskon), min_belanja = VALUES(min_belanja), kuota = VALUES(kuota),
			per_pengguna = VALUES(per_pengguna), mulai = VALUES(mulai), selesai = VALUES(selesai), aktif = VALUES(aktif)`,
		id, v.Judul, v.Layanan, v.Jenis, v.Nilai, v.MaksDiskon, v.MinBelanja, v.Kuota, v.PerPengguna,
		kosongJadiNULL(v.Mulai), kosongJadiNULL(v.Selesai), v.Aktif)
	return err
}

// adminVoucherHandler: GET (semua) dan POST (baru) /api/admin/voucher;
// PUT dan DELETE /api/admin/voucher/{id}.
func adminVoucherHandler(w http.ResponseWriter, r *http.Request) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/admin/voucher"), "/")
	switch {
	case r.Method == http.MethodGet && id == "":
		daftar, err := daftarVoucher()
		if err != nil {
			log.Printf("Voucher gagal dibaca: %v", err)
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal memuat voucher"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "voucher": daftar})

	case (r.Method == http.MethodPost && id == "") || (r.Method == http.MethodPut && id != ""):
		var v Voucher
		if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data voucher tidak terbaca"})
			return
		}
		if pesan := periksaVoucher(&v); pesan != "" {
			writeJSONResponse(w, 400, map[string]string{"error": pesan})
			return
		}
		if id == "" {
			id = newID("vc")
		} else if err := db.QueryRow("SELECT id FROM voucher WHERE id = ?", id).Scan(&id); err == sql.ErrNoRows {
			// Tanpa ini PUT ke id karangan diam-diam membuat voucher baru.
			writeJSONResponse(w, 404, map[string]string{"error": "Voucher tidak ditemukan"})
			return
		}
		if err := simpanVoucher(id, v); err != nil {
			log.Printf("Voucher %s gagal disimpan: %v", id, err)
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan voucher"})
			return
		}
		v.ID = id
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "voucher": v})

	case r.Method == http.MethodDelete && id != "":
		// Pesanan lama tetap menyimpan diskon dan voucher_id-nya; laporan
		// bagi hasil membaca orders.diskon, jadi angkanya tidak ikut hilang.
		res, err := db.Exec("DELETE FROM voucher WHERE id = ?", id)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menghapus voucher"})
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeJSONResponse(w, 404, map[string]string{"error": "Voucher tidak ditemukan"})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success"})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}
