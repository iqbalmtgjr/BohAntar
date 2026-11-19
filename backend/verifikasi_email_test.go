package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestEmailDaftarValid(t *testing.T) {
	for email, mau := range map[string]bool{
		"budi@gmail.com":           true,
		"a.b+c@sub.domain.co.id":   true,
		"budi@gmail":               false,
		"@gmail.com":               false,
		"budi@gmail.com.":          false,
		"budi @gmail.com":          false,
		"budi@gmail.com\r\nBcc: x": false,
		"a@b.com,c@d.com":          false,
	} {
		if emailDaftarValid(email) != mau {
			t.Errorf("emailDaftarValid(%q) = %v, mau %v", email, !mau, mau)
		}
	}
}

// Kode: kirim ulang dijeda, tebakan dibatasi, dan hanya kode yang sudah dicek
// yang bisa dipakai mendaftar — sekali saja.
func TestKodeVerifEmail(t *testing.T) {
	email := fmt.Sprintf("uji%d@contoh.test", time.Now().UnixNano())
	kode, tunggu := buatKodeVerifEmail(email)
	if kode == "" || tunggu != "" {
		t.Fatalf("kode pertama gagal: %q %q", kode, tunggu)
	}
	if _, tunggu := buatKodeVerifEmail(email); tunggu == "" {
		t.Fatal("kirim ulang dalam semenit seharusnya ditahan")
	}
	if cekVerifEmail(kode, email) == "" {
		t.Fatal("kode yang belum diketik di aplikasi tidak boleh dipakai mendaftar")
	}
	if cekKodeEmail("lain@contoh.test", kode) == "" {
		t.Fatal("kode email lain tidak boleh cocok")
	}
	salah := "000000"
	if kode == salah {
		salah = "111111"
	}
	for i := 0; i < salahKodeMaks; i++ {
		if cekKodeEmail(email, salah) == "" {
			t.Fatal("kode salah dianggap cocok")
		}
	}
	if cekKodeEmail(email, kode) == "" {
		t.Fatal("setelah 5 kali salah, kode benar pun harus ditolak sampai minta kode baru")
	}

	// Minta kode baru (jeda semenit dilewati dengan memundurkan jam kirim).
	verifEmailMu.Lock()
	verifEmailKe[email].kirim[0] = time.Now().Add(-2 * time.Minute)
	verifEmailMu.Unlock()
	kode, _ = buatKodeVerifEmail(email)
	if pesan := cekKodeEmail(email, kode); pesan != "" {
		t.Fatalf("kode baru yang benar ditolak: %s", pesan)
	}
	if pesan := cekVerifEmail(kode, email); pesan != "" {
		t.Fatalf("email terverifikasi tapi ditolak saat daftar: %s", pesan)
	}
	habiskanVerifEmail(email)
	if cekVerifEmail(kode, email) == "" {
		t.Fatal("kode yang sudah dipakai mendaftar masih berlaku")
	}

	// Batas per jam per alamat.
	verifEmailMu.Lock()
	verifEmailKe[email] = &verifEmail{kirim: []time.Time{
		time.Now().Add(-50 * time.Minute), time.Now().Add(-40 * time.Minute), time.Now().Add(-30 * time.Minute),
		time.Now().Add(-20 * time.Minute), time.Now().Add(-10 * time.Minute),
	}}
	verifEmailMu.Unlock()
	if _, tunggu := buatKodeVerifEmail(email); tunggu == "" {
		t.Fatal("kiriman keenam dalam sejam seharusnya ditolak")
	}
}

