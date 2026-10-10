package main

import (
	"testing"
	"time"
)

// Panel pelacakan dulu menulis "Honda Beat • KB 1234 XX" dan "4.9 (120)" untuk
// semua driver. Yang ditampilkan sekarang harus datang dari pengajuan yang
// disetujui dan ulasan sungguhan — dan kosong kalau datanya memang tidak ada.
func TestInfoDriverDariDataSungguhan(t *testing.T) {
	bukaDBTes(t)
	stempel := time.Now().Format("150405")
	driver := "+62833" + stempel + "1"
	lama := "+62833" + stempel + "2"
	penggunaUji(t, driver)
	penggunaUji(t, lama)

	kosong := infoDriver(lama)
	if kosong["kendaraan"] != "" || kosong["plat"] != "" || kosong["jumlah_ulasan"] != 0 {
		t.Fatalf("driver tanpa pengajuan dan ulasan diberi data: %v", kosong)
	}

	now := time.Now().Format(time.RFC3339)
	for i, status := range []string{"rejected", "approved"} {
		if err := dbSaveApplication(DriverApplication{
			ID: newID("app"), PhoneNumber: driver, Name: "Uji", Status: status, CreatedAt: now,
			VehicleModel: []string{"Motor Lama", "Honda Beat"}[i], VehiclePlate: " KB 1234 XX ",
		}); err != nil {
			t.Fatalf("gagal menyiapkan pengajuan: %v", err)
		}
	}
	for _, bintang := range []int{5, 4} {
		oid := pesananUji(t, "+62844"+stempel+"9", "cash", "completed", 10000)
		if _, err := db.Exec("INSERT INTO order_ratings (order_id, driver_phone, rider_phone, stars, created_at) VALUES (?, ?, ?, ?, ?)",
			oid, driver, "+62844"+stempel+"9", bintang, time.Now()); err != nil {
			t.Fatalf("gagal menyiapkan ulasan: %v", err)
		}
	}

	info := infoDriver(driver)
	if info["kendaraan"] != "Honda Beat" || info["plat"] != "KB 1234 XX" || info["rating"] != 4.5 || info["jumlah_ulasan"] != 2 {
		t.Fatalf("info driver salah: %v", info)
	}
}
