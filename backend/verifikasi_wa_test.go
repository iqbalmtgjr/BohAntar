package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestNomorHPValid(t *testing.T) {
	for nomor, mau := range map[string]bool{
		"+6281234567890":     true,
		"+628123456789":      true,
		"+62812345678":       true,  // 0812 345 678: 10 digit, yang terpendek
		"+6289539876543":     true,  // formatnya sah; kebohongannya ditangkap verifikasi WA
		"+6221345678":        false, // telepon rumah Jakarta
		"+62abc":             false,
		"+628123":            false,
		"+62812345678901234": false,
	} {
		if nomorHPValid(nomor) != mau {
			t.Errorf("nomorHPValid(%q) = %v, mau %v", nomor, !mau, mau)
		}
	}
}

// Alur penuh: minta kode → webhook palsu ditolak → pesan dari nomor lain tidak
// memverifikasi → pesan dari nomor itu sendiri memverifikasi → daftar berhasil
// sekali saja.
func TestVerifikasiWATerbalik(t *testing.T) {
	bukaDBTes(t)
	t.Setenv("WA_NOMOR", "6281100000000")
	t.Setenv("WA_APP_SECRET", "rahasia-uji")
	stempel := time.Now().UnixNano()
	phone := fmt.Sprintf("+62812%07d", stempel%10000000)
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number = ?", phone) })
	ip := fmt.Sprintf("198.51.100.%d", stempel%250)

	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/api/auth/verifikasi-wa", strings.NewReader(`{"phone_number":"0`+phone[3:]+`"}`))
	r.Header.Set("X-Real-IP", ip)
	verifikasiWAHandler(w, r)
	var minta struct {
		Wajib bool   `json:"wajib"`
		Kode  string `json:"kode"`
		Teks  string `json:"teks"`
	}
	json.Unmarshal(w.Body.Bytes(), &minta)
	if w.Code != 200 || !minta.Wajib || len(minta.Kode) != 6 || !strings.Contains(minta.Teks, minta.Kode) {
		t.Fatalf("minta kode: %d %s", w.Code, w.Body)
	}

	daftar := func(kode string) int {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/api/auth/register", strings.NewReader(fmt.Sprintf(
			`{"phone_number":%q,"name":"Uji WA","email":"uji-wa-%d@contoh.id","password":"rahasia123","kode_wa":%q}`, phone, stempel, kode)))
		r.Header.Set("X-Real-IP", ip)
		registerHandler(w, r)
		return w.Code
	}
	kirim := func(dari, rahasia string) int {
		body := fmt.Sprintf(`{"entry":[{"changes":[{"value":{"messages":[{"from":%q,"type":"text","text":{"body":%q}}]}}]}]}`, dari, minta.Teks)
		mac := hmac.New(sha256.New, []byte(rahasia))
		mac.Write([]byte(body))
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/api/webhook/whatsapp", strings.NewReader(body))
		r.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(mac.Sum(nil)))
		waWebhookHandler(w, r)
		return w.Code
	}
	terverifikasi := func() bool { _, ok := statusVerifWA(minta.Kode); return ok }

	if c := daftar(""); c != 400 {
		t.Errorf("daftar tanpa kode (APK lama) saat verifikasi aktif: %d, mau 400", c)
	}
	if c := daftar(minta.Kode); c != 400 {
		t.Errorf("daftar sebelum kirim WA: %d, mau 400", c)
	}
	if c := kirim(phone[1:], "rahasia-salah"); c != 403 || terverifikasi() {
		t.Errorf("webhook bertanda tangan palsu: kode %d, terverifikasi %v", c, terverifikasi())
	}
	if c := kirim("6281299999999", "rahasia-uji"); c != 200 || terverifikasi() {
		t.Errorf("kode dikirim dari nomor lain: kode %d, terverifikasi %v — harus tetap belum", c, terverifikasi())
	}
	if c := kirim(phone[1:], "rahasia-uji"); c != 200 || !terverifikasi() {
		t.Fatalf("kode dikirim dari nomor sendiri: kode %d, terverifikasi %v", c, terverifikasi())
	}
	if c := daftar(minta.Kode); c != 201 {
		t.Fatalf("daftar setelah terverifikasi: %d, mau 201", c)
	}
	if _, ada := statusVerifWA(minta.Kode); ada {
		t.Error("kode masih hidup setelah dipakai mendaftar")
	}
}

// Tanpa WA_NOMOR/WA_APP_SECRET pendaftaran tetap seperti dulu.
func TestVerifikasiWAMatiTanpaKunci(t *testing.T) {
	t.Setenv("WA_NOMOR", "")
	if pesan := cekVerifWA("", "+6281234567890"); pesan != "" {
		t.Errorf("verifikasi mati tapi pendaftaran ditolak: %q", pesan)
	}
}

func TestKuotaDaftarPerJaringan(t *testing.T) {
	ip := fmt.Sprintf("kuota-uji-%d", time.Now().UnixNano())
	for i := 0; i < batasDaftarPerJam; i++ {
		if kuotaDaftarHabis(ip) {
			t.Fatalf("kuota habis setelah %d akun, batasnya %d", i, batasDaftarPerJam)
		}
		catatPendaftaran(ip)
	}
	if !kuotaDaftarHabis(ip) {
		t.Errorf("akun ke-%d dari jaringan yang sama masih lolos", batasDaftarPerJam+1)
	}
}

func TestNormalizePhoneMembuangPemisah(t *testing.T) {
	if got := normalizePhone(" 0812 3456-7890 "); got != "+6281234567890" || !nomorHPValid(got) {
		t.Errorf("normalizePhone dengan spasi & tanda hubung = %q", got)
	}
}
