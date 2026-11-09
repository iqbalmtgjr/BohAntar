package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Mitra memilih password sendiri saat mendaftar; persetujuan admin tidak boleh
// menimpanya dengan password acak, dan hash-nya tidak boleh bocor di daftar.
func TestDaftarMitraPakaiPasswordSendiri(t *testing.T) {
	bukaDBTes(t)

	phone := "+62897" + time.Now().Format("150405")
	email := "mitra" + time.Now().Format("150405") + "@contoh.test"
	t.Cleanup(func() {
		db.Exec("DELETE FROM partner_subscriptions WHERE phone_number = ?", phone)
		db.Exec("DELETE FROM partner_applications WHERE phone_number = ?", phone)
		db.Exec("DELETE FROM users WHERE phone_number = ?", phone)
	})

	daftar := func(pw string) *httptest.ResponseRecorder {
		b, _ := json.Marshal(map[string]string{
			"type": "rental", "name": "Uji Mitra", "phone_number": phone, "email": email,
			"ktp_number": "6101", "business_name": "Rental Uji", "address": "Sintang", "password": pw,
		})
		w := httptest.NewRecorder()
		partnerRegisterHandler(w, httptest.NewRequest(http.MethodPost, "/api/partner/register", bytes.NewReader(b)))
		return w
	}
	if got := daftar("pendek"); got.Code != 400 {
		t.Fatalf("password 6 karakter diterima: %d", got.Code)
	}
	if got := daftar("rahasia123"); got.Code != 201 {
		t.Fatalf("pendaftaran ditolak: %d %s", got.Code, got.Body.String())
	}

	lw := httptest.NewRecorder()
	adminPartnerApplicationsHandler(lw, httptest.NewRequest(http.MethodGet, "/api/admin/partner-applications", nil))
	if strings.Contains(lw.Body.String(), "password") || strings.Contains(lw.Body.String(), "$2a$") {
		t.Fatal("daftar pengajuan membocorkan password/hash")
	}

	var appID string
	if err := db.QueryRow("SELECT id FROM partner_applications WHERE phone_number = ?", phone).Scan(&appID); err != nil {
		t.Fatalf("id pengajuan tidak terbaca: %v", err)
	}
	ar := httptest.NewRecorder()
	adminPartnerApplicationActionHandler(ar, httptest.NewRequest(http.MethodPost, "/api/admin/partner-applications/"+appID+"/approve", nil))
	if ar.Code != 200 {
		t.Fatalf("approve gagal: %d %s", ar.Code, ar.Body.String())
	}
	var hasil struct {
		InitialPassword string `json:"initial_password"`
	}
	json.Unmarshal(ar.Body.Bytes(), &hasil)
	if hasil.InitialPassword != "" {
		t.Fatal("approve menimpa password pilihan mitra dengan password acak")
	}

	b, _ := json.Marshal(map[string]string{"email": email, "password": "rahasia123"})
	r := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewReader(b))
	r.RemoteAddr = "203.0.113.10:1234"
	w := httptest.NewRecorder()
	loginHandler(w, r)
	if w.Code != 200 {
		t.Fatalf("mitra tidak bisa masuk dengan password pilihannya: %d %s", w.Code, w.Body.String())
	}
}
