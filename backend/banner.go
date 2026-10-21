package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"
)

// Banner beranda aplikasi: spanduk geser di belakang kartu BohPay, diatur super
// admin dari dashboard (halaman Banner Beranda).
//
// Banner tanpa gambar digambar aplikasi sendiri dari judul, keterangan, dan
// warna — admin tidak butuh desainer untuk membuat satu. Banner bergambar
// memakai foto unggahan (/api/upload) apa adanya.

type Banner struct {
	ID          string `json:"id"`
	Judul       string `json:"judul"`
	Keterangan  string `json:"keterangan"`
	LabelTombol string `json:"label_tombol"`
	Tujuan      string `json:"tujuan"` // "" | BohRide | BohCar | BohFood | BohSend | url
	URL         string `json:"url"`
	Warna       string `json:"warna"`
	GambarURL   string `json:"gambar_url"`
	Aktif       bool   `json:"aktif"`
	Urutan      int    `json:"urutan"`
}

const skemaBannerBeranda = `CREATE TABLE IF NOT EXISTS banner_beranda (
	id VARCHAR(64) PRIMARY KEY,
	judul VARCHAR(80) NOT NULL,
	keterangan VARCHAR(160) NOT NULL DEFAULT '',
	label_tombol VARCHAR(30) NOT NULL DEFAULT '',
	tujuan VARCHAR(10) NOT NULL DEFAULT '',
	url VARCHAR(300) NOT NULL DEFAULT '',
	warna VARCHAR(10) NOT NULL DEFAULT 'biru',
	gambar_url VARCHAR(300) NOT NULL DEFAULT '',
	aktif TINYINT(1) NOT NULL DEFAULT 1,
	urutan INT NOT NULL DEFAULT 0,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	INDEX idx_banner_aktif (aktif, urutan)
) DEFAULT CHARSET=utf8mb4`

// Warna yang dikenal aplikasi (lihat bannerWarna di mobile banner_beranda.dart).
var warnaBanner = map[string]bool{"biru": true, "oranye": true, "hijau": true, "ungu": true, "merah": true, "gelap": true}

var tujuanBanner = map[string]bool{"": true, "BohRide": true, "BohCar": true, "BohFood": true, "BohSend": true, "url": true}

// siapkanBanner membuat tabelnya dan menanam banner bawaan — hanya saat tabel
// itu baru lahir. Kalau ditanam setiap kali tabelnya kosong, banner yang sengaja
// dihapus admin akan hidup lagi di restart berikutnya.
func siapkanBanner() {
	var ada int
	db.QueryRow("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'banner_beranda'").Scan(&ada)
	// Tidak fatal, beda dengan tabel inti di initDB: banner cuma pelengkap.
	// Kalau tabelnya gagal dibuat, pesanan tetap jalan; /api/banner membalas
	// 500 dan aplikasi memakai banner bawaannya sendiri.
	if _, err := db.Exec(skemaBannerBeranda); err != nil {
		log.Printf("Tabel banner_beranda gagal dibuat, banner beranda nonaktif: %v", err)
		return
	}
	if ada > 0 {
		return
	}
	b := Banner{
		Judul:       "Tanpa tarif tambahan di BohFood",
		Keterangan:  "Harga menu sama dengan harga di warung.",
		LabelTombol: "Pesan makanan",
		Tujuan:      "BohFood",
		Warna:       "oranye",
		Aktif:       true,
		Urutan:      1,
	}
	if err := simpanBanner(newID("bn"), b); err != nil {
		log.Printf("Banner bawaan gagal ditanam: %v", err)
	}
}

// periksaBanner merapikan isian dan mengembalikan pesan galat untuk admin.
func periksaBanner(b *Banner) string {
	b.Judul = strings.TrimSpace(b.Judul)
	b.Keterangan = strings.TrimSpace(b.Keterangan)
	b.LabelTombol = strings.TrimSpace(b.LabelTombol)
	b.URL = strings.TrimSpace(b.URL)
	b.GambarURL = strings.TrimSpace(b.GambarURL)
	if b.Warna == "" {
		b.Warna = "biru"
	}
	switch {
	case b.Judul == "" || utf8.RuneCountInString(b.Judul) > 80:
		return "Judul wajib diisi, maksimal 80 karakter"
	case utf8.RuneCountInString(b.Keterangan) > 160:
		return "Keterangan maksimal 160 karakter"
	case utf8.RuneCountInString(b.LabelTombol) > 30:
		return "Tulisan tombol maksimal 30 karakter"
	case !warnaBanner[b.Warna]:
		return "Warna tidak dikenal"
	case !tujuanBanner[b.Tujuan]:
		return "Tujuan tidak dikenal"
	case b.Tujuan == "url" && (!strings.HasPrefix(b.URL, "https://") || len(b.URL) > 300):
		return "Tautan harus diawali https:// dan maksimal 300 karakter"
	case b.GambarURL != "" && !strings.HasPrefix(b.GambarURL, "/uploads/") && !strings.HasPrefix(b.GambarURL, "https://"):
		return "Gambar harus hasil unggahan atau tautan https://"
	case len(b.GambarURL) > 300:
		return "Tautan gambar kepanjangan"
	case b.Urutan < 0 || b.Urutan > 999:
		return "Urutan 0–999"
	}
	if b.Tujuan != "url" {
		b.URL = ""
	}
	return ""
}

