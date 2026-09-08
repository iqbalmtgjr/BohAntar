package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Laporan bagi hasil dipakai untuk menagih dan membayar orang, jadi yang diuji
// bukan cuma "ada isinya": komisi tunai harus terpisah dari komisi dompet,
// pesanan di luar rentang tanggal tidak boleh ikut, dan pesanan yang belum
// selesai tidak boleh dihitung sebagai pendapatan.
func TestLaporanKomisiPisahTunaiDanPatuhTanggal(t *testing.T) {
	bukaDBTes(t)

	stempel := time.Now().Format("150405")
	driver := "+62899" + stempel
	rider := "+62898" + stempel
	penggunaUji(t, driver)
	penggunaUji(t, rider)

	hariIni := time.Now().Format("2006-01-02")
	// dompet 10.000 komisi 2.000 | tunai 20.000 komisi 5.000 | tunai lama (bulan
	// lalu) 30.000 komisi 9.000 | dompet belum selesai 40.000 komisi 8.000
	pesanan := []struct {
		metode, status string
		kapan          time.Time
		fare, komisi   float64
	}{
		{"wallet", "completed", time.Now(), 10000, 2000},
		{"cash", "completed", time.Now(), 20000, 5000},
		{"cash", "completed", time.Now().AddDate(0, 0, -40), 30000, 9000},
		{"wallet", "accepted", time.Now(), 40000, 8000},
	}
	for i, p := range pesanan {
		oid := fmt.Sprintf("test-komisi-%s-%d", stempel, i)
		waktu := p.kapan.Format(time.RFC3339)
		if err := dbSaveOrder(Order{
			ID: oid, RiderPhone: rider, RiderName: "Uji",
			PickupAddress: "A", DropoffAddress: "B",
			PickupLat: -0.0784, PickupLng: 111.4933, DropoffLat: -0.0700, DropoffLng: 111.4980,
			Fare: p.fare, Komisi: p.komisi, PaymentMethod: p.metode, Service: "BohAntar",
			Status: p.status, DriverPhone: driver, DriverName: "Driver Uji",
			CreatedAt: waktu, UpdatedAt: waktu,
		}); err != nil {
			t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
		}
		t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })
	}

	rec := httptest.NewRecorder()
	adminKomisiHandler(rec, httptest.NewRequest(http.MethodGet, "/api/admin/komisi?from="+hariIni+"&to="+hariIni, nil))
	if rec.Code != 200 {
		t.Fatalf("laporan gagal: %d %s", rec.Code, rec.Body.String())
	}
	var hasil struct {
		TotalKomisi  float64 `json:"total_komisi"`
		KomisiTunai  float64 `json:"komisi_tunai"`
		KomisiWallet float64 `json:"komisi_wallet"`
		Drivers      []struct {
			DriverPhone string  `json:"driver_phone"`
			OrderCount  int     `json:"order_count"`
			TotalOngkos float64 `json:"total_ongkos"`
			Komisi      float64 `json:"komisi"`
			KomisiTunai float64 `json:"komisi_tunai"`
		} `json:"drivers"`
	}
	json.Unmarshal(rec.Body.Bytes(), &hasil)

	var baris *struct {
		DriverPhone string  `json:"driver_phone"`
		OrderCount  int     `json:"order_count"`
		TotalOngkos float64 `json:"total_ongkos"`
		Komisi      float64 `json:"komisi"`
		KomisiTunai float64 `json:"komisi_tunai"`
	}
	for i := range hasil.Drivers {
		if hasil.Drivers[i].DriverPhone == driver {
			baris = &hasil.Drivers[i]
		}
	}
	if baris == nil {
		t.Fatalf("driver uji tidak muncul di laporan: %s", rec.Body.String())
	}
	if baris.OrderCount != 2 {
		t.Errorf("order dihitung %d, harusnya 2 — yang belum selesai dan yang bulan lalu tidak boleh ikut", baris.OrderCount)
	}
	if baris.Komisi != 7000 {
		t.Errorf("komisi %v, harusnya 7000 (2000 dompet + 5000 tunai)", baris.Komisi)
	}
	if baris.KomisiTunai != 5000 {
		t.Errorf("komisi tunai %v, harusnya 5000", baris.KomisiTunai)
	}
	if baris.TotalOngkos != 30000 {
		t.Errorf("total ongkos %v, harusnya 30000", baris.TotalOngkos)
	}
	if hasil.KomisiWallet+hasil.KomisiTunai != hasil.TotalKomisi {
		t.Errorf("tunai %v + dompet %v tidak sama dengan total %v", hasil.KomisiTunai, hasil.KomisiWallet, hasil.TotalKomisi)
	}

	// Tanggal ngawur dari query string tidak boleh sampai ke MySQL.
	rec = httptest.NewRecorder()
	adminKomisiHandler(rec, httptest.NewRequest(http.MethodGet, "/api/admin/komisi?from=kemarin", nil))
	if rec.Code != 400 {
		t.Errorf("tanggal ngawur dibalas %d, harusnya 400", rec.Code)
	}
}
