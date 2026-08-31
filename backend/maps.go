package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

// ==================== PERANTARA LAYANAN PETA ====================
//
// Dua penyedia, dipilih per kebutuhan, bukan karena selera:
//
//   - Cari alamat dan detail tempat: Google Places. OpenStreetMap tidak punya
//     datanya di Sintang — Overpass cuma menemukan empat tempat bernama di
//     seluruh kota, jadi penyedia gratis mana pun membalas nol. Kedua endpoint
//     ini membalas 503 selama GOOGLE_MAPS_API_KEY belum dipasang, dan hidup
//     sendiri begitu diisi tanpa perlu ubah kode.
//   - Rute dan geocoding balik: OSRM dan Photon. Gratis, tanpa kunci, tanpa
//     billing, dan sudah diuji benar di Sintang. Tidak ada alasan membayar
//     Google untuk dua ini.
//
// Aplikasi tidak memanggil siapa pun langsung. Semua lewat sini karena:
//
//  1. Kunci API yang ditaruh di dalam APK bisa diambil siapa saja dengan `unzip`,
//     lalu kuota berbayar Anda dihabiskan orang lain. Kunci di sini dikunci ke
//     IP VPS dan tidak pernah ikut terkirim ke perangkat.
//  2. Seluruh rute ini wajib bertoken, jadi hanya pengguna terdaftar yang bisa
//     membelanjakan kuota.
//  3. Bentuk balasannya dinormalkan di sini. Kalau suatu hari pindah penyedia,
//     yang berubah cuma berkas ini — aplikasi tidak perlu tahu.
//
// Aplikasi menggambar petanya dengan ubin OpenStreetMap lewat flutter_map, jadi
// tidak ada lagi kunci Maps SDK di dalam APK.
//
// ponytail: tanpa cache. Penggambaran rute sudah dibatasi di sisi aplikasi
// (lihat _jarakUntukGambarUlangRute), jadi satu perjalanan hanya beberapa
// panggilan. Pasang cache berkunci koordinat yang dibulatkan kalau tagihan
// rute mulai terasa.

const (
	urlAutocomplete = "https://places.googleapis.com/v1/places:autocomplete"
	urlPlaceDetails = "https://places.googleapis.com/v1/places/"
	urlPhotonRevers = "https://photon.komoot.io/reverse"
	urlOSRMRoute    = "https://router.project-osrm.org/route/v1/driving/"

	// Layanan gratis berbasis OpenStreetMap minta pemakainya memperkenalkan diri
	// supaya bisa dihubungi kalau ada yang menyalahgunakan. Jangan dikosongkan.
	userAgentPeta = "bohAntar/1.0 (https://bohantar.com)"
)

var mapsClient = &http.Client{Timeout: 12 * time.Second}

func mapsAPIKey() string { return getEnv("GOOGLE_MAPS_API_KEY", "") }

// mapsSiap menolak permintaan lebih awal kalau kunci belum dipasang, supaya
// pesannya jelas ketimbang balasan aneh dari Google. Hanya dipakai dua endpoint
// Places; rute dan geocoding balik tidak butuh kunci apa pun.
func mapsSiap(w http.ResponseWriter) bool {
	if mapsAPIKey() == "" {
		writeJSONResponse(w, 503, map[string]string{"error": "Pencarian alamat belum aktif. Tekan langsung titik tujuan di peta."})
		return false
	}
	return true
}

// bacaKoordinat mengambil sepasang lat/lng dari query string.
func bacaKoordinat(r *http.Request, latKey, lngKey string) (float64, float64, bool) {
	lat, err1 := strconv.ParseFloat(r.URL.Query().Get(latKey), 64)
	lng, err2 := strconv.ParseFloat(r.URL.Query().Get(lngKey), 64)
	if err1 != nil || err2 != nil || !koordinatValid(lat, lng) {
		return 0, 0, false
	}
	return lat, lng, true
}

// kirimPermintaan menjalankan permintaan dan mengurai balasannya jadi map.
func kirimPermintaan(req *http.Request) (map[string]interface{}, error) {
	req.Header.Set("User-Agent", userAgentPeta)
	resp, err := mapsClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gagal menghubungi layanan peta: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, err
	}
	var hasil map[string]interface{}
	if err := json.Unmarshal(body, &hasil); err != nil {
		return nil, fmt.Errorf("balasan layanan peta tidak dikenali")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("layanan peta menolak permintaan (kode %d)", resp.StatusCode)
	}
	return hasil, nil
}

// ---------- CARI ALAMAT ----------

