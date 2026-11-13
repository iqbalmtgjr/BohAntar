package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Celah yang ditemukan 13 Nov 2026 di produksi: jalan pintas menjadi mitra atau
// admin tanpa persetujuan siapa pun.

func panggilSebagai(h http.HandlerFunc, phone, role, method, path string, badan any) int {
	b, _ := json.Marshal(badan)
	r := httptest.NewRequest(method, path, bytes.NewReader(b))
	r = r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, phone), ctxRole, role))
	w := httptest.NewRecorder()
	h(w, r)
	return w.Code
}

// Penumpang (daftar bebas dari aplikasi) tidak boleh membuat warung atau armada
// sendiri; mitra yang disetujui tetap boleh.
func TestPenumpangTidakBisaMembuatWarungAtauArmada(t *testing.T) {
	bukaDBTes(t)
	akhiran := time.Now().UnixNano() % 100000000
	penumpang := fmt.Sprintf("+62897%08d", akhiran)
	mitra := fmt.Sprintf("+62898%08d", akhiran)
	penggunaUji(t, penumpang)
	penggunaUji(t, mitra)
	db.Exec("UPDATE users SET role = 'food_merchant' WHERE phone_number = ?", mitra)
	t.Cleanup(func() {
		db.Exec("DELETE FROM food_merchants WHERE owner_phone IN (?, ?)", penumpang, mitra)
		db.Exec("DELETE FROM rental_cars WHERE owner_phone = ?", penumpang)
	})

	warung := map[string]any{"restaurant_name": "Warung Palsu", "lat": 0.07, "lng": 111.49, "is_open": true}
	// Token yang mengaku food_merchant tetap ditolak: perannya dibaca dari DB.
	if kode := panggilSebagai(foodMerchantHandler, penumpang, "food_merchant", "POST", "/api/food/merchant", warung); kode != 403 {
		t.Fatalf("penumpang membuat warung: status %d, harusnya 403", kode)
	}
	var n int
	db.QueryRow("SELECT COUNT(*) FROM food_merchants WHERE owner_phone = ?", penumpang).Scan(&n)
	if n != 0 {
		t.Fatalf("warung penumpang tetap tersimpan (%d baris)", n)
	}
	mobil := map[string]any{"brand": "Toyota", "model": "Avanza", "plate_number": fmt.Sprintf("KB %d UJI", akhiran%10000), "price_per_day": 300000}
	if kode := panggilSebagai(rentalCarsHandler, penumpang, "rider", "POST", "/api/rental/cars", mobil); kode != 403 {
		t.Fatalf("penumpang menambah armada: status %d, harusnya 403", kode)
	}

	if kode := panggilSebagai(foodMerchantHandler, mitra, "food_merchant", "POST", "/api/food/merchant", warung); kode != 200 {
		t.Fatalf("mitra BohFood yang sah ditolak: status %d", kode)
	}
}

// Super admin tidak boleh bisa dimasuki atau di-reset lewat Google: akun Google
// bisa dibuat untuk email non-Gmail siapa pun yang menguasai domainnya.
func TestGoogleTidakMembukaAkunAdmin(t *testing.T) {
	bukaDBTes(t)
	akhiran := time.Now().UnixNano() % 100000000
	admin := fmt.Sprintf("+62896%08d", akhiran)
	email := fmt.Sprintf("admin%d@domain-belum-dibeli.test", akhiran)
	penggunaUji(t, admin)
	db.Exec("UPDATE users SET role = 'admin', email = ? WHERE phone_number = ?", email, admin)
	if err := dbSetPassword(admin, "password-lama-123"); err != nil {
		t.Fatal(err)
	}

	asli := verifikasiGoogle
	verifikasiGoogle = func(context.Context, string, string) (string, string, error) { return email, "Penyerang", nil }
	t.Cleanup(func() { verifikasiGoogle = asli })

	kirim := func(h http.HandlerFunc, badan map[string]string) (int, string) {
		b, _ := json.Marshal(badan)
		w := httptest.NewRecorder()
		h(w, httptest.NewRequest("POST", "/", bytes.NewReader(b)))
		return w.Code, w.Body.String()
	}
	if kode, isi := kirim(googleLoginHandler, map[string]string{"id_token": "x"}); kode != 403 || bytes.Contains([]byte(isi), []byte("token")) {
		t.Fatalf("masuk Google ke admin: status %d, isi %s", kode, isi)
	}
	if kode, _ := kirim(resetPasswordGoogleHandler, map[string]string{"id_token": "x", "new_password": "password-penyerang"}); kode != 403 {
		t.Fatalf("reset password admin lewat Google: status %d, harusnya 403", kode)
	}
	var hash string
	db.QueryRow("SELECT password FROM users WHERE phone_number = ?", admin).Scan(&hash)
	if !checkPassword(hash, "password-lama-123") {
		t.Fatal("password admin berubah")
	}
}