// Alur penuh lewat handler: minta kode → kode salah → kode benar → daftar
// sekali saja. SMTP palsu: kirimEmail gagal di goroutine, kodenya dibaca dari peta.
func TestVerifikasiEmailAlurDaftar(t *testing.T) {
	bukaDBTes(t)
	t.Setenv("WA_NOMOR", "")
	t.Setenv("VERIFIKASI_EMAIL", "1")
	t.Setenv("SMTP_HOST", "127.0.0.1")
	t.Setenv("SMTP_PORT", "1")
	stempel := time.Now().UnixNano()
	phone := fmt.Sprintf("+62813%07d", stempel%10000000)
	email := fmt.Sprintf("uji-email-%d@contoh.id", stempel)
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number = ?", phone) })
	ip := fmt.Sprintf("203.0.113.%d", stempel%250)

	panggil := func(h http.HandlerFunc, path, body string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", path, strings.NewReader(body))
		r.Header.Set("X-Real-IP", ip)
		h(w, r)
		return w
	}
	daftar := func(kodeEmail string) int {
		return panggil(registerHandler, "/api/auth/register", fmt.Sprintf(
			`{"phone_number":%q,"name":"Uji Email","email":%q,"password":"rahasia123","kode_email":%q}`, phone, " "+strings.ToUpper(email), kodeEmail)).Code
	}

	if w := panggil(verifikasiEmailHandler, "/api/auth/verifikasi-email", `{"email":"`+email+`"}`); w.Code != 200 || !strings.Contains(w.Body.String(), `"wajib":true`) {
		t.Fatalf("minta kode: %d %s", w.Code, w.Body)
	}
	verifEmailMu.Lock()
	kode := verifEmailKe[email].kode
	verifEmailMu.Unlock()

	if c := daftar(""); c != 400 {
		t.Errorf("daftar tanpa kode (APK lama): %d, mau 400", c)
	}
	if c := daftar(kode); c != 400 {
		t.Errorf("daftar sebelum kode diketik di aplikasi: %d, mau 400", c)
	}
	if w := panggil(verifikasiEmailHandler, "/api/auth/verifikasi-email", `{"email":"`+email+`","kode":"99999x"}`); w.Code != 400 {
		t.Errorf("kode salah: %d, mau 400", w.Code)
	}
	if w := panggil(verifikasiEmailHandler, "/api/auth/verifikasi-email", `{"email":"`+email+`","kode":"`+kode+`"}`); w.Code != 200 || !strings.Contains(w.Body.String(), `"terverifikasi":true`) {
		t.Fatalf("kode benar: %d %s", w.Code, w.Body)
	}
	if c := daftar(kode); c != 201 {
		t.Fatalf("daftar setelah email terverifikasi: %d, mau 201", c)
	}
	if w := panggil(verifikasiEmailHandler, "/api/auth/verifikasi-email", `{"email":"`+email+`"}`); w.Code != 409 {
		t.Errorf("minta kode untuk email yang sudah terdaftar: %d, mau 409", w.Code)
	}
}

// Syarat daftar: WA ATAU email, sesuai yang dinyalakan.
func TestCekVerifDaftar(t *testing.T) {
	email := fmt.Sprintf("daftar%d@contoh.test", time.Now().UnixNano())
	kodeEmail, _ := buatKodeVerifEmail(email)
	cekKodeEmail(email, kodeEmail)
	defer habiskanVerifEmail(email)

	nyala := func(wa, mail bool) {
		t.Setenv("WA_NOMOR", map[bool]string{true: "6281100000000"}[wa])
		t.Setenv("WA_APP_SECRET", map[bool]string{true: "rahasia"}[wa])
		t.Setenv("VERIFIKASI_EMAIL", map[bool]string{true: "1"}[mail])
		t.Setenv("SMTP_HOST", map[bool]string{true: "smtp.contoh.test"}[mail])
	}
	kasus := []struct {
		nama              string
		wa, mail          bool
		kodeWA, kodeEmail string
		lolos             bool
	}{
		{"semua mati: daftar bebas", false, false, "", "", true},
		{"email nyala, APK lama tanpa kode", false, true, "", "", false},
		{"email nyala, kode email sah", false, true, "", kodeEmail, true},
		{"email nyala, kode email karangan", false, true, "", "123456x", false},
		{"WA nyala saja, kode email karangan tak melewati WA", true, false, "", kodeEmail, false},
		{"WA + email nyala, pilih email", true, true, "", kodeEmail, true},
		{"WA + email nyala, tanpa kode", true, true, "", "", false},
	}
	for _, k := range kasus {
		nyala(k.wa, k.mail)
		if lolos := cekVerifDaftar(k.kodeWA, "+6281234567890", k.kodeEmail, email) == ""; lolos != k.lolos {
			t.Errorf("%s: lolos=%v, mau %v", k.nama, lolos, k.lolos)
		}
	}
}
