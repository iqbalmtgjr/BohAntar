package main

import (
	"bytes"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// ==================== INTEGRASI KASVO ====================
//
// Toko yang memakai kasir Kasvo bisa bergabung ke BohFood lewat tombol di
// pengaturan tokonya. Jalannya:
//
//  1. Kasvo mengirim profil toko ke /api/integrasi/kasvo/gabung → jadi
//     pengajuan mitra biasa, menunggu persetujuan admin seperti warung lain.
//  2. Disetujui → baris food_merchants lahir dengan kasvo_toko_uuid.
//  3. Sejak itu menu warung TIDAK disalin. Setiap kali pemesan membuka warung
//     atau memesan, menu dibaca langsung dari Kasvo.
//
// Kenapa dibaca langsung: BohFood memakai talangan — driver membayar ke kasir
// dengan harga kasir, lalu menagih pemesan dengan harga yang tercatat di sini.
// Salinan yang basi berarti selisihnya ditanggung driver.
//
// Kedua server saling percaya lewat satu token rahasia bersama
// (KASVO_INTEGRASI_TOKEN di sini, BOHANTAR_INTEGRASI_TOKEN di .env Kasvo).

var (
	kasvoURL    = strings.TrimRight(getEnv("KASVO_URL", ""), "/")
	kasvoToken  = getEnv("KASVO_INTEGRASI_TOKEN", "")
	kasvoClient = &http.Client{Timeout: 5 * time.Second}
)

const gambarWarungBawaan = "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400"

var polaNomorHP = regexp.MustCompile(`^\+62[0-9]{8,13}$`)

func tokenKasvoSah(r *http.Request) bool {
	return kasvoToken != "" &&
		subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Integrasi-Token")), []byte(kasvoToken)) == 1
}

// kirimKasvo melakukan satu panggilan ke Kasvo. Kodenya 0 kalau Kasvo tidak
// terjangkau sama sekali; selain 2xx, galatnya memuat potongan balasan Kasvo.
// isi (kalau ada) dikirim sebagai JSON, balasan 2xx di-decode ke tujuan.
func kirimKasvo(metode, jalur string, isi, tujuan interface{}) (int, error) {
	if kasvoURL == "" || kasvoToken == "" {
		return 0, errors.New("KASVO_URL atau KASVO_INTEGRASI_TOKEN belum diisi")
	}
	var badan io.Reader
	if isi != nil {
		b, err := json.Marshal(isi)
		if err != nil {
			return 0, err
		}
		badan = bytes.NewReader(b)
	}
	req, err := http.NewRequest(metode, kasvoURL+jalur, badan)
	if err != nil {
		return 0, err
	}
	req.Header.Set("X-Integrasi-Token", kasvoToken)
	req.Header.Set("Accept", "application/json")
	if isi != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := kasvoClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		potongan, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return resp.StatusCode, fmt.Errorf("Kasvo membalas %d untuk %s: %s", resp.StatusCode, jalur, potongan)
	}
	if tujuan == nil {
		return resp.StatusCode, nil
	}
	return resp.StatusCode, json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(tujuan)
}

// panggilKasvo melakukan GET ke Kasvo dan membaca balasan JSON-nya.
// ponytail: tanpa cache — kedua aplikasi satu VPS, jadi panggilannya murah.
// Tambahkan cache singkat kalau daftar warung mulai terasa lambat.
func panggilKasvo(jalur string, tujuan interface{}) error {
	_, err := kirimKasvo(http.MethodGet, jalur, nil, tujuan)
	return err
}

// sinkronKasvoMu menyerialkan sinkronKasvo: detak per menit dan pemicu dari
// handler bisa berjalan bersamaan, dan dua-duanya membaca daftar yang sama.
var sinkronKasvoMu sync.Mutex

