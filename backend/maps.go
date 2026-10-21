package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ==================== PERANTARA LAYANAN PETA ====================
//
// Dua penyedia, dipilih per kebutuhan, bukan karena selera:
//
//   - Cari alamat dan detail tempat: Google Places kalau GOOGLE_MAPS_API_KEY
//     terpasang, Photon kalau belum. Uji 9 Okt 2026: Photon menemukan tempat
//     yang tepat untuk sekitar separuh kueri di Sintang (jalan utama, RSUD
//     dengan nama lengkap, bandara, terminal, polres, kampus), tapi gagal untuk
//     nama sehari-hari seperti "rsud sintang" atau alun-alun. Cukup supaya
//     kolom cari tidak mati; begitu kunci diisi, backend pindah ke Google
//     sendiri tanpa perlu ubah kode.
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
// Aplikasi menggambar petanya dengan Google Maps SDK (sejak 17 Okt 2026). Kunci
// SDK itu terpisah, ada di APK dan dibatasi ke package + SHA-1; menampilkan peta
// lewat SDK seluler tidak ditagih.
//
// ponytail: tanpa cache. Penggambaran rute sudah dibatasi di sisi aplikasi
// (lihat _jarakUntukGambarUlangRute), jadi satu perjalanan hanya beberapa
// panggilan. Pasang cache berkunci koordinat yang dibulatkan kalau tagihan
// rute mulai terasa.

const (
	urlAutocomplete = "https://places.googleapis.com/v1/places:autocomplete"
	urlPlaceDetails = "https://places.googleapis.com/v1/places/"
	urlPhotonRevers = "https://photon.komoot.io/reverse"
	urlPhotonCari   = "https://photon.komoot.io/api/"
	urlOSRMRoute    = "https://router.project-osrm.org/route/v1/driving/"

	// Saran Photon membawa koordinatnya sendiri di dalam place_id, jadi
	// /api/maps/place tidak perlu bertanya ke mana pun untuk menukarnya.
	awalanIDPhoton = "photon:"

	// Photon tidak bisa membatasi wilayah, hanya mencondongkan. Tanpa saringan
	// ini "Jalan M.T. Haryono" juga menawarkan yang di Pontianak dan Ketapang,
	// dan penumpang yang salah ketuk mendapat ongkos ratusan kilometer.
	radiusCariGratisKM = 100

	// Layanan gratis berbasis OpenStreetMap minta pemakainya memperkenalkan diri
	// supaya bisa dihubungi kalau ada yang menyalahgunakan. Jangan dikosongkan.
	userAgentPeta = "bohAntar/1.0 (https://bohantar.indotechconsulting.com/api/privasi)"
)

var mapsClient = &http.Client{Timeout: 12 * time.Second}

func mapsAPIKey() string { return getEnv("GOOGLE_MAPS_API_KEY", "") }

// ---------- JATAH HARIAN GOOGLE PLACES ----------
//
// Places API (New) hanya punya batas per menit, tanpa batas harian, dan budget
// di billing cuma mengirim email. Karena kuncinya dikunci ke IP VPS, setiap
// panggilan Places lewat sini — hitungan di bawah sama dengan yang ditagih
// Google, jadi batas hariannya dipasang sendiri: lewat batas, pencarian pindah
// ke Photon sampai tengah malam WIB. Angkanya tampil di dashboard super admin.
//
// ponytail: hitungan di memori, kembali nol saat backend direstart (deploy),
// jadi sehari paling banyak lolos dua kali batas. Pindahkan ke tabel kalau
// butuh riwayat atau angka yang tahan restart.

var zonaWIB = time.FixedZone("WIB", 7*60*60)

type pemakaianPlaces struct {
	Tanggal      string `json:"tanggal"`
	Autocomplete int    `json:"google_autocomplete"`
	Detail       int    `json:"google_detail"`
	GagalGoogle  int    `json:"google_gagal"`
	Photon       int    `json:"photon"`
}

var (
	muPlaces   sync.Mutex
	hariPlaces pemakaianPlaces
)

// batasHarianPlaces: panggilan Google (cari + detail) per hari. Bawaan 300 ≈
// 60–100 pencarian sehari, ±9.000 panggilan sebulan. Naikkan lewat
// PLACES_BATAS_HARIAN di run.sh kalau Photon terlalu sering mengambil alih;
// 0 berarti Google tidak pernah dipanggil.
func batasHarianPlaces() int {
	n, err := strconv.Atoi(getEnv("PLACES_BATAS_HARIAN", "300"))
	if err != nil || n < 0 {
		return 300
	}
	return n
}

