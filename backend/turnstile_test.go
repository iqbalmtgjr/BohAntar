package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestTolakTurnstile(t *testing.T) {
	cf := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if r.Form.Get("secret") != "rahasia" {
			t.Errorf("secret tidak ikut terkirim: %q", r.Form.Get("secret"))
		}
		if r.Form.Get("response") == "token-sah" {
			w.Write([]byte(`{"success":true}`))
			return
		}
		w.Write([]byte(`{"success":false,"error-codes":["invalid-input-response"]}`))
	}))
	defer cf.Close()
	asli := turnstileURL
	turnstileURL = cf.URL
	defer func() { turnstileURL = asli }()

	minta := func(origin, token string) *http.Request {
		r := httptest.NewRequest(http.MethodPost, "/api/auth/login", nil)
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if token != "" {
			r.Header.Set("X-Turnstile", token)
		}
		return r
	}

	t.Setenv("TURNSTILE_SITEKEY", "kunci-situs")
	t.Setenv("TURNSTILE_SECRET", "")
	if tolakTurnstile(minta("https://x", ""), true) != "" {
		t.Fatal("tanpa TURNSTILE_SECRET fitur harus mati")
	}
	t.Setenv("TURNSTILE_SITEKEY", "")
	t.Setenv("TURNSTILE_SECRET", "rahasia")
	if tolakTurnstile(minta("https://x", ""), true) != "" {
		t.Fatal("secret tanpa sitekey: dashboard tak bisa memberi token, jadi fitur harus mati")
	}

	t.Setenv("TURNSTILE_SITEKEY", "kunci-situs")
	kasus := []struct {
		nama        string
		origin      string
		token       string
		selaluWajib bool
		lolos       bool
	}{
		{"aplikasi (tanpa Origin) di endpoint bersama", "", "", false, true},
		{"browser tanpa token", "https://bohantar.indotechconsulting.com", "", false, false},
		{"browser token palsu", "https://bohantar.indotechconsulting.com", "palsu", false, false},
		{"browser token sah", "https://bohantar.indotechconsulting.com", "token-sah", false, true},
		{"endpoint khusus web tanpa Origin tetap wajib", "", "", true, false},
		{"endpoint khusus web token sah", "", "token-sah", true, true},
	}
	for _, k := range kasus {
		if lolos := tolakTurnstile(minta(k.origin, k.token), k.selaluWajib) == ""; lolos != k.lolos {
			t.Errorf("%s: lolos=%v, seharusnya %v", k.nama, lolos, k.lolos)
		}
	}

	// Cloudflare tak terjangkau: gagal tertutup.
	turnstileURL = "http://127.0.0.1:1"
	if tolakTurnstile(minta("https://x", "token-sah"), false) == "" {
		t.Fatal("siteverify gagal tapi permintaan lolos")
	}
}
