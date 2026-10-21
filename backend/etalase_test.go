package main

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

// Etalase BohFood memuat menu yang tersedia saja, dengan porsi terjual dari
// pesanan yang tidak batal; aplikasi lama (tanpa ?menu=1) tidak menerimanya.
func TestEtalaseMenuBohFood(t *testing.T) {
	bukaDBTes(t)
	pemilik := "+62800000501"
	penggunaUji(t, pemilik)
	mid := newID("merchant")
	if _, err := db.Exec(`INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, is_open, created_at, lat, lng)
		VALUES (?, ?, 'Warung Etalase', '', 1, ?, -0.07, 111.49)`, mid, pemilik, time.Now().Format(time.RFC3339)); err != nil {
		t.Fatalf("gagal menyiapkan warung uji: %v", err)
	}
	t.Cleanup(func() {
		db.Exec("DELETE FROM food_menus WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_merchants WHERE id = ?", mid)
	})
	for _, m := range []struct {
		id       string
		tersedia bool
	}{{"etalase-soto", true}, {"etalase-teh", true}, {"etalase-habis", false}} {
		if _, err := db.Exec("INSERT INTO food_menus (id, merchant_id, name, price, is_available) VALUES (?, ?, ?, 10000, ?)", m.id, mid, m.id, m.tersedia); err != nil {
			t.Fatalf("gagal menyiapkan menu uji: %v", err)
		}
	}
	pesan := func(status, menu string, qty int) {
		oid := pesananUji(t, "+62800000502", "cash", status, 8000)
		items, _ := json.Marshal([]OrderItem{{MenuID: menu, Name: menu, Price: 10000, Qty: qty}})
		if _, err := db.Exec("UPDATE orders SET service = 'BohFood', merchant_id = ?, items_json = ? WHERE id = ?", mid, string(items), oid); err != nil {
			t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
		}
	}
	pesan("completed", "etalase-soto", 3)
	pesan("accepted", "etalase-soto", 1)
	pesan("cancelled", "etalase-teh", 10)

	baca := func(path string) map[string]json.RawMessage {
		w := httptest.NewRecorder()
		foodMerchantsHandler(w, httptest.NewRequest("GET", path, nil))
		var isi map[string]json.RawMessage
		json.Unmarshal(w.Body.Bytes(), &isi)
		return isi
	}
	if _, ada := baca("/api/food/merchants")["menus"]; ada {
		t.Fatal("tanpa ?menu=1 balasan tidak boleh membawa menu")
	}
	// Satu halaman per permintaan, urut terlaris; q "warung etalase" menyaring
	// lewat nama warung supaya data lain di basis data lokal tidak ikut.
	etalaseSimpan.kapan = time.Time{}
	halaman := func(page string) (ids []string, terjual []int, adaLagi bool, warung int) {
		isi := baca("/api/food/merchants?menu=1&q=Warung+Etalase&limit=1&page=" + page)
		var menus []menuEtalase
		var merchants []map[string]any
		json.Unmarshal(isi["menus"], &menus)
		json.Unmarshal(isi["ada_lagi"], &adaLagi)
		json.Unmarshal(isi["merchants"], &merchants)
		for _, m := range menus {
			ids, terjual = append(ids, m.ID), append(terjual, m.Terjual)
		}
		return ids, terjual, adaLagi, len(merchants)
	}
	ids, terjual, adaLagi, warung := halaman("1")
	if len(ids) != 1 || ids[0] != "etalase-soto" || terjual[0] != 4 || !adaLagi || warung != 1 {
		t.Fatalf("halaman 1 harus soto (4 porsi, batal tidak dihitung) + warungnya, masih ada lagi: %v %v %v %d", ids, terjual, adaLagi, warung)
	}
	ids, terjual, adaLagi, _ = halaman("2")
	if len(ids) != 1 || ids[0] != "etalase-teh" || terjual[0] != 0 || adaLagi {
		t.Fatalf("halaman 2 harus teh (pesanan batal tidak dihitung) dan yang terakhir; menu habis tidak ikut: %v %v %v", ids, terjual, adaLagi)
	}
	if ids, _, adaLagi, warung = halaman("3"); len(ids) != 0 || adaLagi || warung != 0 {
		t.Fatalf("lewat halaman terakhir harus kosong: %v %v %d", ids, adaLagi, warung)
	}
	if ids := func() (ids []string) {
		var menus []menuEtalase
		json.Unmarshal(baca("/api/food/merchants?menu=1&q=etalase-te")["menus"], &menus)
		for _, m := range menus {
			ids = append(ids, m.ID)
		}
		return
	}(); len(ids) != 1 || ids[0] != "etalase-teh" {
		t.Fatalf("pencarian nama menu harus menyaring menu, bukan warung: %v", ids)
	}
}