// catatPlaces mengubah hitungan hari ini lalu mengembalikan salinannya, dan
// memulai dari nol begitu tanggal WIB berganti.
func catatPlaces(ubah func(*pemakaianPlaces)) pemakaianPlaces {
	muPlaces.Lock()
	defer muPlaces.Unlock()
	if hari := time.Now().In(zonaWIB).Format("2006-01-02"); hariPlaces.Tanggal != hari {
		hariPlaces = pemakaianPlaces{Tanggal: hari}
	}
	if ubah != nil {
		ubah(&hariPlaces)
	}
	return hariPlaces
}

// pesanJatahGoogle memesan satu pencarian ke Google kalau jatah hari ini
// masih ada. Detail tempat tidak ikut dijaga: menolaknya merusak saran Google
// yang sudah terlanjur diketuk penumpang.
func pesanJatahGoogle() bool {
	boleh := false
	catatPlaces(func(p *pemakaianPlaces) {
		if p.Autocomplete+p.Detail < batasHarianPlaces() {
			p.Autocomplete++
			boleh = true
		}
	})
	return boleh
}

// adminPemakaianPetaHandler: GET /api/admin/peta/pemakaian
func adminPemakaianPetaHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{
		"status":       "success",
		"pemakaian":    catatPlaces(nil),
		"batas_harian": batasHarianPlaces(),
		"kunci_google": mapsAPIKey() != "",
	})
}

// mapsSiap menolak permintaan lebih awal kalau kunci belum dipasang, supaya
// pesannya jelas ketimbang balasan aneh dari Google. Sekarang hanya tersisa
// untuk detail tempat dengan place_id Google, yang memang mustahil dijawab
// tanpa kunci.
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
	q := r.URL.Query().Get("q")
	if len(q) < 3 {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "suggestions": []interface{}{}})
		return
	}
	if mapsAPIKey() == "" || !pesanJatahGoogle() {
		cariTempatGratis(w, r, q)
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
		// Kuota per menit habis, billing bermasalah, atau Google gangguan:
		// penumpang tetap bisa mencari lewat Photon, hanya hasilnya kurang lengkap.
		log.Printf("Places autocomplete gagal, pindah ke Photon: %v", err)
		catatPlaces(func(p *pemakaianPlaces) { p.GagalGoogle++ })
		cariTempatGratis(w, r, q)
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

// cariTempatGratis adalah pencarian lewat Photon, dipakai selama kunci Google
// belum ada. Bentuk balasannya sama persis dengan jalur Google, jadi aplikasi
// tidak tahu — dan tidak perlu tahu — penyedia mana yang menjawab.
func cariTempatGratis(w http.ResponseWriter, r *http.Request, q string) {
	catatPlaces(func(p *pemakaianPlaces) { p.Photon++ })
	v := url.Values{"q": {q}, "limit": {"15"}}
	lat, lng, adaLokasi := bacaKoordinat(r, "lat", "lng")
	if adaLokasi {
		v.Set("lat", strconv.FormatFloat(lat, 'f', 6, 64))
		v.Set("lon", strconv.FormatFloat(lng, 'f', 6, 64))
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, urlPhotonCari+"?"+v.Encode(), nil)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan permintaan"})
		return
	}
	hasil, err := kirimPermintaan(req)
	if err != nil {
		writeJSONResponse(w, 502, map[string]string{"error": "Pencarian alamat sedang bermasalah. Geser peta ke titik tujuan."})
		return
	}
	var dekat *[2]float64
	if adaLokasi {
		dekat = &[2]float64{lat, lng}
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "suggestions": saranPhoton(hasil, dekat)})
}

