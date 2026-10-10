package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// kasvoTiruan menyalakan Kasvo palsu dan mengarahkan integrasi ke sana selama
// satu tes.
func kasvoTiruan(t *testing.T, h http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(h)
	lamaURL, lamaToken := kasvoURL, kasvoToken
	kasvoURL, kasvoToken = srv.URL, "rahasia-uji"
	t.Cleanup(func() {
		srv.Close()
		kasvoURL, kasvoToken = lamaURL, lamaToken
	})
}

const menuKasvoUji = `{"buka":true,"menus":[{"id":"12","name":"Kopi Susu","price":15000,"category":"Minuman","image_url":"https://kasvo.test/kopi.jpg","is_available":true,
	"option_groups":[{"id":"3","name":"Suhu","type":"single","required":true,"min":0,"max":1,"options":[{"id":"7","name":"Dingin","price":2000}]}]}]}`

func kasvoMenuUji(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Integrasi-Token") != "rahasia-uji" {
		w.WriteHeader(401)
		return
	}
	switch {
	case strings.HasPrefix(r.URL.Path, "/api/bohfood/toko/") && strings.HasSuffix(r.URL.Path, "/menu") && !strings.Contains(r.URL.Path, "tak-ada"):
		w.Write([]byte(menuKasvoUji))
	case r.URL.Path == "/api/bohfood/buka":
		hasil := map[string]statusToko{}
		for _, u := range strings.Split(r.URL.Query().Get("uuid"), ",") {
			if strings.Contains(u, "tutup") {
				hasil[u] = statusToko{Buka: false, Info: "Buka lagi besok 07.00"}
			} else {
				hasil[u] = statusToko{Buka: true}
			}
		}
		json.NewEncoder(w).Encode(hasil)
	case r.URL.Path == "/api/bohfood/cari":
		hasil := map[string]string{}
		if strings.Contains("kopi susu", r.URL.Query().Get("q")) {
			for _, u := range strings.Split(r.URL.Query().Get("uuid"), ",") {
				hasil[u] = "Kopi Susu"
			}
		}
		json.NewEncoder(w).Encode(hasil)
	default:
		w.WriteHeader(404)
	}
}

// Menu toko Kasvo dibaca langsung tiap kali, lengkap dengan varian dan jam
// bukanya. Balasan galat dari Kasvo harus jadi galat — bukan menu kosong yang
// tampak sah.
func TestMenuKasvoDibacaLangsung(t *testing.T) {
	kasvoTiruan(t, kasvoMenuUji)

	menus, buka, err := menuWarung(FoodMerchant{ID: "merchant-x", IsOpen: true, KasvoTokoUUID: "toko-1"})
	if err != nil || !buka || len(menus) != 1 {
		t.Fatalf("menu Kasvo tidak terbaca: buka=%v err=%v menus=%+v", buka, err, menus)
	}
	m := menus[0]
	if m.MerchantID != "merchant-x" || m.Price != 15000 || len(m.OptionGroups) != 1 || m.OptionGroups[0].Options[0].Price != 2000 {
		t.Errorf("menu Kasvo terbaca salah: %+v", m)
	}

	// Saklar is_open di bohAntar tetap berlaku walau Kasvo bilang buka.
	if _, buka, _ := menuWarung(FoodMerchant{ID: "merchant-x", IsOpen: false, KasvoTokoUUID: "toko-1"}); buka {
		t.Error("warung yang ditutup admin bohAntar dianggap buka")
	}

	if _, _, err := ambilMenuKasvo("tak-ada"); err == nil {
		t.Error("balasan 404 dari Kasvo dianggap menu sah")
	}

	if b := bukaKasvo([]string{"toko-1", "toko-tutup"}); !b["toko-1"].Buka || b["toko-tutup"].Buka || b["toko-tutup"].Info == "" {
		t.Errorf("jam buka terbaca salah: %v", b)
	}
	if c := cariMenuKasvo("kopi", []string{"toko-1"}); c["toko-1"] != "Kopi Susu" {
		t.Errorf("pencarian menu terbaca salah: %v", c)
	}

	kasvoToken = "token-lain"
	if b := bukaKasvo([]string{"toko-1"}); b["toko-1"].Buka {
		t.Error("Kasvo menolak token tapi toko tetap dianggap buka")
	}
}

