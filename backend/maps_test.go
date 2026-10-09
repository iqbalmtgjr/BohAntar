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

// Balasan Photon yang direkam 9 Okt 2026 untuk "jalan mt haryono", ditambah dua
// baris buatan: potongan ganda dan titik tanpa koordinat sah.
const balasanPhotonMTHaryono = `{"features":[
 {"geometry":{"coordinates":[111.4791785,0.0690128]},"properties":{"name":"Jalan M.T. Haryono","district":"Kapuas Kanan Hulu","city":"Sintang","county":"Sintang","state":"Kalimantan Barat"}},
 {"geometry":{"coordinates":[111.4795,0.0695]},"properties":{"name":"Jalan M.T. Haryono","district":"Kapuas Kanan Hulu","city":"Sintang","county":"Sintang","state":"Kalimantan Barat"}},
 {"geometry":{"coordinates":[111.482361,0.0803018]},"properties":{"name":"Jalan M.T. Haryono","district":"Kapuas Kanan Hilir","city":"Sintang","county":"Sintang","state":"Kalimantan Barat"}},
 {"geometry":{"coordinates":[109.3360844,-0.0450345]},"properties":{"name":"Jalan M.T. Haryono","district":"Akcaya","city":"Pontianak","state":"Kalimantan Barat"}},
 {"geometry":{"coordinates":[0,0]},"properties":{"name":"Titik Nol"}},
 {"geometry":{"coordinates":[111.49,0.07]},"properties":{"street":"Jalan Lintas Melawi","housenumber":"12","county":"Sintang"}}
]}`

// Saran gratis harus membuang yang di kota lain dan potongan jalan yang sama,
// dan place_id-nya harus bisa ditukar balik jadi koordinat yang persis sama
// tanpa bertanya ke penyedia mana pun.
func TestSaranPhoton(t *testing.T) {
	var hasil map[string]interface{}
	if err := json.Unmarshal([]byte(balasanPhotonMTHaryono), &hasil); err != nil {
		t.Fatal(err)
	}
	sintang := [2]float64{0.068, 111.495}
	saran := saranPhoton(hasil, &sintang)

	if len(saran) != 3 {
		t.Fatalf("dapat %d saran, harusnya 3 (dua kelurahan + satu jalan tanpa nama): %v", len(saran), saran)
	}
	if saran[0]["name"] != "Jalan M.T. Haryono" || saran[0]["address"] != "Kapuas Kanan Hulu, Sintang" {
		t.Errorf("saran pertama %v", saran[0])
	}
	if saran[1]["address"] != "Kapuas Kanan Hilir, Sintang" {
		t.Errorf("potongan di kelurahan lain harus tetap ada, dapat %v", saran[1])
	}
	// Tanpa nama, judulnya jalan + nomor; kota jatuh ke kabupaten.
	if saran[2]["name"] != "Jalan Lintas Melawi 12" || saran[2]["address"] != "Sintang" {
		t.Errorf("saran tanpa nama %v", saran[2])
	}
	for _, s := range saran {
		if strings.Contains(s["address"], "Pontianak") {
			t.Errorf("hasil 240 km jauhnya ikut ditawarkan: %v", s)
		}
	}

	lat, lng, ok := koordinatDariIDPhoton(saran[0]["place_id"])
	if !ok || lat != 0.069013 || lng != 111.479179 {
		t.Errorf("place_id %q dibongkar jadi %v,%v (ok=%v)", saran[0]["place_id"], lat, lng, ok)
	}
	for _, id := range []string{"ChIJ-google-asli", "photon:abc,def", "photon:0,0", "photon:1"} {
		if _, _, ok := koordinatDariIDPhoton(id); ok {
			t.Errorf("%q tidak boleh dianggap koordinat sah", id)
		}
	}

	// Tanpa lokasi penumpang tidak ada yang disaring jaraknya.
	if semua := saranPhoton(hasil, nil); len(semua) != 4 {
		t.Errorf("tanpa lokasi dapat %d saran, harusnya 4", len(semua))
	}
}
