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

// Chat sewa: hanya penyewa dan mitra pemilik armada yang bisa membaca dan
// mengirim, lencana belum dibaca menyala untuk lawan bicara dan padam saat
// dibuka, dan percakapannya ikut lenyap saat akun penyewa dihapus.
func TestChatSewa(t *testing.T) {
	bukaDBTes(t)
	const mitra, penyewa, orangLain = "+62800000501", "+62800000502", "+62800000503"
	for _, u := range []struct{ phone, peran string }{{mitra, "rental_partner"}, {penyewa, "rider"}, {orangLain, "rider"}} {
		if err := dbSaveUser(User{PhoneNumber: u.phone, Name: "Uji " + u.peran, Role: u.peran, CreatedAt: time.Now().Format(time.RFC3339), Badge: "Silver"}); err != nil {
			t.Fatalf("pengguna uji: %v", err)
		}
	}
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number IN (?, ?, ?)", mitra, penyewa, orangLain) })
	db.Exec("UPDATE users SET business_name = 'Rental Chat Uji' WHERE phone_number = ?", mitra)

	mobil, sewa := fmt.Sprintf("car-chat-%d", time.Now().UnixNano()), fmt.Sprintf("booking-chat-%d", time.Now().UnixNano())
	if _, err := db.Exec(`INSERT INTO rental_cars (id, owner_phone, brand, model, plate_number, transmission, price_per_day, created_at)
		VALUES (?, ?, 'Toyota', 'Avanza', ?, 'Manual', 300000, NOW())`, mobil, mitra, "KB "+sewa[len(sewa)-6:]); err != nil {
		t.Fatalf("mobil uji: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO rental_bookings (id, car_id, customer_phone, start_time, end_time, total_price, status, created_at, updated_at)
		VALUES (?, ?, ?, NOW(), NOW() + INTERVAL 1 DAY, 300000, 'pending', NOW(), NOW())`, sewa, mobil, penyewa); err != nil {
		t.Fatalf("sewa uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM chat_sewa WHERE booking_id = ?", sewa) })

	panggil := func(phone, peran, method, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/rental/chat/"+sewa, strings.NewReader(body))
		ctx := context.WithValue(r.Context(), ctxPhone, phone)
		w := httptest.NewRecorder()
		chatSewaHandler(w, r.WithContext(context.WithValue(ctx, ctxRole, peran)))
		return w
	}
	sewaDi := func(phone, peran string) RentalBooking {
		r := httptest.NewRequest(http.MethodGet, "/api/rental/bookings", nil)
		ctx := context.WithValue(r.Context(), ctxPhone, phone)
		w := httptest.NewRecorder()
		rentalBookingsHandler(w, r.WithContext(context.WithValue(ctx, ctxRole, peran)))
		var daftar []RentalBooking
		json.Unmarshal(w.Body.Bytes(), &daftar)
		for _, b := range daftar {
			if b.ID == sewa {
				return b
			}
		}
		t.Fatalf("sewa uji tidak ada di daftar %s", phone)
		return RentalBooking{}
	}
	belum := func(phone, peran string) int { return sewaDi(phone, peran).ChatBelum }

	if w := panggil(penyewa, "rider", http.MethodPost, `{"content":"  "}`); w.Code != 400 {
		t.Errorf("pesan kosong: %d, mau 400", w.Code)
	}
	if w := panggil(penyewa, "rider", http.MethodPost, `{"content":"Halo, mobilnya bisa diantar?"}`); w.Code != 201 {
		t.Fatalf("penyewa kirim: %d %s", w.Code, w.Body)
	}
	if w := panggil(orangLain, "rider", http.MethodGet, ""); w.Code != 403 {
		t.Errorf("orang lain membaca chat sewa: %d, mau 403", w.Code)
	}
	if w := panggil(orangLain, "rider", http.MethodPost, `{"content":"nyelonong"}`); w.Code != 403 {
		t.Errorf("orang lain mengirim ke chat sewa: %d, mau 403", w.Code)
	}
	if n := belum(mitra, "rental_partner"); n != 1 {
		t.Errorf("lencana mitra sebelum dibuka: %d, mau 1", n)
	}
	if n := belum(penyewa, "rider"); n != 0 {
		t.Errorf("lencana penyewa untuk pesannya sendiri: %d, mau 0", n)
	}

	w := panggil(mitra, "rental_partner", http.MethodGet, "")
	var isi struct {
		Messages  []pesanSewa `json:"messages"`
		Penyewa   string      `json:"penyewa"`
		Kendaraan string      `json:"kendaraan"`
	}
	json.Unmarshal(w.Body.Bytes(), &isi)
	if isi.Penyewa != "Uji rider" || isi.Kendaraan != "Toyota Avanza" {
		t.Errorf("judul chat: penyewa=%q kendaraan=%q", isi.Penyewa, isi.Kendaraan)
	}
	if w.Code != 200 || len(isi.Messages) != 1 || isi.Messages[0].Content != "Halo, mobilnya bisa diantar?" || isi.Messages[0].SenderPhone != penyewa {
		t.Fatalf("mitra membaca: %d %s", w.Code, w.Body)
	}
	if n := belum(mitra, "rental_partner"); n != 0 {
		t.Errorf("lencana mitra setelah dibuka: %d, mau 0", n)
	}

	if w := panggil(mitra, "rental_partner", http.MethodPost, `{"content":"Bisa, ke mana?"}`); w.Code != 201 {
		t.Fatalf("mitra balas: %d %s", w.Code, w.Body)
	}
	json.Unmarshal(panggil(penyewa, "rider", http.MethodGet, "").Body.Bytes(), &isi)
	if len(isi.Messages) != 2 || isi.Messages[1].SenderName != "Rental Chat Uji" {
		t.Errorf("balasan mitra harus atas nama usahanya: %+v", isi.Messages)
	}
	// Daftar Chat portal mitra: pesan terakhir + tanda "Kamu:" ikut di daftar sewa.
	if b := sewaDi(mitra, "rental_partner"); b.ChatTerakhir != "Bisa, ke mana?" || !b.ChatDariSaya || b.ChatWaktu == "" {
		t.Errorf("ringkasan chat mitra: %q dariSaya=%v waktu=%q", b.ChatTerakhir, b.ChatDariSaya, b.ChatWaktu)
	}
	if b := sewaDi(penyewa, "rider"); b.ChatDariSaya {
		t.Error("pesan mitra terbaca sebagai pesan penyewa sendiri")
	}

	u, _ := dbGetUser(penyewa)
	if kode, pesan := hapusAkun(u); kode != 200 {
		t.Fatalf("hapus akun penyewa: %d %s", kode, pesan)
	}
	var sisa int
	db.QueryRow("SELECT COUNT(*) FROM chat_sewa WHERE booking_id = ?", sewa).Scan(&sisa)
	if sisa != 0 {
		t.Errorf("%d pesan chat sewa tertinggal setelah akun penyewa dihapus", sisa)
	}
}