// sinkronKasvo menyamakan pesanan BohFood toko Kasvo dengan kasirnya
// (kolom orders.kasvo_pesanan_id):
//
//   - diterima driver, belum ada di kasir (NULL) → dikirim. Dapur mulai
//     memasak, stok terpotong, dan pesanannya masuk laporan toko. Sengaja
//     baru saat driver menerima: sebelum itu belum tentu ada yang mengantar,
//     dan makanan yang sudah dimasak tidak bisa dibatalkan.
//   - batal atau kedaluwarsa padahal sudah ada di kasir (>0) → dibatalkan di
//     sana dan stoknya kembali, lalu kolomnya dikosongkan.
//
// Kasvo menolak (4xx, mis. stok habis) → kolomnya 0 dan tidak dicoba lagi;
// driver memesan langsung di kasir seperti sebelum integrasi ada. Kasvo tidak
// terjangkau → kolomnya tetap, dan menit berikutnya dicoba lagi.
//
// Pesanan yang dilepas driver (accepted → pending) sengaja tidak disentuh:
// dapurnya tetap memasak untuk driver berikutnya, dan Kasvo mengenali kiriman
// ulang dari bohfood_order_id yang sama.
func sinkronKasvo() {
	if kasvoURL == "" || kasvoToken == "" {
		return
	}
	sinkronKasvoMu.Lock()
	defer sinkronKasvoMu.Unlock()

	type kiriman struct {
		id, uuid, itemsJSON, pemesan, driver, catatan string
		foodTotal                                     float64
	}
	var kirim []kiriman
	rows, err := db.Query(`
		SELECT o.id, m.kasvo_toko_uuid, COALESCE(o.items_json, ''), o.rider_name, o.driver_name,
		       COALESCE(o.package_notes, ''), COALESCE(o.food_total, 0)
		FROM orders o JOIN food_merchants m ON m.id = o.merchant_id
		WHERE o.service = 'BohFood' AND o.status = 'accepted'
		  AND o.kasvo_pesanan_id IS NULL AND m.kasvo_toko_uuid IS NOT NULL`)
	if err != nil {
		log.Printf("sinkron Kasvo: daftar kiriman gagal dibaca: %v", err)
		return
	}
	for rows.Next() {
		var k kiriman
		if rows.Scan(&k.id, &k.uuid, &k.itemsJSON, &k.pemesan, &k.driver, &k.catatan, &k.foodTotal) == nil {
			kirim = append(kirim, k)
		}
	}
	rows.Close()

	for _, k := range kirim {
		type itemKasvo struct {
			MenuID  string   `json:"menu_id"`
			Qty     int      `json:"qty"`
			Options []string `json:"options"`
		}
		var items []itemKasvo
		for _, it := range uraiItems(k.itemsJSON) {
			opsi := []string{}
			for _, o := range it.Options {
				if o.ID != "" {
					opsi = append(opsi, o.ID)
				}
			}
			items = append(items, itemKasvo{MenuID: it.MenuID, Qty: it.Qty, Options: opsi})
		}
		catatan := "bohFood — diambil driver " + k.driver + ", untuk " + k.pemesan
		if c := strings.TrimSpace(k.catatan); c != "" {
			catatan += ". Catatan: " + c
		}
		var hasil struct {
			ID    int64   `json:"id"`
			Total float64 `json:"total"`
		}
		kode, err := kirimKasvo(http.MethodPost, "/api/bohfood/pesanan", map[string]interface{}{
			"bohfood_order_id": k.id,
			"toko_uuid":        k.uuid,
			"items":            items,
			"catatan":          catatan,
		}, &hasil)
		switch {
		case kode == 0 || kode >= 500:
			log.Printf("sinkron Kasvo: pesanan %s belum terkirim, dicoba lagi nanti: %v", k.id, err)
		case err == nil && hasil.ID > 0:
			_, _ = db.Exec("UPDATE orders SET kasvo_pesanan_id = ? WHERE id = ?", hasil.ID, k.id)
			// Pajak eksklusif toko ditagih kasir di atas harga menu, sementara
			// pemesan ditagih harga menu saja — selisihnya ditalangi driver.
			if hasil.Total != k.foodTotal {
				log.Printf("PERINGATAN: pesanan %s di kasir Kasvo Rp%.0f, ditagih ke pemesan Rp%.0f", k.id, hasil.Total, k.foodTotal)
			}
		default:
			log.Printf("sinkron Kasvo: pesanan %s ditolak kasir, driver memesan manual: %v", k.id, err)
			_, _ = db.Exec("UPDATE orders SET kasvo_pesanan_id = 0 WHERE id = ?", k.id)
		}
	}

	var batal []string
	rows, err = db.Query("SELECT id FROM orders WHERE kasvo_pesanan_id > 0 AND status IN ('cancelled', 'expired')")
	if err != nil {
		log.Printf("sinkron Kasvo: daftar pembatalan gagal dibaca: %v", err)
		return
	}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			batal = append(batal, id)
		}
	}
	rows.Close()

	for _, id := range batal {
		kode, err := kirimKasvo(http.MethodPost, "/api/bohfood/pesanan/"+url.PathEscape(id)+"/batal", nil, nil)
		if kode == 0 || kode >= 500 {
			log.Printf("sinkron Kasvo: pembatalan %s belum sampai, dicoba lagi nanti: %v", id, err)
			continue
		}
		// 409 = kasir sudah menyelesaikannya (driver sudah membayar); tidak ada
		// lagi yang bisa ditarik, jadi berhenti mencoba.
		if err != nil {
			log.Printf("sinkron Kasvo: pembatalan %s tidak dijalankan kasir: %v", id, err)
		}
		_, _ = db.Exec("UPDATE orders SET kasvo_pesanan_id = NULL WHERE id = ?", id)
	}
}

