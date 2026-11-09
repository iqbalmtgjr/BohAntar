package main

import (
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestFormatRupiah(t *testing.T) {
	kasus := map[int64]string{
		0:         "Rp0",
		999:       "Rp999",
		1000:      "Rp1.000",
		10000:     "Rp10.000",
		2000000:   "Rp2.000.000",
		123456789: "Rp123.456.789",
	}
	for n, mau := range kasus {
		if dapat := formatRupiah(n); dapat != mau {
			t.Errorf("formatRupiah(%d) = %q, mau %q", n, dapat, mau)
		}
	}
}

// Angka di halaman syarat dibaca dari konstanta yang dipakai kode. Kalau batas
// top up atau masa tunggu pesanan diubah, halaman ini ikut berubah — tes ini
// memastikan sambungannya tidak putus diam-diam.
func TestHalamanSyaratMengikutiKode(t *testing.T) {
	rec := httptest.NewRecorder()
	syaratKetentuanHandler(rec, httptest.NewRequest("GET", "/api/syarat", nil))
	if rec.Code != 200 {
		t.Fatalf("status %d, mau 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type %q, mau text/html", ct)
	}
	isi := rec.Body.String()
	for _, harus := range []string{
		formatRupiah(topUpMinimal),
		formatRupiah(topUpMaksimal),
		strconv.Itoa(int(batasPesananMenunggu.Minutes())) + " menit",
		kontakPrivasi(),
		tanggalSyarat,
		`href="/api/privasi"`,
	} {
		if !strings.Contains(isi, harus) {
			t.Errorf("halaman syarat tidak memuat %q", harus)
		}
	}
}

func TestHalamanSyaratHanyaGET(t *testing.T) {
	rec := httptest.NewRecorder()
	syaratKetentuanHandler(rec, httptest.NewRequest("POST", "/api/syarat", nil))
	if rec.Code != 405 {
		t.Fatalf("status %d, mau 405", rec.Code)
	}
}

// Dua halaman hukum saling menunjuk: yang membuka salah satunya dari Google
// Play harus bisa sampai ke yang lain tanpa menebak alamatnya.
func TestHalamanPrivasiMenautKeSyarat(t *testing.T) {
	rec := httptest.NewRecorder()
	kebijakanPrivasiHandler(rec, httptest.NewRequest("GET", "/api/privasi", nil))
	if !strings.Contains(rec.Body.String(), `href="/api/syarat"`) {
		t.Fatal("halaman privasi belum menaut ke /api/syarat")
	}
}