func simpanBanner(id string, b Banner) error {
	_, err := db.Exec(`INSERT INTO banner_beranda (id, judul, keterangan, label_tombol, tujuan, url, warna, gambar_url, aktif, urutan)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE judul = VALUES(judul), keterangan = VALUES(keterangan), label_tombol = VALUES(label_tombol),
			tujuan = VALUES(tujuan), url = VALUES(url), warna = VALUES(warna), gambar_url = VALUES(gambar_url),
			aktif = VALUES(aktif), urutan = VALUES(urutan)`,
		id, b.Judul, b.Keterangan, b.LabelTombol, b.Tujuan, b.URL, b.Warna, b.GambarURL, b.Aktif, b.Urutan)
	return err
}

func daftarBanner(hanyaAktif bool) ([]Banner, error) {
	q := "SELECT id, judul, keterangan, label_tombol, tujuan, url, warna, gambar_url, aktif, urutan FROM banner_beranda"
	if hanyaAktif {
		// ponytail: 10 cukup untuk karosel beranda; tak ada yang menggeser lebih jauh.
		q += " WHERE aktif = 1 ORDER BY urutan, created_at LIMIT 10"
	} else {
		q += " ORDER BY urutan, created_at"
	}
	rows, err := db.Query(q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	daftar := []Banner{}
	for rows.Next() {
		var b Banner
		if err := rows.Scan(&b.ID, &b.Judul, &b.Keterangan, &b.LabelTombol, &b.Tujuan, &b.URL, &b.Warna, &b.GambarURL, &b.Aktif, &b.Urutan); err != nil {
			return nil, err
		}
		daftar = append(daftar, b)
	}
	return daftar, rows.Err()
}

// bannerPublikHandler: GET /api/banner — tanpa token. Isinya memang untuk
// dipajang, dan beranda butuh banner secepat mungkin saat dibuka.
func bannerPublikHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	daftar, err := daftarBanner(true)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memuat banner"})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "banner": daftar})
}

// adminBannerHandler: GET (semua, termasuk yang nonaktif) dan POST (baru)
// /api/admin/banner; PUT dan DELETE /api/admin/banner/{id}.
func adminBannerHandler(w http.ResponseWriter, r *http.Request) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/admin/banner"), "/")
	switch {
	case r.Method == http.MethodGet && id == "":
		daftar, err := daftarBanner(false)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal memuat banner"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "banner": daftar})

	case (r.Method == http.MethodPost && id == "") || (r.Method == http.MethodPut && id != ""):
		var b Banner
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data banner tidak terbaca"})
			return
		}
		if pesan := periksaBanner(&b); pesan != "" {
			writeJSONResponse(w, 400, map[string]string{"error": pesan})
			return
		}
		if id == "" {
			id = newID("bn")
		} else if err := db.QueryRow("SELECT id FROM banner_beranda WHERE id = ?", id).Scan(&id); err == sql.ErrNoRows {
			// Tanpa ini PUT ke id karangan diam-diam membuat banner baru.
			writeJSONResponse(w, 404, map[string]string{"error": "Banner tidak ditemukan"})
			return
		}
		if err := simpanBanner(id, b); err != nil {
			log.Printf("Banner %s gagal disimpan: %v", id, err)
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan banner"})
			return
		}
		b.ID = id
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "banner": b})

	case r.Method == http.MethodDelete && id != "":
		// ponytail: berkas gambarnya dibiarkan di uploads/ — kecil, dan bisa
		// saja masih dipakai banner lain hasil salin.
		res, err := db.Exec("DELETE FROM banner_beranda WHERE id = ?", id)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menghapus banner"})
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeJSONResponse(w, 404, map[string]string{"error": "Banner tidak ditemukan"})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success"})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}