// ambilMenuKasvo membaca menu satu toko Kasvo, sudah dalam bentuk FoodMenu
// (Kasvo yang menyesuaikan bentuknya), plus apakah toko sedang buka menurut
// jam operasional di Kasvo.
func ambilMenuKasvo(uuid string) (bool, []FoodMenu, error) {
	var isi struct {
		Buka  bool       `json:"buka"`
		Menus []FoodMenu `json:"menus"`
	}
	if err := panggilKasvo("/api/bohfood/toko/"+url.PathEscape(uuid)+"/menu", &isi); err != nil {
		return false, nil, err
	}
	if isi.Menus == nil {
		isi.Menus = []FoodMenu{}
	}
	return isi.Buka, isi.Menus, nil
}

// statusToko adalah keadaan satu toko Kasvo menurut jadwal operasionalnya.
// Info terisi selama tutup, mis. "Buka lagi besok 07.00".
type statusToko struct {
	Buka bool   `json:"buka"`
	Info string `json:"info"`
}

// bukaKasvo menanyakan jam buka beberapa toko sekaligus. Kalau Kasvo tidak bisa
// dihubungi semuanya dianggap tutup — menunya pun tidak akan bisa dibaca.
func bukaKasvo(uuids []string) map[string]statusToko {
	hasil := map[string]statusToko{}
	if err := panggilKasvo("/api/bohfood/buka?uuid="+url.QueryEscape(strings.Join(uuids, ",")), &hasil); err != nil {
		log.Printf("jam buka toko Kasvo gagal dibaca: %v", err)
		return map[string]statusToko{}
	}
	return hasil
}

// cariMenuKasvo menanyakan toko Kasvo mana yang menjual menu bernama mirip q:
// uuid → nama menu pertama yang cocok. Gagal = tidak ada yang cocok.
func cariMenuKasvo(q string, uuids []string) map[string]string {
	hasil := map[string]string{}
	if err := panggilKasvo("/api/bohfood/cari?q="+url.QueryEscape(q)+"&uuid="+url.QueryEscape(strings.Join(uuids, ",")), &hasil); err != nil {
		log.Printf("pencarian menu Kasvo gagal: %v", err)
		return map[string]string{}
	}
	return hasil
}

// permintaanGabungKasvo adalah profil toko yang dikirim Kasvo.
type permintaanGabungKasvo struct {
	TokoUUID    string  `json:"toko_uuid"`
	NamaToko    string  `json:"nama_toko"`
	Alamat      string  `json:"alamat"`
	Lat         float64 `json:"lat"`
	Lng         float64 `json:"lng"`
	Foto        string  `json:"foto"`
	NamaPemilik string  `json:"nama_pemilik"`
	NoHP        string  `json:"no_hp"`
}

