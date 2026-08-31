package main

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

// Dua hal yang paling gampang salah setelah pindah dari Google ke OSRM/Photon,
// dan dua-duanya diam-diam: urutan koordinat OSRM (bujur dulu, bukan lintang)
// dan nama medan yang berbeda. Jarak yang salah langsung jadi tarif yang salah,
// jadi ini diuji ke servernya sungguhan, bukan ke tiruan.

func TestRuteOSRMMasukAkal(t *testing.T) {
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET",
		"/api/maps/route?from_lat=-0.0784&from_lng=111.4933&to_lat=-0.0600&to_lng=111.5100", nil)
	mapsRouteHandler(w, r)

	if w.Code == 502 {
		t.Skip("OSRM tidak bisa dihubungi, lewati")
	}
	if w.Code != 200 {
		t.Fatalf("kode %d: %s", w.Code, w.Body.String())
	}

	var balasan struct {
		Polyline string  `json:"polyline"`
		Jarak    float64 `json:"distance_m"`
		Durasi   string  `json:"duration"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &balasan); err != nil {
		t.Fatalf("balasan tidak terbaca: %s", w.Body.String())
	}
	if balasan.Polyline == "" {
		t.Fatal("polyline kosong, peta tidak akan menggambar rute")
	}
	if !strings.HasSuffix(balasan.Durasi, "s") {
		t.Errorf("durasi %q bukan bentuk \"930s\" yang ditunggu aplikasi", balasan.Durasi)
	}
	// Dua titik di dalam kota Sintang, sekitar 5 km lewat jalan. Kalau lintang
	// dan bujurnya tertukar, angkanya jadi liar atau permintaannya gagal sama
	// sekali — dan jarak yang salah langsung jadi tarif yang salah.
	if balasan.Jarak < 3000 || balasan.Jarak > 9000 {
		t.Fatalf("jarak %v m tidak masuk akal untuk dua titik di Sintang", balasan.Jarak)
	}
}

func TestRangkaiAlamat(t *testing.T) {
	kasus := []struct {
		nama  string
		props map[string]interface{}
		mau   string
	}{
		{"lengkap", map[string]interface{}{
			"name": "Masjid Agung", "street": "Jalan Merdeka", "housenumber": "12", "city": "Sintang",
		}, "Masjid Agung, Jalan Merdeka 12, Sintang"},
		{"potongan berulang dibuang", map[string]interface{}{
			"name": "Sintang", "city": "Sintang", "state": "Kalimantan Barat",
		}, "Sintang, Kalimantan Barat"},
		{"kosong", map[string]interface{}{}, ""},
		{"nil", nil, ""},
	}
	for _, k := range kasus {
		if got := rangkaiAlamat(k.props); got != k.mau {
			t.Errorf("%s: dapat %q, mau %q", k.nama, got, k.mau)
		}
	}
}
