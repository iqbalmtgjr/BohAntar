package main

import (
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Impor menu warung dari Excel (9 Nov 2026), satu berkas dua lembar:
//
//	Menu   : Kategori* | Nama Menu* | Harga* | Deskripsi | Varian | Status | Stok
//	Varian : Nama Grup* | Pilihan* | Harga Tambahan | Cara Pilih | Wajib | Maks Pilihan
//
// Satu baris lembar Varian = satu pilihan; aturan grup (cara pilih, wajib,
// maks) dibaca dari baris pertama grup itu yang mengisinya. Kolom Varian di
// lembar Menu berisi nama grup dipisah koma. Kategori dan grup varian yang
// belum ada dibuat otomatis; grup yang sudah ada di warung dipakai apa adanya,
// isinya tidak diubah (mengubah pilihan lewat tab Varian).
//
// Semua atau tidak sama sekali: satu baris salah = tidak ada yang tersimpan,
// dan semua galat dilaporkan dengan nomor barisnya. Mode pratinjau (simpan=0)
// menjalankan pemeriksaan yang sama tanpa menulis apa pun.
// Kolom judul dicari dari namanya, jadi urutan kolom boleh diubah.

const (
	maksBarisMenuImpor  = 1000
	maksBarisVarianImpor = 1000
	maksBerkasImpor     = 5 << 20
)

type galatImpor struct {
	Lembar string `json:"lembar"`
	Baris  int    `json:"baris"`
	Pesan  string `json:"pesan"`
}

type menuImpor struct {
	Baris     int      `json:"baris"`
	Nama      string   `json:"nama"`
	Kategori  string   `json:"kategori"`
	Harga     float64  `json:"harga"`
	Deskripsi string   `json:"deskripsi"`
	Varian    []string `json:"varian"`
	Aktif     bool     `json:"aktif"`
	Tersedia  bool     `json:"tersedia"`
	Aksi      string   `json:"aksi"` // baru / perbarui / lewati
	id        string
	adaVarian bool // kolom Varian diisi (perbarui hanya mengganti varian kalau diisi)
}

type hasilImpor struct {
	Menu         []menuImpor  `json:"menu"`
	KategoriBaru []string     `json:"kategori_baru"`
	VarianBaru   []string     `json:"varian_baru"`
	VarianAda    []string     `json:"varian_ada"`
	Galat        []galatImpor `json:"galat"`
	grupBaru     []grupWarung
	idGrup       map[string]string // nama kecil → id (yang sudah ada); grup baru diisi saat ditulis
}

func normalNama(s string) string { return strings.ToLower(strings.Join(strings.Fields(s), " ")) }

// petaKolom mencari kolom dari teks judul. Aturan diperiksa berurutan dan
// kata pertama yang cocok menang ("Maks Pilihan" harus jadi maks, bukan pilihan).
func petaKolom(judul []string, aturan [][2]string) map[string]int {
	peta := map[string]int{}
	for i, j := range judul {
		j = normalNama(strings.Trim(j, "* "))
		for _, a := range aturan {
			if _, sudah := peta[a[1]]; !sudah && strings.Contains(j, a[0]) {
				peta[a[1]] = i
				break
			}
		}
	}
	return peta
}

func ambilSel(b barisXLSX, peta map[string]int, kunci string) string {
	if i, ada := peta[kunci]; ada && i < len(b.Sel) {
		return strings.TrimSpace(b.Sel[i])
	}
	return ""
}

func barisKosong(b barisXLSX) bool {
	for _, s := range b.Sel {
		if strings.TrimSpace(s) != "" {
			return false
		}
	}
	return true
}

// angkaRupiah menerima 15000, "15.000", "Rp 15.000", "15,000", dan angka
// Excel seperti 15000.0000001.
func angkaRupiah(s string) (float64, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return math.Round(f), true
	}
	bersih := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, strings.SplitN(s, ",00", 2)[0])
	if bersih == "" {
		return 0, false
	}
	f, err := strconv.ParseFloat(bersih, 64)
	return f, err == nil
}