// kasvoGabungHandler menerima tombol "Gabung bohFood". Toko yang sudah
// tergabung hanya diperbarui profilnya (nama, alamat, lokasi, foto).
func kasvoGabungHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	if !tokenKasvoSah(r) {
		writeJSONResponse(w, 401, map[string]string{"error": "Token integrasi salah"})
		return
	}
	var p permintaanGabungKasvo
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&p); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Data toko tidak terbaca"})
		return
	}
	p.TokoUUID = strings.TrimSpace(p.TokoUUID)
	p.NamaToko = strings.TrimSpace(p.NamaToko)
	p.NamaPemilik = strings.TrimSpace(p.NamaPemilik)
	p.Alamat = strings.TrimSpace(p.Alamat)
	if p.TokoUUID == "" || len(p.TokoUUID) > 36 || p.NamaToko == "" || p.NamaPemilik == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Data toko belum lengkap"})
		return
	}
	if len([]rune(p.NamaToko)) > 100 || len([]rune(p.NamaPemilik)) > 100 || len(p.Alamat) > 1000 || len(p.Foto) > 500 {
		writeJSONResponse(w, 400, map[string]string{"error": "Nama atau alamat toko terlalu panjang"})
		return
	}
	if !koordinatValid(p.Lat, p.Lng) {
		writeJSONResponse(w, 400, map[string]string{"error": "Lokasi toko belum diatur. Isi dulu di Pengaturan Toko → Lokasi, supaya driver tahu harus ke mana."})
		return
	}
	if !strings.HasPrefix(p.Foto, "https://") && !strings.HasPrefix(p.Foto, "http://") {
		p.Foto = ""
	}

	// Sudah tergabung: cukup perbarui profilnya.
	var merchantID string
	if db.QueryRow("SELECT id FROM food_merchants WHERE kasvo_toko_uuid = ?", p.TokoUUID).Scan(&merchantID) == nil {
		if _, err := db.Exec(`UPDATE food_merchants SET restaurant_name = ?, address = ?, image_url = COALESCE(NULLIF(?, ''), image_url), lat = ?, lng = ? WHERE id = ?`,
			p.NamaToko, p.Alamat, p.Foto, p.Lat, p.Lng, merchantID); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui data warung"})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "tergabung", "message": "Data toko di bohFood sudah diperbarui"})
		return
	}
	var adaPengajuan int
	if db.QueryRow("SELECT 1 FROM partner_applications WHERE kasvo_toko_uuid = ? AND status = 'pending' LIMIT 1", p.TokoUUID).Scan(&adaPengajuan) == nil {
		writeJSONResponse(w, 200, map[string]string{"status": "menunggu", "message": "Pengajuan toko ini sedang ditinjau admin bohAntar"})
		return
	}

	phone := normalizePhone(p.NoHP)
	if !polaNomorHP.MatchString(phone) {
		writeJSONResponse(w, 400, map[string]string{"error": "Nomor HP pemilik tidak valid"})
		return
	}
	// Nomor yang sudah punya akun hanya boleh dipakai kalau akun itu memang
	// warung yang belum tersambung ke toko Kasvo lain. Selain itu persetujuan
	// akan menimpa peran akun orang — penumpang atau driver — jadi warung, dan
	// mereka kehilangan aksesnya tanpa tahu sebabnya.
	var peran string
	if db.QueryRow("SELECT COALESCE(role, '') FROM users WHERE phone_number = ?", phone).Scan(&peran) == nil {
		if peran != "food_merchant" {
			writeJSONResponse(w, 409, map[string]string{"error": "Nomor " + phone + " sudah dipakai akun bohAntar lain (" + peran + "). Pakai nomor lain untuk akun warung."})
			return
		}
		var uuidLain string
		if db.QueryRow("SELECT COALESCE(kasvo_toko_uuid, '') FROM food_merchants WHERE owner_phone = ?", phone).Scan(&uuidLain) == nil && uuidLain != "" {
			writeJSONResponse(w, 409, map[string]string{"error": "Nomor " + phone + " sudah dipakai warung bohFood dari toko Kasvo lain."})
			return
		}
	}
	if db.QueryRow("SELECT 1 FROM partner_applications WHERE phone_number = ? AND status = 'pending' LIMIT 1", phone).Scan(&adaPengajuan) == nil {
		writeJSONResponse(w, 409, map[string]string{"error": "Nomor " + phone + " sedang dipakai pengajuan mitra lain yang belum ditinjau."})
		return
	}

	// ponytail: dua ketukan berbarengan bisa melahirkan dua pengajuan untuk toko
	// yang sama; persetujuan kedua lalu ditolak indeks unik kasvo_toko_uuid.
	// Cukup untuk tombol yang ditekan sekali seumur toko.
	app := PartnerApplication{
		ID:            newID("partner-app"),
		Type:          "food",
		PhoneNumber:   phone,
		Name:          p.NamaPemilik,
		BusinessName:  p.NamaToko,
		Address:       p.Alamat,
		Status:        "pending",
		CreatedAt:     time.Now().Format(time.RFC3339),
		KasvoTokoUUID: p.TokoUUID,
		Lat:           p.Lat,
		Lng:           p.Lng,
		ImageURL:      p.Foto,
	}
	if err := dbSavePartnerApplication(app); err != nil {
		log.Printf("pengajuan Kasvo %s gagal disimpan: %v", p.TokoUUID, err)
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan pengajuan"})
		return
	}
	writeJSONResponse(w, 201, map[string]string{"status": "menunggu", "message": "Pengajuan terkirim. Admin bohAntar akan meninjaunya."})
}

