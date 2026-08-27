package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// ==================== PERANTARA GOOGLE MAPS ====================
//
// Aplikasi tidak memanggil Google langsung. Semua permintaan berbayar — cari
// alamat, detail tempat, geocoding balik, dan rute — lewat sini karena:
//
//  1. Kunci API yang ditaruh di dalam APK bisa diambil siapa saja dengan `unzip`,
//     lalu kuota berbayar Anda dihabiskan orang lain. Kunci di sini dikunci ke
//     IP VPS dan tidak pernah ikut terkirim ke perangkat.
//  2. Seluruh rute ini wajib bertoken, jadi hanya pengguna terdaftar yang bisa
//     membelanjakan kuota.
//  3. Bentuk balasannya dinormalkan di sini. Kalau suatu hari pindah penyedia,
//     yang berubah cuma berkas ini — aplikasi tidak perlu tahu.
//
// Kunci Maps SDK di aplikasi berbeda dan memang harus ada di sana untuk
// menggambar peta; kunci itu dibatasi ke nama paket + SHA-1, bukan ke IP.
//
// ponytail: tanpa cache. Penggambaran rute sudah dibatasi di sisi aplikasi
// (lihat _jarakUntukGambarUlangRute), jadi satu perjalanan hanya beberapa
// panggilan. Pasang cache berkunci koordinat yang dibulatkan kalau tagihan
// rute mulai terasa.

const (
	urlAutocomplete  = "https://places.googleapis.com/v1/places:autocomplete"
	urlPlaceDetails  = "https://places.googleapis.com/v1/places/"
	urlGeocode       = "https://maps.googleapis.com/maps/api/geocode/json"
	urlComputeRoutes = "https://routes.googleapis.com/directions/v2:computeRoutes"
)

var mapsClient = &http.Client{Timeout: 12 * time.Second}

func mapsAPIKey() string { return getEnv("GOOGLE_MAPS_API_KEY", "") }

// mapsSiap menolak permintaan lebih awal kalau kunci belum dipasang, supaya
// pesannya jelas ketimbang balasan aneh dari Google.
func mapsSiap(w http.ResponseWriter) bool {
	if mapsAPIKey() == "" {
		writeJSONResponse(w, 503, map[string]string{"error": "Layanan peta belum dikonfigurasi di server"})
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

// kirimKeGoogle menjalankan permintaan dan mengurai balasannya jadi map.
func kirimKeGoogle(req *http.Request) (map[string]interface{}, error) {
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

	hasil, err := kirimKeGoogle(req)
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

	hasil, err := kirimKeGoogle(req)
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
// Dipakai saat penumpang menggeser pin di peta.
func mapsReverseHandler(w http.ResponseWriter, r *http.Request) {
	if !mapsSiap(w) {
		return
	}
	lat, lng, ok := bacaKoordinat(r, "lat", "lng")
	if !ok {
		writeJSONResponse(w, 400, map[string]string{"error": "Koordinat tidak valid"})
		return
	}

	endpoint := fmt.Sprintf("%s?latlng=%f,%f&language=id&key=%s", urlGeocode, lat, lng, url.QueryEscape(mapsAPIKey()))
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, endpoint, nil)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}
	hasil, err := kirimKeGoogle(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": err.Error()})
		return
	}

	alamat := ""
	if daftar, ok := hasil["results"].([]interface{}); ok && len(daftar) > 0 {
		if m, ok := daftar[0].(map[string]interface{}); ok {
			alamat, _ = m["formatted_address"].(string)
		}
	}
	if alamat == "" {
		// Titik di tengah kebun memang bisa tidak punya alamat. Koordinatnya
		// tetap sah, jadi ini bukan kegagalan — cukup diberi label jujur.
		alamat = fmt.Sprintf("%.5f, %.5f", lat, lng)
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "address": alamat, "name": alamat})
}

// ---------- RUTE ----------

// mapsRouteHandler: GET /api/maps/route?from_lat=&from_lng=&to_lat=&to_lng=
//
// Mengembalikan polyline terkode apa adanya, bukan daftar titik: bentuk
// terkodenya sekitar sepersepuluh ukuran JSON-nya, dan penumpang di Sintang
// membayar kuota data untuk setiap byte-nya.
func mapsRouteHandler(w http.ResponseWriter, r *http.Request) {
	if !mapsSiap(w) {
		return
	}
	fLat, fLng, ok1 := bacaKoordinat(r, "from_lat", "from_lng")
	tLat, tLng, ok2 := bacaKoordinat(r, "to_lat", "to_lng")
	if !ok1 || !ok2 {
		writeJSONResponse(w, 400, map[string]string{"error": "Koordinat asal atau tujuan tidak valid"})
		return
	}

	titik := func(lat, lng float64) map[string]interface{} {
		return map[string]interface{}{
			"location": map[string]interface{}{
				"latLng": map[string]float64{"latitude": lat, "longitude": lng},
			},
		}
	}
	badan := map[string]interface{}{
		"origin":      titik(fLat, fLng),
		"destination": titik(tLat, tLng),
		// TWO_WHEELER memakai jalan yang memang bisa dilalui motor — jalur ojek
		// di Sintang sering bukan jalan mobil.
		"travelMode":        "TWO_WHEELER",
		"routingPreference": "TRAFFIC_UNAWARE",
		"languageCode":      "id",
		"regionCode":        "ID",
		"polylineQuality":   "OVERVIEW",
	}

	buf, _ := json.Marshal(badan)
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, urlComputeRoutes, bytes.NewReader(buf))
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Goog-Api-Key", mapsAPIKey())
	req.Header.Set("X-Goog-FieldMask", "routes.polyline.encodedPolyline,routes.distanceMeters,routes.duration")

	hasil, err := kirimKeGoogle(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": err.Error()})
		return
	}

	rute, _ := hasil["routes"].([]interface{})
	if len(rute) == 0 {
		writeJSONResponse(w, 404, map[string]string{"error": "Tidak ada rute yang bisa dilalui"})
		return
	}
	m, _ := rute[0].(map[string]interface{})
	poly, _ := m["polyline"].(map[string]interface{})
	encoded, _ := poly["encodedPolyline"].(string)
	jarak, _ := m["distanceMeters"].(float64)
	durasi, _ := m["duration"].(string) // contoh: "930s"

	writeJSONResponse(w, 200, map[string]interface{}{
		"status":     "success",
		"polyline":   encoded,
		"distance_m": jarak,
		"duration":   durasi,
	})
}
