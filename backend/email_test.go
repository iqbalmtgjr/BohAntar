package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Halaman Kuota Layanan membaca sisa jatah dari akun Brevo. Paket SMS ikut
// di daftar plan dan tidak boleh terbaca sebagai kuota email; galat Brevo
// harus jadi -1, bukan 0 (0 berarti "jatah habis").
func TestSisaKreditBrevo(t *testing.T) {
	if s, _ := sisaKreditBrevo(); s != -1 {
		t.Fatalf("tanpa BREVO_API_KEY sisa = %v, mau -1", s)
	}

	balas := `{"plan":[{"type":"sms","creditsType":"sendLimit","credits":15},{"type":"free","creditsType":"sendLimit","credits":250}]}`
	kode := 200
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("api-key") != "kunci-uji" {
			w.WriteHeader(401)
			return
		}
		w.WriteHeader(kode)
		w.Write([]byte(balas))
	}))
	defer srv.Close()
	lama := brevoAPI
	brevoAPI = srv.URL
	defer func() { brevoAPI = lama }()
	t.Setenv("BREVO_API_KEY", "kunci-uji")

	if s, p := sisaKreditBrevo(); s != 250 || p != "free" {
		t.Fatalf("sisa = %v (%s), mau 250 (free)", s, p)
	}
	kode = 401
	if s, _ := sisaKreditBrevo(); s != -1 {
		t.Fatalf("Brevo menolak tapi sisa = %v, mau -1", s)
	}

	muEmail.Lock()
	hariEmail = pemakaianEmail{}
	muEmail.Unlock()
	catatEmail(func(p *pemakaianEmail) { p.Terkirim += 2 })
	if p := catatEmail(nil); p.Terkirim != 2 || p.Tanggal == "" {
		t.Fatalf("hitungan = %+v, mau 2 terkirim bertanggal hari ini", p)
	}
}