// kasvoStatusHandler: "belum", "menunggu", "ditolak", atau "tergabung" —
// dibaca Kasvo setiap kali halaman pengaturan toko dibuka.
func kasvoStatusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	if !tokenKasvoSah(r) {
		writeJSONResponse(w, 401, map[string]string{"error": "Token integrasi salah"})
		return
	}
	uuid := r.URL.Query().Get("toko_uuid")
	var merchantID string
	if db.QueryRow("SELECT id FROM food_merchants WHERE kasvo_toko_uuid = ?", uuid).Scan(&merchantID) == nil {
		writeJSONResponse(w, 200, map[string]string{"status": "tergabung"})
		return
	}
	var status string
	err := db.QueryRow("SELECT status FROM partner_applications WHERE kasvo_toko_uuid = ? ORDER BY created_at DESC LIMIT 1", uuid).Scan(&status)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		status = "belum"
	case err != nil:
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca status"})
		return
	case status == "rejected":
		status = "ditolak"
	default:
		// Termasuk "approved" yang warungnya gagal dibuat — admin perlu melihat
		// log; dari sisi toko masih menunggu.
		status = "menunggu"
	}
	writeJSONResponse(w, 200, map[string]string{"status": status})
}

// warungDariPengajuan membuat baris food_merchants untuk pengajuan warung yang
// disetujui. Kalau nomor itu sudah punya warung, warung lama itulah yang
// disambungkan ke toko Kasvo-nya.
func warungDariPengajuan(app PartnerApplication) error {
	gambar := app.ImageURL
	if gambar == "" {
		gambar = gambarWarungBawaan
	}
	var id string
	err := db.QueryRow("SELECT id FROM food_merchants WHERE owner_phone = ?", app.PhoneNumber).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		_, err = db.Exec(`
			INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, image_url, is_open, created_at, lat, lng, kasvo_toko_uuid)
			VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, NULLIF(?, ''))`,
			newID("merchant"), app.PhoneNumber, app.BusinessName, app.Address, gambar, time.Now(), app.Lat, app.Lng, app.KasvoTokoUUID)
		return err
	}
	if err != nil || app.KasvoTokoUUID == "" {
		return err
	}
	_, err = db.Exec(`UPDATE food_merchants SET kasvo_toko_uuid = ?, restaurant_name = ?, address = ?, image_url = ?, lat = ?, lng = ? WHERE id = ?`,
		app.KasvoTokoUUID, app.BusinessName, app.Address, gambar, app.Lat, app.Lng, id)
	return err
}
