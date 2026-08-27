package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Dua mitra rental berbagi satu database. Tes ini menjaga agar data mereka tidak
// pernah saling terlihat atau saling menimpa. Butuh MySQL lokal.
func TestRentalPartnersTetapTerpisah(t *testing.T) {
	_, _ = connectTestDB(t) // menyiapkan koneksi & skip kalau MySQL tidak ada

	as := func(phone, method, path, body string) *http.Request {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		ctx := context.WithValue(r.Context(), ctxPhone, phone)
		return r.WithContext(context.WithValue(ctx, ctxRole, "rental_partner"))
	}

	// Dua mitra sungguhan dari tabel users.
	rows, err := db.Query("SELECT phone_number FROM users WHERE role = 'rental_partner' LIMIT 2")
	if err != nil {
		t.Skip("tidak bisa membaca daftar mitra")
	}
	var mitra []string
	for rows.Next() {
		var p string
		if rows.Scan(&p) == nil {
			mitra = append(mitra, p)
		}
	}
	rows.Close()
	if len(mitra) < 2 {
		t.Skip("butuh dua mitra rental untuk menguji pemisahan data")
	}
	A, B := mitra[0], mitra[1]

	plat := fmt.Sprintf("UJI %d", time.Now().UnixNano()%100000)
	mobilA := fmt.Sprintf(`{"brand":"Toyota","model":"Yaris","plate_number":%q,"transmission":"Manual","seats":5,"price_per_day":250000,"status":"active","vehicle_type":"car"}`, plat)

	w := httptest.NewRecorder()
	rentalCarsHandler(w, as(A, http.MethodPost, "/api/rental/cars", mobilA))
	if w.Code != 200 {
		t.Fatalf("mitra A gagal menambah mobil: %d %s", w.Code, w.Body)
	}
	var punyaA RentalCar
	json.Unmarshal(w.Body.Bytes(), &punyaA)
	defer db.Exec("DELETE FROM rental_cars WHERE id = ?", punyaA.ID)

	// Mitra B mendaftarkan plat yang sama. Dulu ini diam-diam menimpa mobil A
	// lewat ON DUPLICATE KEY UPDATE dan B tidak mendapat mobil apa pun.
	mobilB := fmt.Sprintf(`{"brand":"Honda","model":"Jazz RS","plate_number":%q,"transmission":"Automatic","seats":5,"price_per_day":999000,"status":"active","vehicle_type":"car"}`, plat)
	w = httptest.NewRecorder()
	rentalCarsHandler(w, as(B, http.MethodPost, "/api/rental/cars", mobilB))
	if w.Code != 409 {
		t.Errorf("plat kembar harusnya ditolak 409, dapat %d %s", w.Code, w.Body)
	}

	var merek, model string
	var harga float64
	var pemilik string
	if err := db.QueryRow("SELECT owner_phone, brand, model, price_per_day FROM rental_cars WHERE id = ?", punyaA.ID).
		Scan(&pemilik, &merek, &model, &harga); err != nil {
		t.Fatalf("mobil mitra A hilang: %v", err)
	}
	if pemilik != A || merek != "Toyota" || model != "Yaris" || harga != 250000 {
		t.Errorf("mobil mitra A tertimpa mitra lain: %s %s %s %v", pemilik, merek, model, harga)
	}

	// Daftar armada mitra B tidak boleh memuat mobil mitra A.
	w = httptest.NewRecorder()
	rentalCarsHandler(w, as(B, http.MethodGet, "/api/rental/cars?owner_phone="+A, ""))
	var armadaB []RentalCar
	json.Unmarshal(w.Body.Bytes(), &armadaB)
	for _, c := range armadaB {
		if c.OwnerPhone != B {
			t.Errorf("mitra B melihat armada milik %s", c.OwnerPhone)
		}
	}

	// Jadwal mitra A tidak boleh bisa dibuat maupun dibaca oleh mitra B.
	jadwal := fmt.Sprintf(`{"car_id":%q,"start_time":%q,"end_time":%q,"reason":"Servis"}`,
		punyaA.ID,
		time.Now().Add(400*24*time.Hour).Format("2006-01-02 15:04:05"),
		time.Now().Add(402*24*time.Hour).Format("2006-01-02 15:04:05"))

	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(B, http.MethodPost, "/api/rental/schedules", jadwal))
	if w.Code != 403 {
		db.Exec("DELETE FROM rental_car_schedules WHERE car_id = ?", punyaA.ID)
		t.Errorf("mitra B bisa menjadwalkan mobil mitra A: %d %s", w.Code, w.Body)
	}

	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(A, http.MethodPost, "/api/rental/schedules", jadwal))
	if w.Code != 200 {
		t.Fatalf("mitra A gagal menjadwalkan mobilnya sendiri: %d %s", w.Code, w.Body)
	}
	var jadwalA RentalCarSchedule
	json.Unmarshal(w.Body.Bytes(), &jadwalA)
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", jadwalA.ID)

	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(B, http.MethodGet, "/api/rental/schedules", ""))
	var jadwalB []RentalCarSchedule
	json.Unmarshal(w.Body.Bytes(), &jadwalB)
	for _, s := range jadwalB {
		if s.ID == jadwalA.ID {
			t.Error("mitra B membaca jadwal milik mitra A")
		}
	}

	// Menutup jadwal milik mitra lain juga harus ditolak.
	w = httptest.NewRecorder()
	rentalScheduleDetailHandler(w, as(B, http.MethodPut, "/api/rental/schedules/"+jadwalA.ID, `{"status":"completed"}`))
	if w.Code != 403 {
		t.Errorf("mitra B bisa menutup jadwal mitra A: %d %s", w.Code, w.Body)
	}

	// Aturan denda tersimpan per mitra, bukan global.
	w = httptest.NewRecorder()
	rentalSettingsHandler(w, as(A, http.MethodPut, "/api/rental/settings", `{"late_fee_mode":"amount","late_fee_value":75000}`))
	if w.Code != 200 {
		t.Fatalf("mitra A gagal menyimpan aturan denda: %d %s", w.Code, w.Body)
	}
	defer db.Exec("DELETE FROM rental_settings WHERE owner_phone = ?", A)

	w = httptest.NewRecorder()
	rentalSettingsHandler(w, as(B, http.MethodGet, "/api/rental/settings", ""))
	var aturanB RentalSettings
	json.Unmarshal(w.Body.Bytes(), &aturanB)
	if aturanB.LateFeeVal == 75000 {
		t.Error("aturan denda mitra A bocor ke mitra B")
	}
}
