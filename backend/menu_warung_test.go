package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Kelola menu warung dari portal: kategori (urutan, status, ganti nama),
// grup varian bersama, status aktif dan tanda habis. Yang diuji adalah yang
// sampai ke pemesan — menuWarung, sumber aplikasi dan validasi pesanan.
func TestKelolaMenuWarung(t *testing.T) {
	bukaDBTes(t)
	pemilik := "+62800000951"
	penggunaUji(t, pemilik)
	mid := newID("merchant")
	if _, err := db.Exec(`INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, is_open, created_at, lat, lng)
		VALUES (?, ?, 'Warung Kelola', '', 1, ?, -0.07, 111.49)`, mid, pemilik, time.Now().Format(time.RFC3339)); err != nil {
		t.Fatalf("gagal menyiapkan warung uji: %v", err)
	}
	t.Cleanup(func() {
		db.Exec("DELETE FROM food_menu_grup WHERE grup_id IN (SELECT id FROM food_grup_opsi WHERE merchant_id = ?)", mid)
		db.Exec("DELETE FROM food_opsi WHERE grup_id IN (SELECT id FROM food_grup_opsi WHERE merchant_id = ?)", mid)
		db.Exec("DELETE FROM food_grup_opsi WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_kategori WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_menus WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_merchants WHERE id = ?", mid)
	})

	panggil := func(h http.HandlerFunc, method, path string, badan any) (int, map[string]any) {
		b, _ := json.Marshal(badan)
		r := httptest.NewRequest(method, path, bytes.NewReader(b))
		r = r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, pemilik), ctxRole, "food_merchant"))
		w := httptest.NewRecorder()
		h(w, r)
		var isi map[string]any
		json.Unmarshal(w.Body.Bytes(), &isi)
		return w.Code, isi
	}
	publik := func() []FoodMenu {
		menus, err := dbMenuWarung(mid, false)
		if err != nil {
			t.Fatalf("gagal membaca menu: %v", err)
		}
		return menus
	}

	kode, isi := panggil(varianHandler, "POST", "/api/food/varian", map[string]any{
		"merchant_id": mid, "nama": "Level pedas", "tipe": "single", "wajib": true,
		"opsi": []map[string]any{{"nama": "Biasa", "harga": 0, "is_active": true}, {"nama": "Pedas", "harga": 2000, "is_active": true}, {"nama": "Super", "harga": 3000, "is_active": false}},
	})
	if kode != 200 {
		t.Fatalf("simpan grup varian: %d %v", kode, isi)
	}
	grupID := isi["grup"].(map[string]any)["id"].(string)

	kode, isi = panggil(foodMenusHandler, "POST", "/api/food/menus", map[string]any{"merchant_id": mid, "name": "Mie Goreng", "category": "Mie", "price": 15000, "is_available": true, "grup_ids": []string{grupID}})
	if kode != 200 {
		t.Fatalf("simpan menu: %d %v", kode, isi)
	}
	mie := isi["id"].(string)
	// Tanpa is_active (dashboard lama): menu baru tetap aktif.
	if kode, isi = panggil(foodMenusHandler, "POST", "/api/food/menus", map[string]any{"merchant_id": mid, "name": "Es Teh", "category": "Minuman", "price": 5000, "is_available": true}); kode != 200 {
		t.Fatalf("simpan menu: %d %v", kode, isi)
	}
	teh := isi["id"].(string)

	m := publik()
	if len(m) != 2 || m[0].Name != "Mie Goreng" {
		t.Fatalf("pemesan harus melihat 2 menu, Mie dulu (kategori lebih dulu dicatat): %+v", m)
	}
	if g := m[0].OptionGroups; len(g) != 1 || len(g[0].Options) != 2 || !g[0].Required {
		t.Fatalf("varian Mie Goreng harus 1 grup wajib berisi 2 opsi aktif (Super mati): %+v", g)
	}
	var super string
	for _, o := range func() []grupWarung { g, _ := dbGrupWarung(mid); return g }()[0].Opsi {
		if o.Nama == "Super" {
			super = o.ID
		}
	}
	if _, _, pesan := pilihOpsi(m[0], []string{super}); pesan == "" {
		t.Fatal("opsi yang dimatikan tidak boleh bisa dipesan")
	}
	if _, _, pesan := pilihOpsi(m[0], nil); pesan == "" {
		t.Fatal("grup wajib tanpa pilihan harus ditolak")
	}

	// Urutan kategori pilihan warung menentukan urutan di aplikasi.
	kat, _ := dbKategoriWarung(mid)
	ids := map[string]string{}
	for _, k := range kat {
		ids[k.Nama] = k.ID
	}
	panggil(kategoriHandler, "POST", "/api/food/kategori/urutan", map[string]any{"merchant_id": mid, "ids": []string{ids["Minuman"], ids["Mie"]}})
	if m = publik(); m[0].Name != "Es Teh" {
		t.Fatalf("setelah diurutkan, Minuman harus lebih dulu: %s", m[0].Name)
	}

	// Tandai habis: tetap tampil, tapi tidak bisa dipesan. Nonaktif: hilang.
	panggil(foodMenuDetailHandler, "POST", "/api/food/menus/"+teh+"/status", map[string]any{"is_available": false})
	if m = publik(); len(m) != 2 || m[0].IsAvailable {
		t.Fatalf("menu habis harus tetap tampil dan bertanda habis: %+v", m)
	}
	panggil(foodMenuDetailHandler, "POST", "/api/food/menus/"+teh+"/status", map[string]any{"is_active": false})
	if m = publik(); len(m) != 1 {
		t.Fatalf("menu nonaktif harus hilang dari pemesan, sisa %d", len(m))
	}
	if semua, _ := dbMenuWarung(mid, true); len(semua) != 2 {
		t.Fatalf("portal pemilik tetap melihat menu nonaktif, dapat %d", len(semua))
	}

	// Kategori dimatikan: menunya ikut tersembunyi.
	panggil(kategoriHandler, "POST", "/api/food/kategori", map[string]any{"id": ids["Mie"], "merchant_id": mid, "nama": "Mie", "is_active": false})
	if m = publik(); len(m) != 0 {
		t.Fatalf("menu di kategori nonaktif harus tersembunyi, sisa %d", len(m))
	}

	// Ganti nama kategori ikut mengganti kategori menunya.
	panggil(kategoriHandler, "POST", "/api/food/kategori", map[string]any{"id": ids["Mie"], "merchant_id": mid, "nama": "Aneka Mie", "is_active": true})
	if m = publik(); len(m) != 1 || m[0].Category != "Aneka Mie" || m[0].ID != mie {
		t.Fatalf("ganti nama kategori harus ikut ke menu: %+v", m)
	}
	if kode, _ = panggil(kategoriHandler, "DELETE", "/api/food/kategori/"+ids["Mie"], nil); kode != 409 {
		t.Fatalf("kategori yang masih dipakai tidak boleh dihapus, dapat %d", kode)
	}

	// Hapus grup: menunya kehilangan varian, bukan ikut terhapus.
	if kode, _ = panggil(varianHandler, "DELETE", "/api/food/varian/"+grupID, nil); kode != 200 {
		t.Fatalf("hapus grup: %d", kode)
	}
	if m = publik(); len(m) != 1 || len(m[0].OptionGroups) != 0 {
		t.Fatalf("setelah grup dihapus, menu tanpa varian: %+v", m)
	}
}
