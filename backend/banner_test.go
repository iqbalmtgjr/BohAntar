package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

// Banner tampil di beranda semua pemesan, jadi yang dijaga: hanya yang aktif
// keluar di rute publik dengan urutan yang diminta, isian ngawur ditolak
// sebelum tersimpan, dan PUT ke id karangan tidak diam-diam membuat banner baru.
func TestBannerBeranda(t *testing.T) {
	bukaDBTes(t)
	if _, err := db.Exec(skemaBannerBeranda); err != nil {
		t.Fatalf("tabel banner: %v", err)
	}
	migrasiSkema(kolomTargetBanner)
	t.Cleanup(func() { db.Exec("DELETE FROM banner_beranda WHERE judul LIKE 'Uji banner%'") })

	kirim := func(method, path string, b Banner) (int, Banner) {
		body, _ := json.Marshal(b)
		w := httptest.NewRecorder()
		adminBannerHandler(w, httptest.NewRequest(method, path, bytes.NewReader(body)))
		var hasil struct {
			Banner Banner `json:"banner"`
		}
		json.Unmarshal(w.Body.Bytes(), &hasil)
		return w.Code, hasil.Banner
	}
	publik := func() string {
		w := httptest.NewRecorder()
		bannerPublikHandler(w, httptest.NewRequest(http.MethodGet, "/api/banner", nil))
		var hasil struct {
			Banner []Banner `json:"banner"`
		}
		json.Unmarshal(w.Body.Bytes(), &hasil)
		var judul []string
		for _, b := range hasil.Banner {
			if strings.HasPrefix(b.Judul, "Uji banner") {
				judul = append(judul, b.Judul)
			}
		}
		return strings.Join(judul, ",")
	}

	for _, b := range []Banner{
		{Judul: ""},
		{Judul: "Uji banner x", Warna: "pelangi"},
		{Judul: "Uji banner x", Tujuan: "BohTerbang"},
		{Judul: "Uji banner x", Tujuan: "url", URL: "http://tidak-aman.id"},
		{Judul: "Uji banner x", GambarURL: "javascript:alert(1)"},
	} {
		if kode, _ := kirim(http.MethodPost, "/api/admin/banner", b); kode != 400 {
			t.Errorf("banner %+v dibalas %d, harusnya 400", b, kode)
		}
	}

	_, kedua := kirim(http.MethodPost, "/api/admin/banner", Banner{Judul: "Uji banner kedua", Aktif: true, Urutan: 902})
	_, pertama := kirim(http.MethodPost, "/api/admin/banner", Banner{Judul: "Uji banner pertama", Tujuan: "BohFood", Target: " fm-queen ", URL: "https://dibuang.id", Aktif: true, Urutan: 901})
	_, mati := kirim(http.MethodPost, "/api/admin/banner", Banner{Judul: "Uji banner mati", Tujuan: "BohRide", Target: "dibuang", Urutan: 900})
	if pertama.ID == "" || kedua.ID == "" || mati.ID == "" {
		t.Fatal("banner yang sah gagal dibuat")
	}
	if pertama.URL != "" || pertama.Warna != "biru" {
		t.Errorf("tautan untuk tujuan selain url harusnya dibuang dan warna bawaan biru, dapat %+v", pertama)
	}
	if pertama.Target != "fm-queen" || mati.Target != "" {
		t.Errorf("target harusnya dirapikan untuk BohFood dan dibuang untuk BohRide, dapat %q dan %q", pertama.Target, mati.Target)
	}
	if daftar, _ := daftarBanner(false); !slices.ContainsFunc(daftar, func(b Banner) bool { return b.ID == pertama.ID && b.Target == "fm-queen" }) {
		t.Error("target tidak terbaca balik dari database")
	}
	if got := publik(); got != "Uji banner pertama,Uji banner kedua" {
		t.Fatalf("rute publik memuat %q, harusnya yang aktif saja, urut", got)
	}

	kedua.Aktif = false
	if kode, _ := kirim(http.MethodPut, "/api/admin/banner/"+kedua.ID, kedua); kode != 200 {
		t.Fatalf("mematikan banner dibalas %d", kode)
	}
	if got := publik(); got != "Uji banner pertama" {
		t.Fatalf("banner yang dimatikan masih tampil: %q", got)
	}
	if kode, _ := kirim(http.MethodPut, "/api/admin/banner/bn-karangan", Banner{Judul: "Uji banner hantu"}); kode != 404 {
		t.Errorf("PUT ke id karangan dibalas %d, harusnya 404", kode)
	}

	hapus := func(id string) int {
		w := httptest.NewRecorder()
		adminBannerHandler(w, httptest.NewRequest(http.MethodDelete, "/api/admin/banner/"+id, nil))
		return w.Code
	}
	if a, b := hapus(pertama.ID), hapus(pertama.ID); a != 200 || b != 404 {
		t.Errorf("hapus dua kali dibalas %d lalu %d, harusnya 200 lalu 404", a, b)
	}
}