// Token kosong di server tidak boleh membuat header kosong dianggap cocok —
// ConstantTimeCompare menganggap dua irisan kosong sama.
func TestTokenKasvoKosongMenolakSemua(t *testing.T) {
	lama := kasvoToken
	kasvoToken = ""
	t.Cleanup(func() { kasvoToken = lama })
	r := httptest.NewRequest(http.MethodGet, "/api/integrasi/kasvo/status", nil)
	if tokenKasvoSah(r) {
		t.Fatal("tanpa KASVO_INTEGRASI_TOKEN, permintaan tanpa token diterima")
	}
}

// Jalur lengkap tombol "Gabung bohFood": pengajuan → disetujui admin → warung
// tersambung, menunya dibaca pemesan dari Kasvo, dan edit menu dari portal
// bohAntar ditolak.
func TestGabungKasvoSampaiTersambung(t *testing.T) {
	bukaDBTes(t)
	kasvoTiruan(t, kasvoMenuUji)

	stempel := time.Now().Format("150405")
	uuid := "uji-kasvo-" + stempel
	pemilik := "+62877" + stempel + "1"
	penumpang := "+62866" + stempel + "1"
	penggunaUji(t, penumpang)
	t.Cleanup(func() {
		db.Exec("DELETE FROM partner_applications WHERE kasvo_toko_uuid IN (?, ?)", uuid, uuid+"-b")
		db.Exec("DELETE FROM food_merchants WHERE kasvo_toko_uuid = ?", uuid)
		db.Exec("DELETE FROM users WHERE phone_number = ?", pemilik)
	})

	kirim := func(token string, isi map[string]interface{}) *httptest.ResponseRecorder {
		b, _ := json.Marshal(isi)
		r := httptest.NewRequest(http.MethodPost, "/api/integrasi/kasvo/gabung", bytes.NewReader(b))
		r.Header.Set("X-Integrasi-Token", token)
		rec := httptest.NewRecorder()
		kasvoGabungHandler(rec, r)
		return rec
	}
	status := func() string {
		r := httptest.NewRequest(http.MethodGet, "/api/integrasi/kasvo/status?toko_uuid="+uuid, nil)
		r.Header.Set("X-Integrasi-Token", "rahasia-uji")
		rec := httptest.NewRecorder()
		kasvoStatusHandler(rec, r)
		var hasil struct{ Status string }
		json.Unmarshal(rec.Body.Bytes(), &hasil)
		return hasil.Status
	}
	profil := map[string]interface{}{
		"toko_uuid": uuid, "nama_toko": "Kopi Uji", "alamat": "Jl. Uji", "lat": -0.07, "lng": 111.49,
		"foto": "https://kasvo.test/toko.jpg", "nama_pemilik": "Pemilik Uji", "no_hp": "0877" + stempel + "1",
	}

	if rec := kirim("token-karangan", profil); rec.Code != 401 {
		t.Fatalf("token salah dibalas %d", rec.Code)
	}
	if s := status(); s != "belum" {
		t.Fatalf("status awal %q, mau belum", s)
	}
	tanpaLokasi := map[string]interface{}{}
	for k, v := range profil {
		tanpaLokasi[k] = v
	}
	tanpaLokasi["lat"], tanpaLokasi["lng"] = 0, 0
	if rec := kirim("rahasia-uji", tanpaLokasi); rec.Code != 400 {
		t.Fatalf("toko tanpa lokasi dibalas %d, harusnya 400", rec.Code)
	}

	if rec := kirim("rahasia-uji", profil); rec.Code != 201 {
		t.Fatalf("pengajuan dibalas %d: %s", rec.Code, rec.Body.String())
	}
	if rec := kirim("rahasia-uji", profil); rec.Code != 200 || status() != "menunggu" {
		t.Fatalf("pengajuan ulang dibalas %d dengan status %q", rec.Code, status())
	}
	var appID string
	var jumlah int
	db.QueryRow("SELECT COUNT(*), MAX(id) FROM partner_applications WHERE kasvo_toko_uuid = ?", uuid).Scan(&jumlah, &appID)
	if jumlah != 1 {
		t.Fatalf("tombol ditekan dua kali melahirkan %d pengajuan", jumlah)
	}

	// Nomor milik akun penumpang tidak boleh diambil alih jadi warung.
	lain := map[string]interface{}{}
	for k, v := range profil {
		lain[k] = v
	}
	lain["toko_uuid"], lain["no_hp"] = uuid+"-b", penumpang
	if rec := kirim("rahasia-uji", lain); rec.Code != 409 {
		t.Fatalf("nomor penumpang dibalas %d, harusnya 409", rec.Code)
	}

	rec := httptest.NewRecorder()
	adminPartnerApplicationActionHandler(rec, httptest.NewRequest(http.MethodPost, "/api/admin/partner-applications/"+appID+"/approve", nil))
	if rec.Code != 200 {
		t.Fatalf("persetujuan dibalas %d: %s", rec.Code, rec.Body.String())
	}
	if s := status(); s != "tergabung" {
		t.Fatalf("status setelah disetujui %q", s)
	}
	var w FoodMerchant
	db.QueryRow("SELECT id, owner_phone, lat, COALESCE(image_url, '') FROM food_merchants WHERE kasvo_toko_uuid = ?", uuid).Scan(&w.ID, &w.OwnerPhone, &w.Lat, &w.ImageURL)
	if w.OwnerPhone != pemilik || w.Lat != -0.07 || w.ImageURL != "https://kasvo.test/toko.jpg" {
		t.Fatalf("warung lahir salah: %+v", w)
	}

	profil["nama_toko"] = "Kopi Uji Baru"
	if rec := kirim("rahasia-uji", profil); rec.Code != 200 {
		t.Fatalf("perbarui profil dibalas %d", rec.Code)
	}
	var nama string
	db.QueryRow("SELECT restaurant_name FROM food_merchants WHERE id = ?", w.ID).Scan(&nama)
	if nama != "Kopi Uji Baru" {
		t.Errorf("nama warung tidak ikut Kasvo: %q", nama)
	}

	// Daftar warung: ongkir dari posisi pemesan, dan pencarian menemukan warung
	// lewat nama menunya.
	cari := func(query string) []map[string]interface{} {
		r := httptest.NewRequest(http.MethodGet, "/api/food/merchants?lat=-0.08&lng=111.50&"+query, nil)
		rec := httptest.NewRecorder()
		foodMerchantsHandler(rec, r)
		var hasil struct{ Merchants []map[string]interface{} }
		json.Unmarshal(rec.Body.Bytes(), &hasil)
		return hasil.Merchants
	}
	temukan := func(daftar []map[string]interface{}) map[string]interface{} {
		for _, m := range daftar {
			if m["id"] == w.ID {
				return m
			}
		}
		return nil
	}
	if m := temukan(cari("")); m == nil || m["ongkir"].(float64) <= 0 || m["is_open"] != true {
		t.Fatalf("warung Kasvo di daftar: %v", m)
	}
	if m := temukan(cari("q=susu")); m == nil || m["cocok_menu"] != "Kopi Susu" {
		t.Fatalf("pencarian lewat nama menu tidak menemukan warung: %v", m)
	}
	if m := temukan(cari("q=martabak")); m != nil {
		t.Fatalf("pencarian yang tidak cocok tetap memuat warung: %v", m)
	}

	// Penumpang biasa membaca menu warung — dulu 403.
	r := httptest.NewRequest(http.MethodGet, "/api/food/menus?merchant_id="+w.ID, nil)
	r = r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, penumpang), ctxRole, "rider"))
	rec = httptest.NewRecorder()
	foodMenusHandler(rec, r)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"option_groups"`) {
		t.Fatalf("penumpang membaca menu: %d %s", rec.Code, rec.Body.String())
	}

	// Pemilik tidak bisa mengubah menu dari portal bohAntar.
	b, _ := json.Marshal(map[string]interface{}{"merchant_id": w.ID, "name": "Menu Liar", "price": 1000})
	r = httptest.NewRequest(http.MethodPost, "/api/food/menus", bytes.NewReader(b))
	r = r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, pemilik), ctxRole, "food_merchant"))
	rec = httptest.NewRecorder()
	foodMenusHandler(rec, r)
	if rec.Code != 409 {
		t.Fatalf("edit menu warung Kasvo dibalas %d, harusnya 409", rec.Code)
	}
}