// mapsAutocompleteHandler: GET /api/maps/autocomplete?q=&lat=&lng=&session=
//
// session adalah token sesi Places. Satu token dipakai untuk seluruh ketikan
// sampai penumpang memilih satu tempat; tanpa itu setiap huruf ditagih sebagai
// permintaan terpisah.
func mapsAutocompleteHandler(w http.ResponseWriter, r *http.Request) {
	if !mapsSiap(w) {
		return
	}
	q := r.URL.Query().Get("q")
	if len(q) < 3 {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "suggestions": []interface{}{}})
		return
	}

	badan := map[string]interface{}{
		"input":        q,
		"languageCode": "id",
		"regionCode":   "ID",
	}
	if s := r.URL.Query().Get("session"); s != "" {
		badan["sessionToken"] = s
	}
	// Hasil dicondongkan ke sekitar penumpang, bukan dibatasi keras: tujuan di
	// luar radius tetap boleh muncul, hanya kalah urutan.
	if lat, lng, ok := bacaKoordinat(r, "lat", "lng"); ok {
		badan["locationBias"] = map[string]interface{}{
			"circle": map[string]interface{}{
				"center": map[string]float64{"latitude": lat, "longitude": lng},
				"radius": 50000.0,
			},
		}
	}

	buf, _ := json.Marshal(badan)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, urlAutocomplete, bytes.NewReader(buf))
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Goog-Api-Key", mapsAPIKey())
	req.Header.Set("X-Goog-FieldMask", "suggestions.placePrediction.placeId,suggestions.placePrediction.text,suggestions.placePrediction.structuredFormat")

	hasil, err := kirimPermintaan(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": err.Error()})
		return
	}

	saran := []map[string]string{}
	if daftar, ok := hasil["suggestions"].([]interface{}); ok {
		for _, item := range daftar {
			m, _ := item.(map[string]interface{})
			p, _ := m["placePrediction"].(map[string]interface{})
			if p == nil {
				continue
			}
			id, _ := p["placeId"].(string)
			penuh := teksDari(p["text"])
			nama, alamat := penuh, penuh
			if sf, ok := p["structuredFormat"].(map[string]interface{}); ok {
				if t := teksDari(sf["mainText"]); t != "" {
					nama = t
				}
				if t := teksDari(sf["secondaryText"]); t != "" {
					alamat = t
				}
			}
			if id != "" {
				saran = append(saran, map[string]string{"place_id": id, "name": nama, "address": alamat})
			}
		}
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "suggestions": saran})
}

// teksDari membaca bentuk {"text": "..."} yang dipakai Places API.
func teksDari(v interface{}) string {
	m, ok := v.(map[string]interface{})
	if !ok {
		return ""
	}
	s, _ := m["text"].(string)
	return s
}

// ---------- DETAIL TEMPAT ----------

// mapsPlaceHandler: GET /api/maps/place?place_id=&session=
// Menukar place_id hasil autocomplete jadi koordinat.
func mapsPlaceHandler(w http.ResponseWriter, r *http.Request) {
	if !mapsSiap(w) {
		return
	}
	id := r.URL.Query().Get("place_id")
	if id == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "place_id diperlukan"})
		return
	}

	endpoint := urlPlaceDetails + url.PathEscape(id) + "?languageCode=id"
	if s := r.URL.Query().Get("session"); s != "" {
		endpoint += "&sessionToken=" + url.QueryEscape(s)
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}
	req.Header.Set("X-Goog-Api-Key", mapsAPIKey())
	req.Header.Set("X-Goog-FieldMask", "location,displayName,formattedAddress")

	hasil, err := kirimPermintaan(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": err.Error()})
		return
	}

	lokasi, _ := hasil["location"].(map[string]interface{})
	lat, _ := lokasi["latitude"].(float64)
	lng, _ := lokasi["longitude"].(float64)
	if !koordinatValid(lat, lng) {
		writeJSONResponse(w, 502, map[string]string{"error": "Tempat ini tidak punya koordinat"})
		return
	}
	alamat, _ := hasil["formattedAddress"].(string)
	writeJSONResponse(w, 200, map[string]interface{}{
		"status":  "success",
		"lat":     lat,
		"lng":     lng,
		"name":    teksDari(hasil["displayName"]),
		"address": alamat,
	})
}

// ---------- GEOCODING BALIK ----------