// saranPhoton mengubah balasan Photon jadi daftar saran: yang terlalu jauh dari
// penumpang dibuang, dan potongan jalan yang namanya serta kelurahannya sama
// persis cuma ditampilkan sekali. Paling banyak enam, sama panjangnya dengan
// daftar Google.
func saranPhoton(hasil map[string]interface{}, dekat *[2]float64) []map[string]string {
	saran := []map[string]string{}
	sudah := map[string]bool{}
	daftar, _ := hasil["features"].([]interface{})
	for _, item := range daftar {
		f, _ := item.(map[string]interface{})
		geo, _ := f["geometry"].(map[string]interface{})
		koord, _ := geo["coordinates"].([]interface{})
		if len(koord) != 2 {
			continue
		}
		// GeoJSON menulis bujur dulu, baru lintang.
		lng, _ := koord[0].(float64)
		lat, _ := koord[1].(float64)
		if !koordinatValid(lat, lng) {
			continue
		}
		if dekat != nil && jarakKM(dekat[0], dekat[1], lat, lng) > radiusCariGratisKM {
			continue
		}
		p, _ := f["properties"].(map[string]interface{})
		nama, alamat := namaDanAlamatPhoton(p)
		if nama == "" || sudah[nama+"|"+alamat] {
			continue
		}
		sudah[nama+"|"+alamat] = true
		saran = append(saran, map[string]string{
			"place_id": fmt.Sprintf("%s%.6f,%.6f", awalanIDPhoton, lat, lng),
			"name":     nama,
			"address":  alamat,
		})
		if len(saran) == 6 {
			break
		}
	}
	return saran
}

// namaDanAlamatPhoton memisahkan judul saran dari baris keterangannya. Provinsi
// dan kabupaten sengaja tidak ikut: di Sintang hasilnya cuma "Sintang, Sintang,
// Kalimantan Barat" di setiap baris, tanpa membedakan apa pun.
func namaDanAlamatPhoton(p map[string]interface{}) (nama, alamat string) {
	ambil := func(k string) string { s, _ := p[k].(string); return strings.TrimSpace(s) }
	jalan := strings.TrimSpace(ambil("street") + " " + ambil("housenumber"))
	nama = ambil("name")
	if nama == "" {
		nama = jalan
	}
	kota := ambil("city")
	if kota == "" {
		kota = ambil("county")
	}
	bagian := []string{}
	for _, s := range []string{jalan, ambil("district"), kota} {
		if s != "" && s != nama && !slices.Contains(bagian, s) {
			bagian = append(bagian, s)
		}
	}
	return nama, strings.Join(bagian, ", ")
}

// koordinatDariIDPhoton membongkar place_id buatan saranPhoton. Isinya datang
// dari aplikasi, tapi koordinat karangan tidak membuka apa pun: penumpang
// memang boleh mengetuk titik mana saja di peta.
func koordinatDariIDPhoton(id string) (float64, float64, bool) {
	isi, ok := strings.CutPrefix(id, awalanIDPhoton)
	if !ok {
		return 0, 0, false
	}
	a, b, ok := strings.Cut(isi, ",")
	lat, e1 := strconv.ParseFloat(a, 64)
	lng, e2 := strconv.ParseFloat(b, 64)
	if !ok || e1 != nil || e2 != nil || !koordinatValid(lat, lng) {
		return 0, 0, false
	}
	return lat, lng, true
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
	id := r.URL.Query().Get("place_id")
	if id == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "place_id diperlukan"})
		return
	}
	// Saran Photon sudah membawa koordinatnya: tidak ada yang perlu ditanyakan
	// lagi. Nama dikosongkan supaya aplikasi memakai nama dari saran yang
	// diketuk penumpang.
	if lat, lng, ok := koordinatDariIDPhoton(id); ok {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "lat": lat, "lng": lng, "name": "", "address": ""})
		return
	}
	if !mapsSiap(w) {
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

	catatPlaces(func(p *pemakaianPlaces) { p.Detail++ })
	hasil, err := kirimPermintaan(req)
	if err != nil {
		catatPlaces(func(p *pemakaianPlaces) { p.GagalGoogle++ })
		log.Printf("layanan peta gagal: %v", err)
		writeJSONResponse(w, 502, map[string]string{"error": "Layanan peta sedang gangguan. Coba lagi sebentar."})
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
		log.Printf("layanan peta gagal: %v", err)
		writeJSONResponse(w, 502, map[string]string{"error": "Layanan peta sedang gangguan. Coba lagi sebentar."})
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
		log.Printf("layanan peta gagal: %v", err)
		writeJSONResponse(w, 502, map[string]string{"error": "Layanan peta sedang gangguan. Coba lagi sebentar."})
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
