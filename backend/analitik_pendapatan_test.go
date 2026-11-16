package main

import (
	"fmt"
	"testing"
	"time"
)

// Dashboard dulu menampilkan SUM(fare) sebagai "Total Pendapatan" — padahal
// sebagian besar ongkos itu milik driver. Yang diuji: pendapatan_kami memakai
// rumus yang sama dengan laporan bagi hasil, dan bagian driver = ongkos − komisi.
func TestAnalitikPisahPendapatanKamiDanDriver(t *testing.T) {
	bukaDBTes(t)

	stempel := time.Now().Format("150405")
	driver := "+62897" + stempel
	rider := "+62896" + stempel
	penggunaUji(t, driver)
	penggunaUji(t, rider)

	sebelum, _ := dbGetAnalyticsData()

	// BohRide 14.000, komisi 8% = 1.120, biaya jasa 1.500, diskon voucher 500.
	oid := fmt.Sprintf("test-analitik-%s", stempel)
	waktu := time.Now().Format(time.RFC3339)
	if err := dbSaveOrder(Order{
		ID: oid, RiderPhone: rider, RiderName: "Uji",
		PickupAddress: "A", DropoffAddress: "B",
		PickupLat: -0.0784, PickupLng: 111.4933, DropoffLat: -0.0700, DropoffLng: 111.4980,
		Fare: 14000, Komisi: 1120, BiayaJasa: 1500, Diskon: 500, PaymentMethod: "wallet", Service: "BohRide",
		Status: "completed", DriverPhone: driver, DriverName: "Driver Uji",
		CreatedAt: waktu, UpdatedAt: waktu,
	}); err != nil {
		t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })

	// Pesanan "selesai" tanpa driver (kasus produksi 15 Nov): laporan /komisi
	// tak menghitungnya, jadi dashboard juga tidak boleh.
	yatim := oid + "-tanpa-driver"
	if err := dbSaveOrder(Order{
		ID: yatim, RiderPhone: rider, RiderName: "Uji", PickupAddress: "A", DropoffAddress: "B",
		Fare: 14000, Komisi: 2100, BiayaJasa: 1500, PaymentMethod: "cash", Service: "BohSend",
		Status: "completed", CreatedAt: waktu, UpdatedAt: waktu,
	}); err != nil {
		t.Fatalf("gagal menyiapkan pesanan tanpa driver: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", yatim) })

	sesudah, err := dbGetAnalyticsData()
	if err != nil {
		t.Fatal(err)
	}
	if d := sesudah["pendapatan_kami"].(float64) - sebelum["pendapatan_kami"].(float64); d != 2120 {
		t.Fatalf("pendapatan_kami harus naik 1.120 + 1.500 − 500 = 2.120, naik %v", d)
	}
	if d := sesudah["total_revenue"].(float64) - sebelum["total_revenue"].(float64); d != 14000 {
		t.Fatalf("total_revenue (ongkos kotor) harus naik 14.000, naik %v", d)
	}
	for _, s := range sesudah["driver_stats"].([]map[string]interface{}) {
		if s["driver_phone"] == driver {
			if s["bagian_driver"] != 12880.0 || s["bagian_kami"] != 2120.0 {
				t.Fatalf("baris driver salah: %+v", s)
			}
			return
		}
	}
	t.Fatal("driver uji tidak muncul di driver_stats")
}
