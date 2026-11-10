package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHitungDiskon(t *testing.T) {
	for _, c := range []struct {
		v          Voucher
		dasar, mau float64
	}{
		{Voucher{Jenis: "nominal", Nilai: 5000}, 12000, 5000},
		{Voucher{Jenis: "nominal", Nilai: 5000}, 3000, 3000}, // tidak melebihi totalnya
		{Voucher{Jenis: "nominal", Nilai: 5000, MinBelanja: 20000}, 19999, 0},
		{Voucher{Jenis: "persen", Nilai: 20}, 12500, 2500},
		{Voucher{Jenis: "persen", Nilai: 20, MaksDiskon: 2000}, 12500, 2000},
		{Voucher{Jenis: "persen", Nilai: 33.33}, 10001, 3333}, // dibulatkan ke bawah
		{Voucher{Jenis: "persen", Nilai: 100}, 11000, 11000},
	} {
		if d := hitungDiskon(c.v, c.dasar); d != c.mau {
			t.Errorf("%+v dari %v: diskon %v, harusnya %v", c.v, c.dasar, d, c.mau)
		}
	}
}

// Yang dijaga: voucher terpakai sendiri tanpa kode (yang terbesar menang),
// jatah per penumpang dihormati dan kembali saat pesanan batal, voucher basi/
// nonaktif/layanan lain tidak ikut, dan diskonnya ditanggung BohAntar — saldo
// driver berubah sebesar diskon − (komisi + biaya jasa), bukan −(komisi +
// biaya jasa) seperti pesanan biasa.
func TestVoucherOtomatisDitanggungAplikator(t *testing.T) {
	bukaDBTes(t)
	t.Cleanup(func() { db.Exec("DELETE FROM voucher WHERE judul LIKE 'Uji voucher%'") })
	stempel := time.Now().Format("150405")
	rider := "+62897" + stempel
	driver := "+62896" + stempel
	penggunaUji(t, rider)
	penggunaUji(t, driver)

	kirim := func(v Voucher) int {
		body, _ := json.Marshal(v)
		w := httptest.NewRecorder()
		adminVoucherHandler(w, httptest.NewRequest(http.MethodPost, "/api/admin/voucher", bytes.NewReader(body)))
		return w.Code
	}
	for _, v := range []Voucher{
		{Judul: "", Jenis: "nominal", Nilai: 1000},
		{Judul: "Uji voucher x", Jenis: "persen", Nilai: 150},
		{Judul: "Uji voucher x", Jenis: "nominal", Nilai: 0},
		{Judul: "Uji voucher x", Jenis: "nominal", Nilai: 1000, Layanan: "BohTerbang"},
		{Judul: "Uji voucher x", Jenis: "nominal", Nilai: 1000, Mulai: "2026-12-01", Selesai: "2026-11-01"},
	} {
		if kode := kirim(v); kode != 400 {
			t.Errorf("voucher %+v dibalas %d, harusnya 400", v, kode)
		}
	}
	kemarin := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	for _, v := range []Voucher{
		{Judul: "Uji voucher kecil", Layanan: "BohRide", Jenis: "nominal", Nilai: 1000, PerPengguna: 1, Aktif: true},
		{Judul: "Uji voucher besar", Layanan: "BohRide", Jenis: "nominal", Nilai: 3000, PerPengguna: 1, Aktif: true},
		{Judul: "Uji voucher basi", Layanan: "BohRide", Jenis: "nominal", Nilai: 9000, Selesai: kemarin, Aktif: true},
		{Judul: "Uji voucher mati", Layanan: "BohRide", Jenis: "nominal", Nilai: 9000},
		{Judul: "Uji voucher mobil", Layanan: "BohCar", Jenis: "nominal", Nilai: 9000, Aktif: true},
		{Judul: "Uji voucher makan", Layanan: "BohFood", Jenis: "persen", Nilai: 100, Aktif: true},
	} {
		if kode := kirim(v); kode != 200 {
			t.Fatalf("voucher %s dibalas %d", v.Judul, kode)
		}
	}

	pesan := func() Order {
		body := `{"pickup":"A","dropoff":"B","pickup_lat":0.0785,"pickup_lng":111.494,"dropoff_lat":0.0900,"dropoff_lng":111.500,"service":"BohRide"}`
		req := httptest.NewRequest(http.MethodPost, "/api/orders", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+mustToken(t, rider, "rider"))
		w := httptest.NewRecorder()
		createOrderHandler(w, req)
		var hasil struct {
			Order Order `json:"order"`
		}
		json.Unmarshal(w.Body.Bytes(), &hasil)
		if w.Code != 201 {
			t.Fatalf("pesanan gagal: %d %s", w.Code, w.Body.String())
		}
		t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", hasil.Order.ID) })
		return hasil.Order
	}
	o1, o2, o3 := pesan(), pesan(), pesan()
	if o1.Diskon != 3000 || o2.Diskon != 1000 || o3.Diskon != 0 {
		t.Fatalf("diskon tiga pesanan %v, %v, %v; harusnya 3000, 1000, 0", o1.Diskon, o2.Diskon, o3.Diskon)
	}
	// Hapus akun mengosongkan rider_phone; daftar ulang dengan nomor yang sama
	// tidak boleh mendapat jatah baru.
	db.Exec("UPDATE orders SET rider_phone = NULL WHERE id = ?", o2.ID)
	if v, d := pilihVoucher(rider, "BohRide", 20000, 20000); d != 0 {
		t.Errorf("hapus akun membuka jatah lagi: dapat %q %v", v.Judul, d)
	}
	db.Exec("UPDATE orders SET rider_phone = ? WHERE id = ?", rider, o2.ID)
	db.Exec("UPDATE orders SET status = 'cancelled' WHERE id = ?", o1.ID)
	if v, d := pilihVoucher(rider, "BohRide", 20000, 20000); d != 3000 || v.Judul != "Uji voucher besar" {
		t.Errorf("pesanan batal harus mengembalikan jatah: dapat %q %v", v.Judul, d)
	}
	// BohFood: makanan 50.000 + ongkir & jasa 11.000. Diskon 100% tetap
	// berhenti di 11.000 — uang makanan yang ditalangi driver tidak dipotong.
	if _, d := pilihVoucher(rider, "BohFood", 61000, 11000); d != 11000 {
		t.Errorf("diskon BohFood %v, harusnya berhenti di ongkir + biaya jasa 11000", d)
	}

	saldo := func() (s float64) {
		db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", driver).Scan(&s)
		return
	}
	db.Exec("UPDATE orders SET status = 'accepted', driver_phone = ?, driver_name = 'Uji' WHERE id = ?", driver, o2.ID)
	awal := saldo()
	req := httptest.NewRequest(http.MethodPost, "/api/orders/"+o2.ID+"/complete", nil)
	req.Header.Set("Authorization", "Bearer "+mustToken(t, driver, "driver"))
	w := httptest.NewRecorder()
	orderRouterHandler(w, req)
	if w.Code != 200 {
		t.Fatalf("selesai gagal: %d %s", w.Code, w.Body.String())
	}
	if beda, mau := saldo()-awal, o2.Diskon-o2.Komisi-o2.BiayaJasa; beda != mau {
		t.Errorf("saldo driver berubah %v, harusnya %v (diskon − komisi − biaya jasa)", beda, mau)
	}
}