func pilihanYa(s string) bool {
	switch normalNama(s) {
	case "ya", "y", "1", "wajib", "true", "benar", "iya":
		return true
	}
	return false
}

func cariLembar(lembar []lembarXLSX, nama string) *lembarXLSX {
	for i := range lembar {
		if normalNama(lembar[i].Nama) == nama {
			return &lembar[i]
		}
	}
	return nil
}

// barisData memisahkan baris judul (baris tidak kosong pertama) dari isinya.
func barisData(l *lembarXLSX) ([]string, []barisXLSX) {
	for i, b := range l.Baris {
		if !barisKosong(b) {
			var isi []barisXLSX
			for _, d := range l.Baris[i+1:] {
				if !barisKosong(d) {
					isi = append(isi, d)
				}
			}
			return b.Sel, isi
		}
	}
	return nil, nil
}

// susunImpor memeriksa seluruh berkas dan menyusun rencana tanpa menulis.
func susunImpor(merchantID string, lembar []lembarXLSX, perbarui bool) hasilImpor {
	h := hasilImpor{Menu: []menuImpor{}, KategoriBaru: []string{}, VarianBaru: []string{}, VarianAda: []string{}, Galat: []galatImpor{}, idGrup: map[string]string{}}
	galat := func(l string, baris int, format string, a ...any) {
		h.Galat = append(h.Galat, galatImpor{Lembar: l, Baris: baris, Pesan: fmt.Sprintf(format, a...)})
	}

	grupAda, _ := dbGrupWarung(merchantID)
	for _, g := range grupAda {
		h.idGrup[normalNama(g.Nama)] = g.ID
	}

	// ---- Lembar Varian (boleh tidak ada) ----
	namaGrup := map[string]string{} // nama kecil → nama asli, untuk semua grup yang dikenal
	for _, g := range grupAda {
		namaGrup[normalNama(g.Nama)] = g.Nama
	}
	if lv := cariLembar(lembar, "varian"); lv != nil {
		judul, isi := barisData(lv)
		peta := petaKolom(judul, [][2]string{{"maks", "maks"}, {"cara", "cara"}, {"tipe", "cara"}, {"wajib", "wajib"}, {"grup", "grup"}, {"harga", "harga"}, {"pilihan", "pilihan"}, {"opsi", "pilihan"}})
		if len(isi) > 0 {
			if _, ada := peta["grup"]; !ada {
				galat("Varian", 1, "Kolom \"Nama Grup\" tidak ditemukan di baris judul")
			}
			if _, ada := peta["pilihan"]; !ada {
				galat("Varian", 1, "Kolom \"Pilihan\" tidak ditemukan di baris judul")
			}
		}
		if len(isi) > maksBarisVarianImpor {
			galat("Varian", 0, "Paling banyak %d baris varian sekali impor", maksBarisVarianImpor)
			isi = nil
		}
		if len(h.Galat) == 0 {
			type kumpulan struct {
				g          grupWarung
				barisAwal  int
				caraDiisi  bool
				wajibDiisi bool
				maksDiisi  bool
				namaOpsi   map[string]bool
			}
			urutan := []string{}
			kump := map[string]*kumpulan{}
			for _, b := range isi {
				nama := ambilSel(b, peta, "grup")
				opsi := ambilSel(b, peta, "pilihan")
				if nama == "" {
					galat("Varian", b.No, "Nama grup wajib diisi")
					continue
				}
				kunci := normalNama(nama)
				if _, ada := h.idGrup[kunci]; ada {
					if !containsStr(h.VarianAda, namaGrup[kunci]) {
						h.VarianAda = append(h.VarianAda, namaGrup[kunci])
					}
					continue // grup lama tidak diubah dari Excel
				}
				k := kump[kunci]
				if k == nil {
					k = &kumpulan{g: grupWarung{Nama: nama, Tipe: "single"}, barisAwal: b.No, namaOpsi: map[string]bool{}}
					kump[kunci] = k
					urutan = append(urutan, kunci)
					namaGrup[kunci] = nama
				}
				if cara := normalNama(ambilSel(b, peta, "cara")); cara != "" && !k.caraDiisi {
					k.caraDiisi = true
					switch {
					case strings.Contains(cara, "beberapa") || strings.Contains(cara, "banyak") || strings.Contains(cara, "multi"):
						k.g.Tipe = "multiple"
					case strings.Contains(cara, "satu") || cara == "1" || strings.Contains(cara, "single"):
						k.g.Tipe = "single"
					default:
						galat("Varian", b.No, "Cara Pilih \"%s\" tidak dikenal. Isi \"Pilih satu\" atau \"Pilih beberapa\"", ambilSel(b, peta, "cara"))
					}
				}
				if w := ambilSel(b, peta, "wajib"); w != "" && !k.wajibDiisi {
					k.wajibDiisi = true
					k.g.Wajib = pilihanYa(w)
				}
				if m := ambilSel(b, peta, "maks"); m != "" && !k.maksDiisi {
					k.maksDiisi = true
					n, err := strconv.Atoi(strings.TrimSuffix(m, ".0"))
					if err != nil || n < 0 {
						galat("Varian", b.No, "Maks Pilihan harus angka bulat (kosongkan = tanpa batas)")
					}
					k.g.Max = n
				}
				if opsi == "" {
					galat("Varian", b.No, "Pilihan untuk grup %s wajib diisi", nama)
					continue
				}
				if k.namaOpsi[normalNama(opsi)] {
					galat("Varian", b.No, "Pilihan \"%s\" ditulis dua kali di grup %s", opsi, nama)
					continue
				}
				k.namaOpsi[normalNama(opsi)] = true
				harga := 0.0
				if s := ambilSel(b, peta, "harga"); s != "" {
					var ok bool
					if harga, ok = angkaRupiah(s); !ok {
						galat("Varian", b.No, "Harga tambahan \"%s\" bukan angka", s)
					}
				}
				k.g.Opsi = append(k.g.Opsi, opsiWarung{Nama: opsi, Harga: harga, Aktif: true})
			}
			for _, kunci := range urutan {
				k := kump[kunci]
				if k.g.Tipe == "multiple" && k.g.Wajib {
					k.g.Min = 1
				}
				if pesan := grupMasukAkal(&k.g); pesan != "" {
					galat("Varian", k.barisAwal, "Grup %s: %s", k.g.Nama, pesan)
					continue
				}
				h.grupBaru = append(h.grupBaru, k.g)
				h.VarianBaru = append(h.VarianBaru, k.g.Nama)
			}
		}
	}

	// ---- Lembar Menu ----
	lm := cariLembar(lembar, "menu")
	if lm == nil {
		for i := range lembar {
			if n := normalNama(lembar[i].Nama); n != "varian" && n != "petunjuk" {
				lm = &lembar[i]
				break
			}
		}
	}
	if lm == nil {
		galat("Menu", 0, "Lembar \"Menu\" tidak ditemukan. Pakai template dari tombol Unduh template.")
		return h
	}
	judul, isi := barisData(lm)
	peta := petaKolom(judul, [][2]string{{"kategori", "kategori"}, {"nama", "nama"}, {"menu", "nama"}, {"harga", "harga"}, {"deskripsi", "deskripsi"}, {"keterangan", "deskripsi"}, {"varian", "varian"}, {"status", "status"}, {"stok", "stok"}})
	for _, k := range [][2]string{{"nama", "Nama Menu"}, {"harga", "Harga"}, {"kategori", "Kategori"}} {
		if _, ada := peta[k[0]]; !ada {
			galat(lm.Nama, 1, "Kolom \"%s\" tidak ditemukan di baris judul", k[1])
		}
	}
	if len(h.Galat) > 0 && len(isi) == 0 {
		return h
	}
	if len(isi) == 0 {
		galat(lm.Nama, 0, "Lembar Menu masih kosong")
		return h
	}
	if len(isi) > maksBarisMenuImpor {
		galat(lm.Nama, 0, "Paling banyak %d menu sekali impor", maksBarisMenuImpor)
		return h
	}

	menuAda := map[string]string{}
	if rows, err := db.Query("SELECT id, name FROM food_menus WHERE merchant_id = ?", merchantID); err == nil {
		for rows.Next() {
			var id, nama string
			if rows.Scan(&id, &nama) == nil {
				menuAda[normalNama(nama)] = id
			}
		}
		rows.Close()
	}
	katAda := map[string]string{}
	if daftar, err := dbKategoriWarung(merchantID); err == nil {
		for _, k := range daftar {
			katAda[normalNama(k.Nama)] = k.Nama
		}
	}

	diFile := map[string]int{}
	for _, b := range isi {
		m := menuImpor{Baris: b.No, Aktif: true, Tersedia: true}
		m.Nama = strings.Join(strings.Fields(ambilSel(b, peta, "nama")), " ")
		m.Kategori = strings.Join(strings.Fields(ambilSel(b, peta, "kategori")), " ")
		m.Deskripsi = ambilSel(b, peta, "deskripsi")
		salah := len(h.Galat)
		switch {
		case m.Nama == "":
			galat(lm.Nama, b.No, "Nama menu wajib diisi")
		case utf8.RuneCountInString(m.Nama) > 100:
			galat(lm.Nama, b.No, "Nama menu maksimal 100 karakter")
		}
		if n, dobel := diFile[normalNama(m.Nama)]; dobel && m.Nama != "" {
			galat(lm.Nama, b.No, "Nama menu \"%s\" sudah ada di baris %d", m.Nama, n)
		}
		diFile[normalNama(m.Nama)] = b.No
		switch {
		case m.Kategori == "":
			galat(lm.Nama, b.No, "Kategori wajib diisi")
		case utf8.RuneCountInString(m.Kategori) > 50:
			galat(lm.Nama, b.No, "Kategori maksimal 50 karakter")
		}
		if nama, ada := katAda[normalNama(m.Kategori)]; ada {
			m.Kategori = nama // ikut ejaan yang sudah ada: "makanan" → "Makanan"
		} else if m.Kategori != "" && utf8.RuneCountInString(m.Kategori) <= 50 {
			katAda[normalNama(m.Kategori)] = m.Kategori
			h.KategoriBaru = append(h.KategoriBaru, m.Kategori)
		}
		if utf8.RuneCountInString(m.Deskripsi) > 500 {
			galat(lm.Nama, b.No, "Deskripsi maksimal 500 karakter")
		}
		if s := ambilSel(b, peta, "harga"); s == "" {
			galat(lm.Nama, b.No, "Harga wajib diisi (isi 0 kalau harga ada di varian)")
		} else if harga, ok := angkaRupiah(s); !ok || harga < 0 || harga > 100_000_000 {
			galat(lm.Nama, b.No, "Harga \"%s\" bukan angka yang masuk akal", s)
		} else {
			m.Harga = harga
		}
		if v := ambilSel(b, peta, "varian"); v != "" {
			m.adaVarian = true
			for _, nama := range strings.Split(v, ",") {
				nama = strings.TrimSpace(nama)
				if nama == "" {
					continue
				}
				asli, dikenal := namaGrup[normalNama(nama)]
				if !dikenal {
					galat(lm.Nama, b.No, "Varian \"%s\" belum ada. Tulis isinya di lembar Varian, atau buat dulu di tab Varian", nama)
					continue
				}
				if !containsStr(m.Varian, asli) {
					m.Varian = append(m.Varian, asli)
				}
			}
		}
		if m.Harga == 0 && len(m.Varian) == 0 && len(h.Galat) == salah {
			galat(lm.Nama, b.No, "Harga Rp0 hanya untuk menu yang harganya ada di varian")
		}
		if s := normalNama(ambilSel(b, peta, "status")); s != "" {
			m.Aktif = !(strings.Contains(s, "non") || strings.Contains(s, "sembunyi") || s == "0" || s == "tidak")
		}
		if s := normalNama(ambilSel(b, peta, "stok")); s != "" {
			m.Tersedia = !(strings.Contains(s, "habis") || s == "0" || s == "tidak")
		}
		m.id = menuAda[normalNama(m.Nama)]
		switch {
		case m.id == "":
			m.Aksi = "baru"
		case perbarui:
			m.Aksi = "perbarui"
		default:
			m.Aksi = "lewati"
		}
		h.Menu = append(h.Menu, m)
	}
	return h
}

