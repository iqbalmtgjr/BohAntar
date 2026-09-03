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

// Rem login dijaga satu tes saja: sepuluh tebakan salah dari satu alamat masih
// dilayani, yang kesebelas ditolak — dan alamat lain tidak ikut terkena.
func TestRemLoginMenutupSetelahSepuluhGagal(t *testing.T) {
	gagalLoginMu.Lock()
	gagalLogin = map[string][]time.Time{}
	gagalLoginMu.Unlock()

	for i := 0; i < batasGagalLogin; i++ {
		if terlaluSeringGagal("1.2.3.4") {
			t.Fatalf("percobaan ke-%d sudah ditolak, seharusnya masih boleh", i+1)
		}
		catatGagalLogin("1.2.3.4")
	}
	if !terlaluSeringGagal("1.2.3.4") {
		t.Fatal("percobaan ke-11 lolos, rem tidak menutup")
	}
	if terlaluSeringGagal("5.6.7.8") {
		t.Fatal("alamat lain ikut terkunci")
	}

	// Catatan yang sudah lewat jendela harus dilupakan, bukan mengunci selamanya.
	gagalLoginMu.Lock()
	gagalLogin["1.2.3.4"] = []time.Time{time.Now().Add(-jendelaGagalLogin - time.Minute)}
	gagalLoginMu.Unlock()
	if terlaluSeringGagal("1.2.3.4") {
		t.Fatal("catatan kedaluwarsa masih menghitung")
	}
}

// alamatPemanggil harus membedakan penelepon lewat header dari proxy: tanpa
// itu semua permintaan tampak datang dari reverse proxy di 127.0.0.1 dan satu
// penyerang mengunci seluruh pengguna. Yang lebih berbahaya sebaliknya: kalau
// alamatnya boleh dikarang penelepon, remnya bisa dilewati cukup dengan
// mengganti satu header tiap percobaan.
func TestAlamatPemanggilTidakBisaDipalsukan(t *testing.T) {
	r := httptest.NewRequest("POST", "/api/auth/login", nil)
	r.RemoteAddr = "127.0.0.1:54321"
	if got := alamatPemanggil(r); got != "127.0.0.1" {
		t.Fatalf("tanpa header seharusnya 127.0.0.1, dapat %q", got)
	}

	// X-Forwarded-For tidak boleh mengubah apa pun: isinya cuma bisa
	// dipercaya kalau proxy di depan menambahkan alamat asli ke ujungnya, dan
	// backend tidak punya cara memastikan itu.
	r.Header.Set("X-Forwarded-For", "1.1.1.1, 203.0.113.9")
	if got := alamatPemanggil(r); got != "127.0.0.1" {
		t.Fatalf("X-Forwarded-For seharusnya diabaikan, dapat %q", got)
	}

	// X-Real-IP diisi nginx dari alamat sambungan, jadi hanya ia yang dipakai.
	r.Header.Set("X-Real-IP", "198.51.100.7")
	if got := alamatPemanggil(r); got != "198.51.100.7" {
		t.Fatalf("X-Real-IP seharusnya dipakai, dapat %q", got)
	}

	// Penyerang yang mengganti-ganti alamat karangan tetap jatuh ke ember
	// yang sama, karena yang dihitung alamat dari nginx.
	for _, karangan := range []string{"9.9.9.9", "8.8.8.8", "7.7.7.7"} {
		p := httptest.NewRequest("POST", "/api/auth/login", nil)
		p.RemoteAddr = "127.0.0.1:1"
		p.Header.Set("X-Real-IP", "203.0.113.50")
		p.Header.Set("X-Forwarded-For", karangan)
		if got := alamatPemanggil(p); got != "203.0.113.50" {
			t.Fatalf("alamat karangan %q lolos jadi %q", karangan, got)
		}
	}

	// Tanpa X-Real-IP, alamat karangan tetap tidak boleh memisahkan ember:
	// semua jatuh ke alamat proxy. Tumpul, tapi tidak bisa dilewati.
	for _, karangan := range []string{"9.9.9.9", "8.8.8.8", "7.7.7.7"} {
		p := httptest.NewRequest("POST", "/api/auth/login", nil)
		p.RemoteAddr = "127.0.0.1:1"
		p.Header.Set("X-Forwarded-For", karangan)
		if got := alamatPemanggil(p); got != "127.0.0.1" {
			t.Fatalf("tanpa X-Real-IP, %q lolos jadi %q", karangan, got)
		}
	}
}
