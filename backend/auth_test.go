package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func init() { jwtKey = []byte("kunci-uji-yang-panjangnya-cukup-32-karakter") }

func bearer(tok string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Authorization", "Bearer "+tok)
	return r
}

func TestTokenRoundTrip(t *testing.T) {
	tok, err := issueToken("+628123456789", "admin")
	if err != nil {
		t.Fatalf("issueToken: %v", err)
	}
	phone, role, ok := parseBearer(bearer(tok))
	if !ok || phone != "+628123456789" || role != "admin" {
		t.Fatalf("got %q/%q ok=%v", phone, role, ok)
	}
}

func TestTokenRejectsTampering(t *testing.T) {
	tok, _ := issueToken("+628123456789", "rider")

	// Tanda tangan dari kunci lain harus ditolak.
	good := jwtKey
	jwtKey = []byte("kunci-penyerang-yang-juga-32-karakter-lebih")
	other, _ := issueToken("+628000000000", "admin")
	jwtKey = good
	if _, _, ok := parseBearer(bearer(other)); ok {
		t.Error("token dengan kunci berbeda diterima")
	}

	// Payload yang diubah harus ditolak.
	if _, _, ok := parseBearer(bearer(tok[:len(tok)-3] + "aaa")); ok {
		t.Error("token yang diubah diterima")
	}

	// Token gaya lama tidak boleh lolos lagi.
	if _, _, ok := parseBearer(bearer("mock-jwt-token-for-+628000000000")); ok {
		t.Error("token mock lama masih diterima")
	}

	// Tanpa header sama sekali.
	if _, _, ok := parseBearer(httptest.NewRequest(http.MethodGet, "/", nil)); ok {
		t.Error("request tanpa Authorization diterima")
	}
}

func TestTokenExpiry(t *testing.T) {
	orig := tokenTTL
	tokenTTL = -time.Minute // sudah kedaluwarsa saat diterbitkan
	tok, _ := issueToken("+628123456789", "rider")
	tokenTTL = orig
	if _, _, ok := parseBearer(bearer(tok)); ok {
		t.Error("token kedaluwarsa masih diterima")
	}
}

func TestRequireRole(t *testing.T) {
	handler := requireRole("admin")(func(w http.ResponseWriter, r *http.Request) {
		if callerPhone(r) == "" || callerRole(r) != "admin" {
			t.Error("context tidak terisi identitas pemanggil")
		}
		w.WriteHeader(http.StatusOK)
	})

	cases := []struct {
		name string
		tok  string
		want int
	}{
		{"tanpa token", "", 401},
		{"role salah", mustToken(t, "+628123456789", "rider"), 403},
		{"role benar", mustToken(t, "+628000000000", "admin"), 200},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodGet, "/api/admin/users", nil)
		if c.tok != "" {
			r.Header.Set("Authorization", "Bearer "+c.tok)
		}
		w := httptest.NewRecorder()
		handler(w, r)
		if w.Code != c.want {
			t.Errorf("%s: status %d, harusnya %d", c.name, w.Code, c.want)
		}
	}
}

func mustToken(t *testing.T, phone, role string) string {
	t.Helper()
	tok, err := issueToken(phone, role)
	if err != nil {
		t.Fatalf("issueToken: %v", err)
	}
	return tok
}

func TestPasswordHashing(t *testing.T) {
	hash, err := hashPassword("rahasia123")
	if err != nil {
		t.Fatalf("hashPassword: %v", err)
	}
	if hash == "rahasia123" {
		t.Fatal("password tersimpan sebagai teks biasa")
	}
	if !checkPassword(hash, "rahasia123") {
		t.Error("password yang benar ditolak")
	}
	if checkPassword(hash, "salah") {
		t.Error("password yang salah diterima")
	}
	// Akun tanpa password (hash kosong) tidak boleh bisa login dengan string kosong.
	if checkPassword("", "") {
		t.Error("hash kosong + password kosong diterima")
	}
}

func TestOTPLifecycle(t *testing.T) {
	const phone = "+628123456789"

	saveOTP(phone, "654321")
	if consumeOTP(phone, "111111") {
		t.Error("OTP salah diterima")
	}
	if !consumeOTP(phone, "654321") {
		t.Error("OTP benar ditolak")
	}
	if consumeOTP(phone, "654321") {
		t.Error("OTP bisa dipakai dua kali")
	}

	// Backdoor lama tidak boleh berlaku lagi.
	saveOTP(phone, "654321")
	if consumeOTP(phone, "123456") {
		t.Error("backdoor OTP 123456 masih berlaku")
	}

	// Batas percobaan.
	saveOTP(phone, "654321")
	for i := 0; i < otpMaxAttempts; i++ {
		consumeOTP(phone, "000000")
	}
	if consumeOTP(phone, "654321") {
		t.Error("OTP masih berlaku setelah melewati batas percobaan")
	}

	// Kedaluwarsa.
	saveOTP(phone, "654321")
	otpMutex.Lock()
	otpStore[phone].expires = time.Now().Add(-time.Second)
	otpMutex.Unlock()
	if consumeOTP(phone, "654321") {
		t.Error("OTP kedaluwarsa masih diterima")
	}
}

func TestSanitizeServiceName(t *testing.T) {
	// "|" harus mati di gerbang: reason jadwal dipisah dengan pipa,
	// nama jasa yang membawa pipa akan dibaca sebagai field lain.
	cases := map[string]string{
		"  Dengan Supir  ":   "Dengan Supir",
		"Supir | KTP: /hack": "Supir / KTP: /hack",
		"":                   "",
		"   ":                "",
	}
	for in, want := range cases {
		if got := sanitizeServiceName(in); got != want {
			t.Fatalf("sanitizeServiceName(%q) = %q, mau %q", in, got, want)
		}
	}
}

func TestBookingTransition(t *testing.T) {
	// Alur pesanan searah. Yang dijaga di sini terutama aksi dari halaman basi:
	// menolak pesanan yang sudah selesai, atau menyetujui yang sudah ditolak.
	valid := [][2]string{
		{"pending", "confirmed"}, {"pending", "rejected"}, {"pending", "cancelled"},
		{"confirmed", "ongoing"}, {"confirmed", "completed"}, {"confirmed", "cancelled"}, {"ongoing", "completed"},
	}
	invalid := [][2]string{
		{"completed", "rejected"}, {"rejected", "confirmed"}, {"ongoing", "confirmed"},
		{"cancelled", "ongoing"}, {"pending", "completed"}, {"", "confirmed"},
	}
	for _, c := range valid {
		if !canTransition(c[0], c[1]) {
			t.Fatalf("%s -> %s seharusnya boleh", c[0], c[1])
		}
	}
	for _, c := range invalid {
		if canTransition(c[0], c[1]) {
			t.Fatalf("%s -> %s seharusnya ditolak", c[0], c[1])
		}
	}
}

func TestNormalizePhone(t *testing.T) {
	cases := map[string]string{
		"081234567890":   "+6281234567890",
		"81234567890":    "+6281234567890",
		"+6281234567890": "+6281234567890",
		" 081234567890 ": "+6281234567890",
	}
	for in, want := range cases {
		if got := normalizePhone(in); got != want {
			t.Errorf("normalizePhone(%q) = %q, mau %q", in, got, want)
		}
	}
}
