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

// Alur penyewa BohRental dari aplikasi: katalog hanya memuat armada aktif dari
// mitra yang langganannya jalan, sewa yang diajukan muncul di "Sewa saya"
// lengkap dengan kendaraan dan mitranya, dan penyewa bisa membatalkannya.
func TestAlurPenyewaRental(t *testing.T) {
	bukaDBTes(t)
	const mitraA, mitraB, penyewa = "+62800000401", "+62800000402", "+62800000403"
	for _, u := range []struct{ phone, peran string }{{mitraA, "rental_partner"}, {mitraB, "rental_partner"}, {penyewa, "rider"}} {
		if err := dbSaveUser(User{PhoneNumber: u.phone, Name: "Uji", Role: u.peran, CreatedAt: time.Now().Format(time.RFC3339), Badge: "Silver"}); err != nil {
			t.Fatalf("pengguna uji: %v", err)
		}
	}
	// Mobil, sewa, dan langganan ikut terhapus lewat ON DELETE CASCADE.
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number IN (?, ?, ?)", mitraA, mitraB, penyewa) })
	db.Exec("UPDATE users SET business_name = 'Rental Uji A' WHERE phone_number = ?", mitraA)
	dbSavePartnerSubscription(PartnerSubscription{PhoneNumber: mitraA, Status: "TRIAL", ValidUntil: time.Now().AddDate(0, 0, 7).Format(time.RFC3339), UpdatedAt: time.Now().Format(time.RFC3339)})
	dbSavePartnerSubscription(PartnerSubscription{PhoneNumber: mitraB, Status: "ACTIVE", ValidUntil: time.Now().AddDate(0, 0, -1).Format(time.RFC3339), UpdatedAt: time.Now().Format(time.RFC3339)})

	sebagai := func(phone, peran, method, path, body string) *http.Request {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		ctx := context.WithValue(r.Context(), ctxPhone, phone)
		return r.WithContext(context.WithValue(ctx, ctxRole, peran))
	}
	mobil := func(pemilik, merek, status string) string {
		w := httptest.NewRecorder()
		rentalCarsHandler(w, sebagai(pemilik, "rental_partner", http.MethodPost, "/api/rental/cars",
			fmt.Sprintf(`{"brand":%q,"model":"Uji","plate_number":"UJI %d","transmission":"Manual","seats":7,"price_per_day":300000,"status":%q,"vehicle_type":"car"}`,
				merek, time.Now().UnixNano()%1000000, status)))
		var c RentalCar
		json.Unmarshal(w.Body.Bytes(), &c)
		if w.Code != 200 || c.ID == "" {
			t.Fatalf("mobil uji: %d %s", w.Code, w.Body)
		}
		return c.ID
	}
	aktif, nonaktif, habis := mobil(mitraA, "Toyota", "active"), mobil(mitraA, "Daihatsu", "inactive"), mobil(mitraB, "Honda", "active")

	w := httptest.NewRecorder()
	katalogRentalHandler(w, sebagai(penyewa, "rider", http.MethodGet, "/api/rental/katalog", ""))
	var katalog struct {
		Kendaraan []KendaraanSewa `json:"kendaraan"`
	}
	json.Unmarshal(w.Body.Bytes(), &katalog)
	ada := map[string]KendaraanSewa{}
	for _, k := range katalog.Kendaraan {
		ada[k.ID] = k
	}
	if k, ok := ada[aktif]; !ok || k.MitraNama != "Rental Uji A" {
		t.Fatalf("mobil aktif tidak ada di katalog atau nama mitranya salah: %+v (kode %d)", k, w.Code)
	}
	if _, ok := ada[nonaktif]; ok {
		t.Error("mobil nonaktif ikut tampil di katalog")
	}
	if _, ok := ada[habis]; ok {
		t.Error("mobil mitra yang langganannya habis ikut tampil di katalog")
	}

	besok := time.Now().AddDate(0, 0, 1).Format("2006-01-02")
	lusaLagi := time.Now().AddDate(0, 0, 3).Format("2006-01-02")
	w = httptest.NewRecorder()
	rentalBookingsHandler(w, sebagai(penyewa, "rider", http.MethodPost, "/api/rental/bookings",
		fmt.Sprintf(`{"car_id":%q,"start_time":"%s 08:00:00","end_time":"%s 08:00:00"}`, aktif, besok, lusaLagi)))
	var sewa RentalBooking
	json.Unmarshal(w.Body.Bytes(), &sewa)
	if w.Code != 200 || sewa.TotalPrice != 600000 {
		t.Fatalf("ajukan sewa dua hari: %d %s", w.Code, w.Body)
	}

	w = httptest.NewRecorder()
	rentalBookingsHandler(w, sebagai(penyewa, "rider", http.MethodGet, "/api/rental/bookings", ""))
	var milikku []RentalBooking
	json.Unmarshal(w.Body.Bytes(), &milikku)
	if len(milikku) != 1 || milikku[0].CarName != "Toyota Uji" || milikku[0].OwnerName != "Rental Uji A" || milikku[0].OwnerPhone != mitraA {
		t.Fatalf("Sewa saya: %+v", milikku)
	}

	w = httptest.NewRecorder()
	rentalBookingDetailHandler(w, sebagai(penyewa, "rider", http.MethodPut, "/api/rental/bookings/"+sewa.ID, `{"status":"cancelled"}`))
	if w.Code != 200 {
		t.Fatalf("penyewa membatalkan: %d %s", w.Code, w.Body)
	}

	if judul, isi := kabarSewa("rejected", "Mobil sedang servis"); judul == "" || isi != "Mobil sedang servis" {
		t.Errorf("kabar penolakan harus membawa alasan mitra: %q %q", judul, isi)
	}
	if judul, _ := kabarSewa("pending", ""); judul != "" {
		t.Error("status pending tidak perlu dikabarkan")
	}
}
