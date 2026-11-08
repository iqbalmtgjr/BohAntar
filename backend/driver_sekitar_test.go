package main

import (
	"encoding/json"
	"math"
	"net/http/httptest"
	"testing"
	"time"
)

// Peta penumpang hanya boleh menampilkan driver yang benar-benar bisa diambil:
// siaga, dekat, kendaraannya cocok — dan titiknya kasar, tanpa identitas.
func TestDriverSekitarHanyaYangSiaga(t *testing.T) {
	bukaDBTes(t)
	stempel := time.Now().Format("150405")
	no := func(i string) string { return "+62856" + stempel + i }
	const lat, lng = -0.0784, 111.4933

	// Tiap driver diberi titik sendiri supaya bisa dikenali dari koordinatnya.
	type d struct {
		phone    string
		dLat     float64
		siaga    bool
		mobil    bool
		sibuk    bool
		harusAda bool
	}
	daftar := []d{
		{phone: no("1"), dLat: 0.0101, siaga: true, harusAda: true},
		{phone: no("2"), dLat: 0.0202, siaga: true, sibuk: true},
		{phone: no("3"), dLat: 0.0303},                           // offline
		{phone: no("4"), dLat: 0.1004, siaga: true},              // ±11 km
		{phone: no("5"), dLat: 0.0405, siaga: true, mobil: true}, // BohRide tak dijemput mobil
		{phone: no("6"), dLat: 0.0506, siaga: true},              // si pemanggil
	}
	for _, x := range daftar {
		penggunaUji(t, x.phone)
		var waktu interface{}
		if x.siaga {
			waktu = time.Now()
		}
		if _, err := db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1, driver_lat = ?, driver_lng = ?, driver_loc_at = ? WHERE phone_number = ?",
			lat+x.dLat+0.00004, lng, waktu, x.phone); err != nil {
			t.Fatal(err)
		}
		if x.mobil {
			if err := dbSaveApplication(DriverApplication{ID: newID("app"), PhoneNumber: x.phone, Name: "Uji", VehicleType: "mobil", Status: "approved", CreatedAt: time.Now().Format(time.RFC3339)}); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { db.Exec("DELETE FROM driver_applications WHERE phone_number = ?", x.phone) })
		}
		if x.sibuk {
			oid := pesananUji(t, no("9"), "cash", "accepted", 10000)
			db.Exec("UPDATE orders SET driver_phone = ? WHERE id = ?", x.phone, oid)
		}
	}

	tok, _ := issueToken(no("6"), "driver")
	minta := func(layanan string) []map[string]float64 {
		req := httptest.NewRequest("GET", "/api/drivers/sekitar?lat=-0.0784&lng=111.4933&layanan="+layanan, nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		rec := httptest.NewRecorder()
		requireAuth(driverSekitarHandler)(rec, req)
		if rec.Code != 200 {
			t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
		}
		var hasil struct {
			Drivers []map[string]interface{} `json:"drivers"`
		}
		json.Unmarshal(rec.Body.Bytes(), &hasil)
		var titik []map[string]float64
		for _, x := range hasil.Drivers {
			if _, ada := x["phone_number"]; ada {
				t.Errorf("identitas driver ikut terkirim: %v", x)
			}
			titik = append(titik, map[string]float64{"lat": x["lat"].(float64), "lng": x["lng"].(float64)})
		}
		return titik
	}
	ada := func(titik []map[string]float64, dLat float64) bool {
		for _, p := range titik {
			if p["lat"] == bulatUji(lat+dLat) && p["lng"] == bulatUji(lng) {
				return true
			}
		}
		return false
	}

	ride := minta("BohRide")
	for _, x := range daftar {
		if ada(ride, x.dLat) != x.harusAda {
			t.Errorf("driver %s (dLat %v): tampil=%v, harusnya %v", x.phone, x.dLat, !x.harusAda, x.harusAda)
		}
	}
	// Titik dibulatkan: tambahan 0,00004 tadi tidak boleh ikut terkirim.
	if !ada(ride, 0.0101) {
		t.Error("titik driver siaga tidak dibulatkan ke 0,001°")
	}
	if !ada(minta("BohCar"), 0.0405) {
		t.Error("driver mobil harus tampil untuk BohCar")
	}
}

func bulatUji(x float64) float64 { return math.Round(x*1000) / 1000 }
