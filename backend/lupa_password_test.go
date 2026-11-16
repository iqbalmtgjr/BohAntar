package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// Lupa password lewat email: balasan sama untuk email terdaftar/tidak, rem laju
// per email, tautan sekali pakai, kedaluwarsa, dan password benar-benar berganti.
func TestLupaPasswordEmail(t *testing.T) {
	bukaDBTes(t)
	migrasiResetPassword()
	t.Setenv("SMTP_HOST", "127.0.0.1") // kiriman gagal cepat di goroutine; yang diuji alurnya
	t.Setenv("SMTP_PORT", "1")
	const phone, email = "+62800000501", "uji-lupa@contoh.test"
	if err := dbSaveUser(User{PhoneNumber: phone, Name: "Uji", Email: email, Role: "rider",
		CreatedAt: time.Now().Format(time.RFC3339), Badge: "Silver"}); err != nil {
		t.Fatalf("gagal menyiapkan pengguna: %v", err)
	}
	dbSetPassword(phone, "passwordLama1")
	t.Cleanup(func() {
		db.Exec("DELETE FROM reset_password WHERE email LIKE '%@contoh.test'")
		db.Exec("DELETE FROM users WHERE phone_number = ?", phone)
	})

	minta := func(e string) (int, string) {
		w := httptest.NewRecorder()
		lupaPasswordHandler(w, httptest.NewRequest(http.MethodPost, "/api/auth/lupa-password", strings.NewReader(`{"email":"`+e+`"}`)))
		return w.Code, w.Body.String()
	}
	kode, ada := minta(email)
	_, tidakAda := minta("tidak-ada@contoh.test")
	if kode != 200 || ada != tidakAda {
		t.Fatalf("email terdaftar (%d %s) dan tidak terdaftar (%s) harus dibalas sama", kode, ada, tidakAda)
	}
	var baris int
	db.QueryRow("SELECT COUNT(*) FROM reset_password WHERE email = ? AND phone_number = ?", email, phone).Scan(&baris)
	if baris != 1 {
		t.Fatalf("token untuk email terdaftar tidak tersimpan (%d baris)", baris)
	}
	minta(email)
	minta(email)
	if kode, _ := minta(email); kode != 429 {
		t.Fatalf("permintaan ke-4 dalam sejam dibalas %d, harusnya 429", kode)
	}

	// Token buatan tes, karena yang tersimpan hanya hash-nya.
	tokenUji := func(umur time.Duration) string {
		tok := strings.Repeat("ab", 16) + time.Now().Format("150405.000000000")
		db.Exec("INSERT INTO reset_password (token_hash, phone_number, email, ip, created_at) VALUES (?, ?, ?, 'tes', ?)",
			hashTokenReset(tok), phone, email, waktuKeDB(time.Now().Add(-umur).Format(time.RFC3339)))
		return tok
	}
	halaman := func(method, tok string, form url.Values) string {
		r := httptest.NewRequest(method, "/api/reset-password/"+tok, strings.NewReader(form.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		w := httptest.NewRecorder()
		resetPasswordHalamanHandler(w, r)
		return w.Body.String()
	}

	tok := tokenUji(0)
	if !strings.Contains(halaman(http.MethodGet, tok, nil), "Buat password baru") {
		t.Fatal("GET tautan sah tidak menampilkan formulir")
	}
	if !strings.Contains(halaman(http.MethodPost, tok, url.Values{"password": {"passwordBaru1"}, "ulang": {"lain12345"}}), "tidak sama") {
		t.Fatal("password yang tidak sama diterima")
	}
	if !strings.Contains(halaman(http.MethodPost, tok, url.Values{"password": {"passwordBaru1"}, "ulang": {"passwordBaru1"}}), "tersimpan") {
		t.Fatal("password baru tidak tersimpan")
	}
	var hash string
	db.QueryRow("SELECT password FROM users WHERE phone_number = ?", phone).Scan(&hash)
	if !checkPassword(hash, "passwordBaru1") {
		t.Fatal("password di database tidak berganti")
	}
	if !strings.Contains(halaman(http.MethodPost, tok, url.Values{"password": {"passwordLagi1"}, "ulang": {"passwordLagi1"}}), "tidak berlaku") {
		t.Fatal("tautan bisa dipakai dua kali")
	}
	if !strings.Contains(halaman(http.MethodGet, tokenUji(resetBerlaku+time.Minute), nil), "tidak berlaku") {
		t.Fatal("tautan kedaluwarsa masih menampilkan formulir")
	}
}
