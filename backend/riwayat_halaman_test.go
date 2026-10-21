package main

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

// Beranda menarik riwayat tiap beberapa detik, jadi GET /api/orders?limit=
// harus memotong per halaman — pesanan sebagai penumpang dan sebagai driver
// dalam satu urutan terbaru dulu, tanpa ulang atau lompat di batas halaman.
// Tanpa ?limit (APK lama) bentuk balasannya tetap seperti dulu.
func TestRiwayatPesananPerHalaman(t *testing.T) {
	bukaDBTes(t)
	const aku, orangLain = "+62800000601", "+62800000602"
	penggunaUji(t, aku)
	penggunaUji(t, orangLain)
	simpan := func(rider, driver string, menitLalu int) string {
		oid := newID("test")
		waktu := time.Now().Add(-time.Duration(menitLalu) * time.Minute).Format(time.RFC3339)
		if err := dbSaveOrder(Order{
			ID: oid, RiderPhone: rider, RiderName: "Uji", DriverPhone: driver,
			PickupAddress: "A", DropoffAddress: "B",
			PickupLat: -0.0784, PickupLng: 111.4933, DropoffLat: -0.0700, DropoffLng: 111.4980,
			Fare: 10000, PaymentMethod: "cash", Service: "BohRide",
			Status: "completed", CreatedAt: waktu, UpdatedAt: waktu,
		}); err != nil {
			t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
		}
		t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })
		return oid
	}
	urutan := []string{simpan(aku, "", 1), simpan(orangLain, aku, 2), simpan(aku, "", 3)}
	simpan(orangLain, "", 4) // bukan milikku, tidak boleh ikut

	tok := tokenUji(t, aku)
	baca := func(query string) map[string]json.RawMessage {
		r := httptest.NewRequest("GET", "/api/orders"+query, nil)
		r.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		createOrderHandler(w, r)
		if w.Code != 200 {
			t.Fatalf("GET /api/orders%s = %d %s", query, w.Code, w.Body.String())
		}
		var isi map[string]json.RawMessage
		json.Unmarshal(w.Body.Bytes(), &isi)
		return isi
	}
	var dapat []string
	for page, mauAdaLagi := range []bool{true, false} {
		isi := baca("?limit=2&page=" + []string{"1", "2"}[page])
		var orders []Order
		var adaLagi bool
		json.Unmarshal(isi["orders"], &orders)
		json.Unmarshal(isi["ada_lagi"], &adaLagi)
		if adaLagi != mauAdaLagi {
			t.Fatalf("halaman %d: ada_lagi = %v", page+1, adaLagi)
		}
		for _, o := range orders {
			dapat = append(dapat, o.ID)
		}
	}
	if len(dapat) != 3 || dapat[0] != urutan[0] || dapat[1] != urutan[1] || dapat[2] != urutan[2] {
		t.Fatalf("riwayat harus %v (penumpang + driver, terbaru dulu), dapat %v", urutan, dapat)
	}
	if _, ada := baca("")["ada_lagi"]; ada {
		t.Fatal("tanpa ?limit balasan harus tetap bentuk lama untuk APK yang sudah terpasang")
	}
}
