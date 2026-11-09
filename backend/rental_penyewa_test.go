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

// Ketersediaan dari sisi aplikasi (perbaikan 10 Nov): pesanan basi tidak lagi
// mengunci kendaraan selamanya, penyapu membatalkan permintaan yang tak
// ditanggapi, pesan bentrok menyebut rentangnya, dan katalog memuat rentang
// terpakai termasuk kendaraan yang belum kembali.
func TestKetersediaanRentalAplikasi(t *testing.T) {
	bukaDBTes(t)
	const mitra, penyewa, penyewaLama = "+62800000421", "+62800000422", "+62800000423"
	for _, u := range []struct{ phone, peran string }{{mitra, "rental_partner"}, {penyewa, "rider"}, {penyewaLama, "rider"}} {
		if err := dbSaveUser(User{PhoneNumber: u.phone, Name: "Uji", Role: u.peran, CreatedAt: time.Now().Format(time.RFC3339), Badge: "Silver"}); err != nil {
			t.Fatalf("pengguna uji: %v", err)
		}
	}
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number IN (?, ?, ?)", mitra, penyewa, penyewaLama) })
	dbSavePartnerSubscription(PartnerSubscription{PhoneNumber: mitra, Status: "ACTIVE", ValidUntil: time.Now().AddDate(0, 1, 0).Format(time.RFC3339), UpdatedAt: time.Now().Format(time.RFC3339)})

	sebagai := func(phone, peran, method, path, body string) *http.Request {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		return r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, phone), ctxRole, peran))
	}
	w := httptest.NewRecorder()
	rentalCarsHandler(w, sebagai(mitra, "rental_partner", http.MethodPost, "/api/rental/cars",
		fmt.Sprintf(`{"brand":"Uji","model":"Sedia","plate_number":"UJI %d","transmission":"Manual","seats":7,"price_per_day":300000,"status":"active","vehicle_type":"car"}`, time.Now().UnixNano()%1000000)))
	var mobil RentalCar
	json.Unmarshal(w.Body.Bytes(), &mobil)
	if mobil.ID == "" {
		t.Fatalf("mobil uji: %d %s", w.Code, w.Body)
	}
	jam := func(d time.Duration) string { return time.Now().Add(d).Format("2006-01-02 15:04:05") }
	sisip := func(status string, mulai, selesai time.Duration) string {
		id := newID("booking")
		if _, err := db.Exec("INSERT INTO rental_bookings (id, car_id, customer_phone, start_time, end_time, total_price, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 300000, ?, NOW(), NOW())",
			id, mobil.ID, penyewaLama, jam(mulai), jam(selesai), status); err != nil {
			t.Fatalf("sewa uji %s: %v", status, err)
		}
		return id
	}
	ajukan := func(mulai, selesai time.Duration) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		rentalBookingsHandler(w, sebagai(penyewa, "rider", http.MethodPost, "/api/rental/bookings",
			fmt.Sprintf(`{"car_id":%q,"start_time":%q,"end_time":%q}`, mobil.ID, jam(mulai), jam(selesai))))
		return w
	}
	hari := 24 * time.Hour

	// Permintaan lama yang tak pernah ditanggapi mitra dan tanggalnya lewat.
	basi := sisip("pending", -3*hari, -2*hari)
	sisip("pending", -time.Hour, -30*time.Minute) // masih dalam tenggang 2 jam: tidak dibatalkan
	sisip("confirmed", -5*hari, -4*hari)          // penyewa tak datang, tak pernah dimulai
	if w := ajukan(hari, 3*hari); w.Code != 200 {
		t.Fatalf("pesanan basi masih mengunci kendaraan: %d %s", w.Code, w.Body)
	}

	// Penyapu: yang basi dibatalkan dengan catatan, yang akan datang tidak disentuh.
	kedaluwarsakanSewa()
	var status, catatan string
	db.QueryRow("SELECT status, COALESCE(notes, '') FROM rental_bookings WHERE id = ?", basi).Scan(&status, &catatan)
	if status != "cancelled" || catatan != catatanSewaKedaluwarsa {
		t.Errorf("sewa basi: status %q catatan %q", status, catatan)
	}
	var menunggu int
	db.QueryRow("SELECT COUNT(*) FROM rental_bookings WHERE car_id = ? AND status = 'pending'", mobil.ID).Scan(&menunggu)
	if menunggu != 2 {
		t.Errorf("penyapu membatalkan yang akan datang / masih dalam tenggang: sisa pending %d, mau 2", menunggu)
	}

	// Bentrok dengan permintaan besok: pesannya menyebut rentang yang terpakai.
	if w := ajukan(2*hari, 4*hari); w.Code != 409 || !strings.Contains(w.Body.String(), "sudah terpakai") {
		t.Errorf("bentrok biasa: %d %s", w.Code, w.Body)
	}
	// Di luar rentang itu tetap boleh.
	if w := ajukan(5*hari, 6*hari); w.Code != 200 {
		t.Errorf("tanggal bebas ditolak: %d %s", w.Code, w.Body)
	}

	// Kendaraan yang sedang disewa dan lewat jatuh tempo: semua tanggal ditolak
	// dengan pesan "belum dikembalikan", dan katalog menandainya.
	sisip("ongoing", -2*hari, -time.Hour)
	if w := ajukan(20*hari, 21*hari); w.Code != 409 || !strings.Contains(w.Body.String(), "belum dikembalikan") {
		t.Errorf("kendaraan belum kembali: %d %s", w.Code, w.Body)
	}
	w = httptest.NewRecorder()
	katalogRentalHandler(w, sebagai(penyewa, "rider", http.MethodGet, "/api/rental/katalog", ""))
	var katalog struct {
		Kendaraan []KendaraanSewa `json:"kendaraan"`
	}
	json.Unmarshal(w.Body.Bytes(), &katalog)
	for _, k := range katalog.Kendaraan {
		if k.ID != mobil.ID {
			continue
		}
		var belum, aktif int
		for _, r := range k.Terpakai {
			if r.BelumKembali {
				belum++
			} else {
				aktif++
			}
		}
		// Dua permintaan aktif (besok & hari ke-5) + satu yang belum kembali;
		// yang basi/dibatalkan/tak datang tidak tampil.
		if belum != 1 || aktif != 2 {
			t.Errorf("rentang terpakai di katalog: %+v", k.Terpakai)
		}
		return
	}
	t.Fatal("mobil uji tidak ada di katalog")
}
