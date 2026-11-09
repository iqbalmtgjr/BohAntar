package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Kelola menu warung BohFood (non-Kasvo), setara halaman Kasvo (9 Nov 2026):
//   - kategori ber-urutan yang bisa dinonaktifkan (menunya ikut tersembunyi);
//   - grup varian ("Level pedas", "Topping") milik warung, dipakai bersama
//     banyak menu, tiap opsi bisa dimatikan sendiri;
//   - menu dengan status aktif (tampil/tidak di aplikasi) yang terpisah dari
//     tanda habis (tampil, tapi abu-abu dan tidak bisa dipesan).
//
// Nama kategori tetap disimpan sebagai teks di food_menus.category — kolom yang
// dibaca aplikasi sejak awal — supaya aplikasi tidak perlu dirilis ulang. Tabel
// food_kategori hanya menambahkan urutan dan status.
//
// Tabel-tabel baru ini sengaja tidak di-JOIN ke tabel lama pada kolom teks: di
// MariaDB produksi tabel baru bisa lahir dengan collation berbeda (galat 1267).
// Semua penghubung lewat parameter, atau antar tabel baru saja. Karena alasan
// yang sama tidak ada foreign key ke food_menus/food_merchants (galat 1833);
// pembersihan dilakukan kode saat menu atau grup dihapus.

func migrasiMenuWarung() {
	migrasiSkema("ALTER TABLE food_menus ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE")
	migrasiSkema(`CREATE TABLE IF NOT EXISTS food_kategori (
		id VARCHAR(50) PRIMARY KEY,
		merchant_id VARCHAR(50) NOT NULL,
		nama VARCHAR(50) NOT NULL,
		urutan INT NOT NULL DEFAULT 0,
		is_active BOOLEAN NOT NULL DEFAULT TRUE,
		UNIQUE KEY uq_food_kategori (merchant_id, nama)
	)`)
	migrasiSkema(`CREATE TABLE IF NOT EXISTS food_grup_opsi (
		id VARCHAR(50) PRIMARY KEY,
		merchant_id VARCHAR(50) NOT NULL,
		nama VARCHAR(50) NOT NULL,
		tipe VARCHAR(10) NOT NULL DEFAULT 'single',
		wajib BOOLEAN NOT NULL DEFAULT FALSE,
		min_pilih INT NOT NULL DEFAULT 0,
		max_pilih INT NOT NULL DEFAULT 0,
		urutan INT NOT NULL DEFAULT 0,
		INDEX idx_food_grup_merchant (merchant_id)
	)`)
	migrasiSkema(`CREATE TABLE IF NOT EXISTS food_opsi (
		id VARCHAR(50) PRIMARY KEY,
		grup_id VARCHAR(50) NOT NULL,
		nama VARCHAR(50) NOT NULL,
		harga DECIMAL(12,2) NOT NULL DEFAULT 0,
		is_active BOOLEAN NOT NULL DEFAULT TRUE,
		urutan INT NOT NULL DEFAULT 0,
		INDEX idx_food_opsi_grup (grup_id)
	)`)
	migrasiSkema(`CREATE TABLE IF NOT EXISTS food_menu_grup (
		menu_id VARCHAR(50) NOT NULL,
		grup_id VARCHAR(50) NOT NULL,
		urutan INT NOT NULL DEFAULT 0,
		PRIMARY KEY (menu_id, grup_id),
		INDEX idx_food_menu_grup_grup (grup_id)
	)`)
}

// ==================== BACA ====================

type kategoriWarung struct {
	ID       string `json:"id"`
	Nama     string `json:"nama"`
	Urutan   int    `json:"urutan"`
	Aktif    bool   `json:"is_active"`
	JmlMenu  int    `json:"jumlah_menu"`
	JmlAktif int    `json:"jumlah_aktif"`
}

type opsiWarung struct {
	ID    string  `json:"id"`
	Nama  string  `json:"nama"`
	Harga float64 `json:"harga"`
	Aktif bool    `json:"is_active"`
}

type grupWarung struct {
	ID      string       `json:"id"`
	Nama    string       `json:"nama"`
	Tipe    string       `json:"tipe"` // "single" / "multiple"
	Wajib   bool         `json:"wajib"`
	Min     int          `json:"min"`
	Max     int          `json:"max"` // multiple: 0 = tanpa batas
	Opsi    []opsiWarung `json:"opsi"`
	MenuIDs []string     `json:"menu_ids"`
}

