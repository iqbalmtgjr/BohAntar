package main

import (
	"testing"
	"time"
)

// Sebelum BohCar dibuka, papan orderan dan siaran "Orderan baru" dikirim ke
// semua driver tanpa melihat kendaraannya — driver motor bisa menerima
// penumpang mobil. Jenis kendaraan diambil dari pengajuan yang DISETUJUI, dan
// driver tanpa pengajuan dianggap motor.
func TestOrderanDisaringMenurutKendaraan(t *testing.T) {
	bukaDBTes(t)
	stempel := time.Now().Format("150405")
	mobil := "+62855" + stempel + "1"
	ditolak := "+62855" + stempel + "2"
	lama := "+62855" + stempel + "3"
	for _, p := range []string{mobil, ditolak, lama} {
		penggunaUji(t, p)
	}

	now := time.Now().Format(time.RFC3339)
	for _, a := range []DriverApplication{
		{PhoneNumber: mobil, VehicleType: "mobil", Status: "approved"},
		{PhoneNumber: ditolak, VehicleType: "mobil", Status: "rejected"},
	} {
		a.ID, a.Name, a.CreatedAt = newID("app"), "Uji", now
		if err := dbSaveApplication(a); err != nil {
			t.Fatalf("gagal menyiapkan pengajuan: %v", err)
		}
	}

	harap := map[string]string{mobil: "mobil", ditolak: "motor", lama: "motor"}
	for p, k := range harap {
		if got := kendaraanDriver(p); got != k {
			t.Errorf("kendaraanDriver(%s) = %q, harusnya %q", p, got, k)
		}
	}

	for _, k := range []struct {
		layanan, kendaraan string
		boleh              bool
	}{
		{"BohCar", "mobil", true},
		{"BohCar", "motor", false},
		{"BohRide", "motor", true},
		{"BohRide", "mobil", false},
		{"BohSend", "motor", true},
		{"BohSend", "mobil", true},
		{"BohFood", "mobil", true},
		{"BohAntar", "motor", true},
	} {
		if cocokKendaraan(k.layanan, k.kendaraan) != k.boleh {
			t.Errorf("cocokKendaraan(%s, %s) harusnya %v", k.layanan, k.kendaraan, k.boleh)
		}
	}
}