// mapsReverseHandler: GET /api/maps/reverse?lat=&lng=
// Dipakai saat penumpang memindahkan pin di peta.
//
// Photon, bukan Geocoding API: gratis dan tanpa kunci. Di Sintang balasannya
// paling banter nama jalan — tapi Google pun tidak jauh berbeda di sana, dan
// yang benar-benar dipakai penumpang adalah titiknya, bukan tulisannya.
func mapsReverseHandler(w http.ResponseWriter, r *http.Request) {
	lat, lng, ok := bacaKoordinat(r, "lat", "lng")
	if !ok {
		writeJSONResponse(w, 400, map[string]string{"error": "Koordinat tidak valid"})
		return
	}

	endpoint := fmt.Sprintf("%s?lat=%f&lon=%f&limit=1", urlPhotonRevers, lat, lng)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}
	hasil, err := kirimPermintaan(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": err.Error()})
		return
	}

	alamat := ""
	if daftar, ok := hasil["features"].([]interface{}); ok && len(daftar) > 0 {
		if m, ok := daftar[0].(map[string]interface{}); ok {
			p, _ := m["properties"].(map[string]interface{})
			alamat = rangkaiAlamat(p)
		}
	}
	if alamat == "" {
		// Titik di tengah kebun memang bisa tidak punya alamat. Koordinatnya
		// tetap sah, jadi ini bukan kegagalan — cukup diberi label jujur.
		alamat = fmt.Sprintf("%.5f, %.5f", lat, lng)
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "address": alamat, "name": alamat})
}

// rangkaiAlamat menyusun satu baris alamat dari properti Photon, yang memberi
// potongan terpisah (nama, jalan, kelurahan, kota) alih-alih satu kalimat jadi
// seperti Google. Potongan kosong dan yang berulang dibuang — di kota kecil
// nama tempat dan nama kelurahannya kerap sama persis.
func rangkaiAlamat(p map[string]interface{}) string {
	ambil := func(k string) string { s, _ := p[k].(string); return s }
	jalan := strings.TrimSpace(ambil("street") + " " + ambil("housenumber"))

	bagian := []string{}
	for _, s := range []string{ambil("name"), jalan, ambil("district"), ambil("city"), ambil("county"), ambil("state")} {
		if s != "" && !slices.Contains(bagian, s) {
			bagian = append(bagian, s)
		}
	}
	return strings.Join(bagian, ", ")
}

// ---------- RUTE ----------

// mapsRouteHandler: GET /api/maps/route?from_lat=&from_lng=&to_lat=&to_lng=
//
// OSRM, bukan Routes API: gratis, tanpa kunci, dan kebetulan bentuk balasannya
// sudah cocok — polyline terkode presisi 5, persis yang dibongkar decodePolyline
// di aplikasi. Yang berubah cuma nama medannya.
//
// Polyline diteruskan terkode apa adanya, bukan sebagai daftar titik: ukurannya
// sekitar sepersepuluh JSON-nya, dan penumpang di Sintang membayar kuota data
// untuk setiap byte-nya.
//
// ponytail: server demo OSRM, batasnya "pemakaian wajar" dan profilnya cuma
// mobil — tidak ada roda dua seperti TWO_WHEELER di Google, jadi gang sempit
// yang sebenarnya bisa dilewati motor kadang diputar. Cukup untuk Sintang;
// kalau mulai ditolak atau jalurnya terasa salah, pasang OSRM sendiri di VPS —
// yang berubah hanya urlOSRMRoute.
func mapsRouteHandler(w http.ResponseWriter, r *http.Request) {
	fLat, fLng, ok1 := bacaKoordinat(r, "from_lat", "from_lng")
	tLat, tLng, ok2 := bacaKoordinat(r, "to_lat", "to_lng")
	if !ok1 || !ok2 {
		writeJSONResponse(w, 400, map[string]string{"error": "Koordinat asal atau tujuan tidak valid"})
		return
	}

	// OSRM menulis koordinat terbalik dari kebiasaan: bujur dulu, baru lintang.
	endpoint := fmt.Sprintf("%s%f,%f;%f,%f?overview=simplified&geometries=polyline",
		urlOSRMRoute, fLng, fLat, tLng, tLat)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}

	hasil, err := kirimPermintaan(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": err.Error()})
		return
	}

	// OSRM membalas 200 sambil bilang "NoRoute" di badan, jadi kode di dalamnya
	// yang menentukan, bukan status HTTP-nya.
	rute, _ := hasil["routes"].([]interface{})
	if kode, _ := hasil["code"].(string); kode != "Ok" || len(rute) == 0 {
		writeJSONResponse(w, 404, map[string]string{"error": "Tidak ada rute yang bisa dilalui"})
		return
	}
	m, _ := rute[0].(map[string]interface{})
	encoded, _ := m["geometry"].(string)
	jarak, _ := m["distance"].(float64)
	detik, _ := m["duration"].(float64)

	writeJSONResponse(w, 200, map[string]interface{}{
		"status":     "success",
		"polyline":   encoded,
		"distance_m": jarak,
		"duration":   fmt.Sprintf("%.0fs", detik), // bentuk "930s", sama seperti sebelumnya
	})
}