func containsStr(daftar []string, s string) bool {
	for _, x := range daftar {
		if x == s {
			return true
		}
	}
	return false
}

// jalankanImpor menulis rencana yang sudah lolos pemeriksaan, dalam satu transaksi.
func jalankanImpor(merchantID string, h *hasilImpor) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for i := range h.grupBaru {
		g := &h.grupBaru[i]
		if err := simpanGrupTx(tx, merchantID, g); err != nil {
			return err
		}
		h.idGrup[normalNama(g.Nama)] = g.ID
	}

	var akhir int
	tx.QueryRow("SELECT COALESCE(MAX(urutan), 0) FROM food_kategori WHERE merchant_id = ?", merchantID).Scan(&akhir)
	for _, nama := range h.KategoriBaru {
		akhir++
		if _, err := tx.Exec("INSERT IGNORE INTO food_kategori (id, merchant_id, nama, urutan, is_active) VALUES (?, ?, ?, ?, TRUE)",
			newID("kat"), merchantID, nama, akhir); err != nil {
			return err
		}
	}

	for _, m := range h.Menu {
		if m.Aksi == "lewati" {
			continue
		}
		var ids []string
		for _, v := range m.Varian {
			ids = append(ids, h.idGrup[normalNama(v)])
		}
		id := m.id
		if m.Aksi == "baru" {
			id = newID("menu")
			if _, err := tx.Exec("INSERT INTO food_menus (id, merchant_id, name, description, price, category, image_url, is_available, is_active) VALUES (?, ?, ?, ?, ?, ?, '', ?, ?)",
				id, merchantID, m.Nama, m.Deskripsi, m.Harga, m.Kategori, m.Tersedia, m.Aktif); err != nil {
				return err
			}
		} else {
			// Foto dan deskripsi lama dipertahankan kalau sel Excel-nya kosong.
			if _, err := tx.Exec("UPDATE food_menus SET name = ?, description = IF(? = '', description, ?), price = ?, category = ?, is_available = ?, is_active = ? WHERE id = ? AND merchant_id = ?",
				m.Nama, m.Deskripsi, m.Deskripsi, m.Harga, m.Kategori, m.Tersedia, m.Aktif, id, merchantID); err != nil {
				return err
			}
		}
		if m.Aksi == "baru" || m.adaVarian {
			if err := pasangGrupMenu(tx, merchantID, id, ids); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

// menuImporHandler: POST /api/food/menu-impor (multipart: merchant_id, berkas,
// simpan=1 untuk menulis, perbarui=1 untuk menimpa menu bernama sama).
func menuImporHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maksBerkasImpor+(1<<20))
	if err := r.ParseMultipartForm(maksBerkasImpor); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Berkas terlalu besar (maks 5 MB) atau tidak terbaca"})
		return
	}
	merchantID := r.FormValue("merchant_id")
	if !warungMilikPemanggil(w, r, merchantID) {
		return
	}
	f, _, err := r.FormFile("berkas")
	if err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Pilih berkas Excel (.xlsx) dulu"})
		return
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maksBerkasImpor+1))
	if err != nil || len(data) > maksBerkasImpor {
		writeJSONResponse(w, 400, map[string]string{"error": "Berkas terlalu besar (maks 5 MB)"})
		return
	}
	lembar, err := bacaXLSX(data)
	if err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Berkas tidak terbaca: " + err.Error()})
		return
	}
	h := susunImpor(merchantID, lembar, r.FormValue("perbarui") == "1")
	if len(h.Galat) > 0 {
		writeJSONResponse(w, 422, map[string]interface{}{"status": "galat", "error": fmt.Sprintf("Ada %d hal yang perlu diperbaiki di berkas", len(h.Galat)), "hasil": h})
		return
	}
	disimpan := false
	if r.FormValue("simpan") == "1" {
		if err := jalankanImpor(merchantID, &h); err != nil {
			galatServer(w, r, err)
			return
		}
		disimpan = true
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "disimpan": disimpan, "hasil": h})
}