// dbKategoriWarung membaca kategori warung, sekaligus mencatat kategori yang
// baru dikenal dari menu (menu lama sebelum tabel ini ada, atau kategori yang
// diketik di formulir menu) supaya selalu bisa diurutkan dan dinonaktifkan.
func dbKategoriWarung(merchantID string) ([]kategoriWarung, error) {
	jumlah := map[string][2]int{}
	rows, err := db.Query("SELECT COALESCE(category, ''), COUNT(*), COALESCE(SUM(is_active), 0) FROM food_menus WHERE merchant_id = ? GROUP BY category", merchantID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var nama string
		var n, aktif int
		if rows.Scan(&nama, &n, &aktif) == nil && strings.TrimSpace(nama) != "" {
			jumlah[nama] = [2]int{n, aktif}
		}
	}
	rows.Close()
	for nama := range jumlah {
		pastikanKategori(merchantID, nama)
	}

	rows, err = db.Query("SELECT id, nama, urutan, is_active FROM food_kategori WHERE merchant_id = ? ORDER BY urutan, nama", merchantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	daftar := []kategoriWarung{}
	for rows.Next() {
		var k kategoriWarung
		if rows.Scan(&k.ID, &k.Nama, &k.Urutan, &k.Aktif) == nil {
			k.JmlMenu, k.JmlAktif = jumlah[k.Nama][0], jumlah[k.Nama][1]
			daftar = append(daftar, k)
		}
	}
	return daftar, rows.Err()
}

// pastikanKategori mencatat kategori kalau belum ada, di urutan paling akhir.
func pastikanKategori(merchantID, nama string) {
	var akhir int
	db.QueryRow("SELECT COALESCE(MAX(urutan), 0) FROM food_kategori WHERE merchant_id = ?", merchantID).Scan(&akhir)
	db.Exec("INSERT IGNORE INTO food_kategori (id, merchant_id, nama, urutan, is_active) VALUES (?, ?, ?, ?, TRUE)",
		newID("kat"), merchantID, nama, akhir+1)
}

// dbGrupWarung membaca semua grup varian warung beserta opsi (yang mati juga)
// dan menu yang memakainya.
func dbGrupWarung(merchantID string) ([]grupWarung, error) {
	rows, err := db.Query("SELECT id, nama, tipe, wajib, min_pilih, max_pilih FROM food_grup_opsi WHERE merchant_id = ? ORDER BY urutan, nama", merchantID)
	if err != nil {
		return nil, err
	}
	daftar := []grupWarung{}
	indeks := map[string]int{}
	for rows.Next() {
		g := grupWarung{Opsi: []opsiWarung{}, MenuIDs: []string{}}
		if rows.Scan(&g.ID, &g.Nama, &g.Tipe, &g.Wajib, &g.Min, &g.Max) == nil {
			indeks[g.ID] = len(daftar)
			daftar = append(daftar, g)
		}
	}
	rows.Close()

	rows, err = db.Query(`SELECT o.id, o.grup_id, o.nama, o.harga, o.is_active FROM food_opsi o
		JOIN food_grup_opsi g ON g.id = o.grup_id WHERE g.merchant_id = ? ORDER BY o.urutan, o.nama`, merchantID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var o opsiWarung
		var grup string
		if rows.Scan(&o.ID, &grup, &o.Nama, &o.Harga, &o.Aktif) == nil {
			if i, ada := indeks[grup]; ada {
				daftar[i].Opsi = append(daftar[i].Opsi, o)
			}
		}
	}
	rows.Close()

	rows, err = db.Query(`SELECT mg.menu_id, mg.grup_id FROM food_menu_grup mg
		JOIN food_grup_opsi g ON g.id = mg.grup_id WHERE g.merchant_id = ? ORDER BY mg.urutan`, merchantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var menu, grup string
		if rows.Scan(&menu, &grup) == nil {
			if i, ada := indeks[grup]; ada {
				daftar[i].MenuIDs = append(daftar[i].MenuIDs, menu)
			}
		}
	}
	return daftar, rows.Err()
}

// dbMenuWarung: menu warung beserta variannya. semua=false adalah yang dilihat
// pemesan (dan satu-satunya yang boleh dipesan): menu aktif di kategori aktif,
// hanya opsi yang aktif, dan grup tanpa satu pun opsi aktif dibuang — grup
// wajib yang kosong membuat menunya mustahil dipesan. semua=true untuk portal
// pemiliknya.
func dbMenuWarung(merchantID string, semua bool) ([]FoodMenu, error) {
	kategori, err := dbKategoriWarung(merchantID)
	if err != nil {
		return nil, err
	}
	urutanKat := map[string]int{}
	katAktif := map[string]bool{}
	for _, k := range kategori {
		urutanKat[k.Nama], katAktif[k.Nama] = k.Urutan, k.Aktif
	}
	grup, err := dbGrupWarung(merchantID)
	if err != nil {
		return nil, err
	}
	grupMenu := map[string][]GrupOpsi{}
	idGrupMenu := map[string][]string{}
	for _, g := range grup {
		var opsi []OpsiMenu
		for _, o := range g.Opsi {
			if o.Aktif {
				opsi = append(opsi, OpsiMenu{ID: o.ID, Name: o.Nama, Price: o.Harga})
			}
		}
		for _, menuID := range g.MenuIDs {
			idGrupMenu[menuID] = append(idGrupMenu[menuID], g.ID)
			if len(opsi) > 0 {
				grupMenu[menuID] = append(grupMenu[menuID], GrupOpsi{ID: g.ID, Name: g.Nama, Type: g.Tipe, Required: g.Wajib, Min: g.Min, Max: g.Max, Options: opsi})
			}
		}
	}

	rows, err := db.Query("SELECT id, merchant_id, name, COALESCE(description, ''), price, COALESCE(category, ''), COALESCE(image_url, ''), is_available, is_active FROM food_menus WHERE merchant_id = ?", merchantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	menus := []FoodMenu{}
	for rows.Next() {
		var m FoodMenu
		if rows.Scan(&m.ID, &m.MerchantID, &m.Name, &m.Description, &m.Price, &m.Category, &m.ImageURL, &m.IsAvailable, &m.IsActive) != nil {
			continue
		}
		if !semua && (!m.IsActive || (m.Category != "" && !katAktif[m.Category])) {
			continue
		}
		m.OptionGroups = grupMenu[m.ID]
		if semua {
			m.GrupIDs = idGrupMenu[m.ID]
		}
		menus = append(menus, m)
	}
	// Aplikasi menampilkan kategori menurut urutan kemunculannya di daftar ini,
	// jadi urutan kategori pilihan warung cukup diterapkan di sini. Tanpa
	// kategori: paling akhir.
	posisi := func(m FoodMenu) int {
		if u, ada := urutanKat[m.Category]; ada && m.Category != "" {
			return u
		}
		return 1 << 30
	}
	sort.SliceStable(menus, func(i, j int) bool {
		if a, b := posisi(menus[i]), posisi(menus[j]); a != b {
			return a < b
		}
		return strings.ToLower(menus[i].Name) < strings.ToLower(menus[j].Name)
	})
	return menus, rows.Err()
}

// ==================== TULIS ====================

// warungMilikPemanggil memeriksa kepemilikan dan menolak toko Kasvo, yang
// menunya diatur dari Kasvo. Mengembalikan false setelah menulis balasannya.
func warungMilikPemanggil(w http.ResponseWriter, r *http.Request, merchantID string) bool {
	if merchantID == "" || !ownsMerchant(r, merchantID) {
		denyOwnership(w)
		return false
	}
	if m, _ := dbGetFoodMerchant(merchantID); m.KasvoTokoUUID != "" {
		writeJSONResponse(w, 409, map[string]string{"error": "Menu warung ini dikelola dari Kasvo. Ubah di Kasvo, BohFood ikut otomatis."})
		return false
	}
	return true
}

func teksPanjang(s string, maks int) bool { return utf8.RuneCountInString(s) > maks }

// kategoriHandler: /api/food/kategori (GET ?merchant_id=, POST simpan),
// /api/food/kategori/urutan (POST), /api/food/kategori/{id} (DELETE).
func kategoriHandler(w http.ResponseWriter, r *http.Request) {
	bagian := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/food/kategori"), "/"), "/")
	switch {
	case r.Method == http.MethodGet:
		merchantID := r.URL.Query().Get("merchant_id")
		if !ownsMerchant(r, merchantID) {
			denyOwnership(w)
			return
		}
		daftar, err := dbKategoriWarung(merchantID)
		if err != nil {
			galatServer(w, r, err)
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "kategori": daftar})

	case r.Method == http.MethodPost && bagian[0] == "urutan":
		var in struct {
			MerchantID string   `json:"merchant_id"`
			IDs        []string `json:"ids"`
		}
		if json.NewDecoder(r.Body).Decode(&in) != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data tidak terbaca"})
			return
		}
		if !warungMilikPemanggil(w, r, in.MerchantID) {
			return
		}
		for i, id := range in.IDs {
			db.Exec("UPDATE food_kategori SET urutan = ? WHERE id = ? AND merchant_id = ?", i+1, id, in.MerchantID)
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success"})

	case r.Method == http.MethodPost:
		var in struct {
			ID         string `json:"id"`
			MerchantID string `json:"merchant_id"`
			Nama       string `json:"nama"`
			Aktif      *bool  `json:"is_active"`
		}
		if json.NewDecoder(r.Body).Decode(&in) != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data tidak terbaca"})
			return
		}
		in.Nama = strings.TrimSpace(in.Nama)
		if in.Nama == "" || teksPanjang(in.Nama, 50) {
			writeJSONResponse(w, 400, map[string]string{"error": "Nama kategori wajib diisi, maksimal 50 karakter"})
			return
		}
		if !warungMilikPemanggil(w, r, in.MerchantID) {
			return
		}
		aktif := in.Aktif == nil || *in.Aktif
		if in.ID == "" {
			var ada int
			db.QueryRow("SELECT COUNT(*) FROM food_kategori WHERE merchant_id = ? AND nama = ?", in.MerchantID, in.Nama).Scan(&ada)
			if ada > 0 {
				writeJSONResponse(w, 409, map[string]string{"error": "Kategori \"" + in.Nama + "\" sudah ada"})
				return
			}
			pastikanKategori(in.MerchantID, in.Nama)
			db.Exec("UPDATE food_kategori SET is_active = ? WHERE merchant_id = ? AND nama = ?", aktif, in.MerchantID, in.Nama)
			writeJSONResponse(w, 200, map[string]string{"status": "success"})
			return
		}
		var lama string
		if db.QueryRow("SELECT nama FROM food_kategori WHERE id = ? AND merchant_id = ?", in.ID, in.MerchantID).Scan(&lama) != nil {
			writeJSONResponse(w, 404, map[string]string{"error": "Kategori tidak ditemukan"})
			return
		}
		tx, err := db.Begin()
		if err != nil {
			galatServer(w, r, err)
			return
		}
		defer tx.Rollback()
		if _, err := tx.Exec("UPDATE food_kategori SET nama = ?, is_active = ? WHERE id = ?", in.Nama, aktif, in.ID); err != nil {
			writeJSONResponse(w, 409, map[string]string{"error": "Kategori \"" + in.Nama + "\" sudah ada"})
			return
		}
		// Ganti nama ikut ke menunya: aplikasi membaca nama kategori dari menu.
		if lama != in.Nama {
			if _, err := tx.Exec("UPDATE food_menus SET category = ? WHERE merchant_id = ? AND category = ?", in.Nama, in.MerchantID, lama); err != nil {
				galatServer(w, r, err)
				return
			}
		}
		if err := tx.Commit(); err != nil {
			galatServer(w, r, err)
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success"})

	case r.Method == http.MethodDelete && bagian[0] != "":
		var merchantID, nama string
		if db.QueryRow("SELECT merchant_id, nama FROM food_kategori WHERE id = ?", bagian[0]).Scan(&merchantID, &nama) != nil {
			writeJSONResponse(w, 404, map[string]string{"error": "Kategori tidak ditemukan"})
			return
		}
		if !warungMilikPemanggil(w, r, merchantID) {
			return
		}
		var dipakai int
		db.QueryRow("SELECT COUNT(*) FROM food_menus WHERE merchant_id = ? AND category = ?", merchantID, nama).Scan(&dipakai)
		if dipakai > 0 {
			writeJSONResponse(w, 409, map[string]interface{}{"error": "Kategori ini masih dipakai " + strconv.Itoa(dipakai) + " menu. Pindahkan menunya ke kategori lain dulu."})
			return
		}
		db.Exec("DELETE FROM food_kategori WHERE id = ?", bagian[0])
		writeJSONResponse(w, 200, map[string]string{"status": "success"})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// grupMasukAkal merapikan aturan pilih supaya sama dengan yang ditegakkan
// pilihOpsi dan lembar varian aplikasi. Pesan kosong = boleh disimpan.
func grupMasukAkal(g *grupWarung) string {
	g.Nama = strings.TrimSpace(g.Nama)
	if g.Nama == "" || teksPanjang(g.Nama, 50) {
		return "Nama grup varian wajib diisi, maksimal 50 karakter"
	}
	if g.Tipe != "multiple" {
		g.Tipe = "single"
	}
	if len(g.Opsi) == 0 {
		return "Isi minimal satu pilihan varian"
	}
	if len(g.Opsi) > 50 {
		return "Pilihan varian paling banyak 50"
	}
	for i := range g.Opsi {
		g.Opsi[i].Nama = strings.TrimSpace(g.Opsi[i].Nama)
		if g.Opsi[i].Nama == "" || teksPanjang(g.Opsi[i].Nama, 50) {
			return "Nama pilihan varian wajib diisi, maksimal 50 karakter"
		}
		if g.Opsi[i].Harga < 0 || g.Opsi[i].Harga > 10_000_000 {
			return "Harga tambahan " + g.Opsi[i].Nama + " tidak masuk akal"
		}
	}
	switch {
	case g.Tipe == "single":
		g.Min, g.Max = 0, 1
		if g.Wajib {
			g.Min = 1
		}
	default:
		if g.Max < 0 || g.Max == 1 {
			return "Batas maksimal pilihan: kosongkan (tanpa batas) atau isi 2 ke atas. Untuk satu pilihan, pakai tipe Pilih satu."
		}
		if g.Max > len(g.Opsi) {
			g.Max = 0 // sama saja dengan tanpa batas
		}
		if !g.Wajib {
			g.Min = 0
		} else if g.Min < 1 {
			g.Min = 1
		}
		if g.Min > len(g.Opsi) || (g.Max > 0 && g.Min > g.Max) {
			return "Minimal pilihan melebihi jumlah pilihan yang bisa diambil"
		}
	}
	return ""
}

// varianHandler: /api/food/varian (GET ?merchant_id=, POST simpan grup beserta
// seluruh opsinya), /api/food/varian/{id} (DELETE).
func varianHandler(w http.ResponseWriter, r *http.Request) {
	idPath := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/food/varian"), "/")
	switch {
	case r.Method == http.MethodGet:
		merchantID := r.URL.Query().Get("merchant_id")
		if !ownsMerchant(r, merchantID) {
			denyOwnership(w)
			return
		}
		daftar, err := dbGrupWarung(merchantID)
		if err != nil {
			galatServer(w, r, err)
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "grup": daftar})

	case r.Method == http.MethodPost:
		var in struct {
			grupWarung
			MerchantID string `json:"merchant_id"`
		}
		if json.NewDecoder(r.Body).Decode(&in) != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data tidak terbaca"})
			return
		}
		if !warungMilikPemanggil(w, r, in.MerchantID) {
			return
		}
		g := in.grupWarung
		if pesan := grupMasukAkal(&g); pesan != "" {
			writeJSONResponse(w, 400, map[string]string{"error": pesan})
			return
		}
		if g.ID != "" {
			var pemilik string
			if db.QueryRow("SELECT merchant_id FROM food_grup_opsi WHERE id = ?", g.ID).Scan(&pemilik) != nil || pemilik != in.MerchantID {
				writeJSONResponse(w, 404, map[string]string{"error": "Grup varian tidak ditemukan"})
				return
			}
		}
		if err := simpanGrup(in.MerchantID, &g); err != nil {
			galatServer(w, r, err)
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "grup": g})

	case r.Method == http.MethodDelete && idPath != "":
		var merchantID string
		if db.QueryRow("SELECT merchant_id FROM food_grup_opsi WHERE id = ?", idPath).Scan(&merchantID) != nil {
			writeJSONResponse(w, 404, map[string]string{"error": "Grup varian tidak ditemukan"})
			return
		}
		if !warungMilikPemanggil(w, r, merchantID) {
			return
		}
		tx, err := db.Begin()
		if err != nil {
			galatServer(w, r, err)
			return
		}
		defer tx.Rollback()
		for _, q := range []string{"DELETE FROM food_menu_grup WHERE grup_id = ?", "DELETE FROM food_opsi WHERE grup_id = ?", "DELETE FROM food_grup_opsi WHERE id = ?"} {
			if _, err := tx.Exec(q, idPath); err != nil {
				galatServer(w, r, err)
				return
			}
		}
		if err := tx.Commit(); err != nil {
			galatServer(w, r, err)
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success"})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// simpanGrup menulis grup dan menyamakan opsinya dengan daftar kiriman dalam
// satu transaksi. Opsi lama mempertahankan id-nya: keranjang pemesan yang
// sedang terbuka menyimpan id itu, dan pesanannya tetap sah selama opsinya ada.
func simpanGrup(merchantID string, g *grupWarung) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := simpanGrupTx(tx, merchantID, g); err != nil {
		return err
	}
	return tx.Commit()
}

// simpanGrupTx: isi simpanGrup di dalam transaksi pemanggil (impor Excel
// menulis semua grup dan menu dalam satu transaksi).
func simpanGrupTx(tx *sql.Tx, merchantID string, g *grupWarung) error {
	if g.ID == "" {
		g.ID = newID("grup")
		var akhir int
		tx.QueryRow("SELECT COALESCE(MAX(urutan), 0) FROM food_grup_opsi WHERE merchant_id = ?", merchantID).Scan(&akhir)
		if _, err := tx.Exec("INSERT INTO food_grup_opsi (id, merchant_id, nama, tipe, wajib, min_pilih, max_pilih, urutan) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
			g.ID, merchantID, g.Nama, g.Tipe, g.Wajib, g.Min, g.Max, akhir+1); err != nil {
			return err
		}
	} else if _, err := tx.Exec("UPDATE food_grup_opsi SET nama = ?, tipe = ?, wajib = ?, min_pilih = ?, max_pilih = ? WHERE id = ?",
		g.Nama, g.Tipe, g.Wajib, g.Min, g.Max, g.ID); err != nil {
		return err
	}

	lama := map[string]bool{}
	rows, err := tx.Query("SELECT id FROM food_opsi WHERE grup_id = ?", g.ID)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			lama[id] = true
		}
	}
	rows.Close()

	dipakai := map[string]bool{}
	for i := range g.Opsi {
		o := &g.Opsi[i]
		// Id kiriman yang bukan milik grup ini dianggap opsi baru, bukan izin
		// mengubah opsi grup lain.
		if !lama[o.ID] || dipakai[o.ID] {
			o.ID = newID("opsi")
			if _, err := tx.Exec("INSERT INTO food_opsi (id, grup_id, nama, harga, is_active, urutan) VALUES (?, ?, ?, ?, ?, ?)",
				o.ID, g.ID, o.Nama, o.Harga, o.Aktif, i+1); err != nil {
				return err
			}
		} else if _, err := tx.Exec("UPDATE food_opsi SET nama = ?, harga = ?, is_active = ?, urutan = ? WHERE id = ?",
			o.Nama, o.Harga, o.Aktif, i+1, o.ID); err != nil {
			return err
		}
		dipakai[o.ID] = true
	}
	for id := range lama {
		if !dipakai[id] {
			if _, err := tx.Exec("DELETE FROM food_opsi WHERE id = ?", id); err != nil {
				return err
			}
		}
	}
	// Pasang ke banyak menu sekaligus dari editor grup. nil = tidak dikirim,
	// pemasangan lama dibiarkan; [] = lepas dari semua menu.
	if g.MenuIDs != nil {
		if _, err := tx.Exec("DELETE FROM food_menu_grup WHERE grup_id = ?", g.ID); err != nil {
			return err
		}
		terpasang := []string{}
		for _, menuID := range g.MenuIDs {
			var pemilik string
			if tx.QueryRow("SELECT merchant_id FROM food_menus WHERE id = ?", menuID).Scan(&pemilik) != nil || pemilik != merchantID {
				continue
			}
			if _, err := tx.Exec("INSERT IGNORE INTO food_menu_grup (menu_id, grup_id) VALUES (?, ?)", menuID, g.ID); err != nil {
				return err
			}
			terpasang = append(terpasang, menuID)
		}
		g.MenuIDs = terpasang
	}
	return nil
}

// pasangGrupMenu mengganti grup varian sebuah menu. Grup milik warung lain
// diabaikan diam-diam (hanya bisa terjadi lewat kiriman karangan).
func pasangGrupMenu(tx *sql.Tx, merchantID, menuID string, grupIDs []string) error {
	if _, err := tx.Exec("DELETE FROM food_menu_grup WHERE menu_id = ?", menuID); err != nil {
		return err
	}
	for i, id := range grupIDs {
		var pemilik string
		if tx.QueryRow("SELECT merchant_id FROM food_grup_opsi WHERE id = ?", id).Scan(&pemilik) != nil || pemilik != merchantID {
			continue
		}
		if _, err := tx.Exec("INSERT IGNORE INTO food_menu_grup (menu_id, grup_id, urutan) VALUES (?, ?, ?)", menuID, id, i+1); err != nil {
			return err
		}
	}
	return nil
}