// menuImporTemplateHandler: GET /api/food/menu-impor/template — contoh berkas
// yang langsung bisa diisi, dengan daftar pilihan untuk kolom Status/Stok dst.
func menuImporTemplateHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
	w.Header().Set("Content-Disposition", `attachment; filename="template-menu-bohfood.xlsx"`)
	_ = tulisXLSX(w, templateImporMenu())
}

func templateImporMenu() []lembarTulis {
	return []lembarTulis{
		{
			Nama:  "Menu",
			Lebar: []float64{18, 28, 12, 40, 26, 12, 12},
			Baris: [][]string{
				{"Kategori *", "Nama Menu *", "Harga *", "Deskripsi", "Varian", "Status", "Stok"},
				{"Makanan", "Mie Goreng Spesial", "15000", "Mie goreng telur, bakso, dan sayur", "Level Pedas, Topping", "Aktif", "Tersedia"},
				{"Makanan", "Nasi Goreng Kampung", "17000", "Nasi goreng dengan telur ceplok", "Level Pedas", "Aktif", "Tersedia"},
				{"Minuman", "Es Teh Manis", "5000", "", "Ukuran", "Aktif", "Tersedia"},
				{"Minuman", "Jus Alpukat", "12000", "", "", "Aktif", "Habis"},
			},
			Pilihan: []string{"F2:F1001|Aktif,Nonaktif", "G2:G1001|Tersedia,Habis"},
		},
		{
			Nama:  "Varian",
			Lebar: []float64{20, 22, 16, 16, 10, 14},
			Baris: [][]string{
				{"Nama Grup *", "Pilihan *", "Harga Tambahan", "Cara Pilih", "Wajib", "Maks Pilihan"},
				{"Level Pedas", "Tidak pedas", "0", "Pilih satu", "Ya", ""},
				{"Level Pedas", "Pedas", "0"},
				{"Level Pedas", "Extra pedas", "2000"},
				{"Topping", "Telur", "3000", "Pilih beberapa", "Tidak", "3"},
				{"Topping", "Keju", "4000"},
				{"Topping", "Sosis", "3000"},
				{"Ukuran", "Reguler", "0", "Pilih satu", "Ya", ""},
				{"Ukuran", "Jumbo", "3000"},
			},
			Pilihan: []string{"D2:D1001|Pilih satu,Pilih beberapa", "E2:E1001|Ya,Tidak"},
		},
		{
			Nama:  "Petunjuk",
			Lebar: []float64{110},
			Baris: [][]string{
				{"Cara mengisi template menu BohFood"},
				{"1. Lembar Menu: satu baris = satu menu. Kolom bertanda * wajib diisi. Hapus contoh di baris 2-5 lalu isi menu Anda."},
				{"2. Kategori yang belum ada akan dibuat otomatis. Tulis persis sama untuk menu sekategori (huruf besar/kecil tidak masalah)."},
				{"3. Harga ditulis angka saja, contoh 15000. Isi 0 hanya kalau harga menu ada di varian (mis. Isi 6 / Isi 12)."},
				{"4. Kolom Varian berisi nama grup varian, pisahkan dengan koma. Contoh: Level Pedas, Topping."},
				{"5. Lembar Varian: satu baris = satu pilihan. Grup yang belum ada di warung akan dibuat otomatis dari lembar ini."},
				{"6. Cara Pilih, Wajib, dan Maks Pilihan cukup diisi di baris pertama tiap grup. Maks Pilihan kosong = tanpa batas."},
				{"7. Grup varian yang sudah ada di warung tidak diubah. Ubah pilihannya lewat tab Varian di dashboard."},
				{"8. Status: Aktif (tampil di aplikasi) / Nonaktif (disembunyikan). Stok: Tersedia / Habis. Kosong = Aktif & Tersedia."},
				{"9. Menu yang namanya sudah ada di warung dilewati, kecuali Anda mencentang \"Perbarui menu yang sudah ada\" saat impor."},
				{"10. Foto menu ditambahkan setelah impor, lewat tombol edit di tiap menu."},
			},
		},
	}
}
