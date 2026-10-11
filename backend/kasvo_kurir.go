package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ==================== KURIR UNTUK PELANGGAN TOKO KASVO (FASE 4) ====================
//
// Pelanggan memesan langsung ke toko Kasvo (web pesan online, mis. diarahkan
// dari DM Instagram/WhatsApp) dan memilih "Antar ke rumah". Begitu kasir
// memverifikasi pembayarannya — makanan masuk dapur — Kasvo meminta kurir di
// sini. Bukan saat tombol Pesan: kurir yang datang untuk pesanan yang belum
// dibayar atau akhirnya ditolak sudah menempuh perjalanan sia-sia.
//
// Pesanannya BohFood atas nama akun toko: jemput di toko, antar ke titik
// pelanggan, tarif BohFood (sama dengan pesan lewat aplikasi). food_total 0:
// makanan sudah lunas ke toko, kurir cuma menagih ongkir + biaya jasa TUNAI ke
// penerima (keputusan user 11 Okt, pilihan A). Komisi dan biaya jasa dipotong
// dari saldo driver seperti pesanan tunai lain.
//
// Ditandai kasvo_pengantaran_id. Mesin fase 3 (sinkronKasvo) melewatinya:
// pesanan ini sudah ada di kasir sejak awal, dan kurir yang kedaluwarsa tidak
// boleh ikut membatalkan makanan yang sudah dibayar.

// jarakAntarMaksKM: batas antar dari toko (keputusan user 11 Okt).
const jarakAntarMaksKM = 10.0

// warungKasvo mencari warung bohFood milik toko Kasvo ini.
func warungKasvo(uuid string) (FoodMerchant, bool) {
	var id string
	if uuid == "" || db.QueryRow("SELECT id FROM food_merchants WHERE kasvo_toko_uuid = ?", uuid).Scan(&id) != nil {
		return FoodMerchant{}, false
	}
	return dbGetFoodMerchant(id)
}

// jumlahDriverSiaga: driver aktif yang posisinya segar — kriteria yang sama
// dengan siaran pesanan baru (notifikasiDriverSiaga).
func jumlahDriverSiaga() int {
	var n int
	_ = db.QueryRow("SELECT COUNT(*) FROM users WHERE role = 'driver' AND is_driver_active = 1 AND driver_loc_at > ?",
		time.Now().Add(-10*time.Minute)).Scan(&n)
	return n
}

// kasvoOngkirHandler: GET /api/integrasi/kasvo/ongkir?uuid=&lat=&lng=
//
// Dibaca checkout web Kasvo. Tanpa lat/lng cukup menjawab apakah pilihan
// "Antar ke rumah" pantas ditawarkan (toko tergabung, ada kurir siaga); dengan
// lat/lng ikut ongkir dan jaraknya. Rumus ongkirnya sama persis dengan yang
// dipakai kasvoKurirHandler, jadi angka di checkout = angka yang ditagih kurir.
func kasvoOngkirHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	if !tokenKasvoSah(r) {
		writeJSONResponse(w, 401, map[string]string{"error": "Token integrasi tidak sah"})
		return
	}
	q := r.URL.Query()
	m, ok := warungKasvo(q.Get("uuid"))
	if !ok || !koordinatValid(m.Lat, m.Lng) {
		writeJSONResponse(w, 200, map[string]interface{}{"bisa": false, "alasan": "Toko belum tergabung di bohFood."})
		return
	}
	siaga := jumlahDriverSiaga()
	hasil := map[string]interface{}{"bisa": siaga > 0, "driver_siaga": siaga, "jarak_maks_km": jarakAntarMaksKM}
	if siaga == 0 {
		hasil["alasan"] = "Kurir sedang tidak tersedia. Coba lagi nanti, atau pilih ambil di tempat."
	}
	lat, _ := strconv.ParseFloat(q.Get("lat"), 64)
	lng, _ := strconv.ParseFloat(q.Get("lng"), 64)
	if koordinatValid(lat, lng) {
		t := ambilTarif("BohFood")
		km := jarakKM(m.Lat, m.Lng, lat, lng)
		hasil["jarak_km"] = math.Round(km*10) / 10
		hasil["ongkir"] = hitungTarif(t, m.Lat, m.Lng, lat, lng)
		hasil["biaya_jasa"] = t.BiayaJasa
		if km > jarakAntarMaksKM {
			hasil["bisa"] = false
			hasil["alasan"] = fmt.Sprintf("Lokasi di luar jangkauan antar (maksimal %.0f km dari toko).", jarakAntarMaksKM)
		}
	}
	writeJSONResponse(w, 200, hasil)
}

// permintaanKurirKasvo dikirim Kasvo saat pesanan antar masuk dapur.
type permintaanKurirKasvo struct {
	PengantaranID int64   `json:"pengantaran_id"`
	KasvoOrderID  int64   `json:"kasvo_order_id"`
	TokoUUID      string  `json:"toko_uuid"`
	PenerimaNama  string  `json:"penerima_nama"`
	PenerimaHP    string  `json:"penerima_hp"`
	Alamat        string  `json:"alamat"`
	Patokan       string  `json:"patokan"`
	Lat           float64 `json:"lat"`
	Lng           float64 `json:"lng"`
	// Nama, jumlah, dan varian — supaya driver bisa mencocokkan bungkusan di
	// kasir. Harga sengaja dinolkan: kurir tidak membayar makanan ini.
	Items []OrderItem `json:"items"`
}

// kurirKasvoMu: dua permintaan untuk pengantaran yang sama (tombol ditekan
// dua kali, kiriman ulang) tidak boleh sama-sama lolos pemeriksaan "sudah ada
// kurir" lalu memanggil dua kurir. ponytail: kunci satu proses, sama seperti
// gerbangSaldoMu — backend memang satu binary.
var kurirKasvoMu sync.Mutex

// kasvoKurirHandler: POST /api/integrasi/kasvo/kurir
//
// Satu kurir hidup per pengantaran: kiriman ulang mendapat pesanan yang sama.
// Setelah kurir sebelumnya kedaluwarsa atau batal, permintaan berikutnya
// membuat pesanan baru — itulah "cari ulang".
func kasvoKurirHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	if !tokenKasvoSah(r) {
		writeJSONResponse(w, 401, map[string]string{"error": "Token integrasi tidak sah"})
		return
	}
	var p permintaanKurirKasvo
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Data pengantaran tidak valid"})
		return
	}
	p.PenerimaNama = strings.TrimSpace(p.PenerimaNama)
	p.PenerimaHP = strings.TrimSpace(p.PenerimaHP)
	p.Alamat = strings.TrimSpace(p.Alamat)
	p.Patokan = strings.TrimSpace(p.Patokan)
	if p.PengantaranID <= 0 || p.KasvoOrderID <= 0 || p.PenerimaNama == "" || p.PenerimaHP == "" || p.Alamat == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Data pengantaran tidak lengkap"})
		return
	}
	if !koordinatValid(p.Lat, p.Lng) {
		writeJSONResponse(w, 400, map[string]string{"error": "Titik antar tidak valid"})
		return
	}
	if len(p.Items) > maksJenisMenu {
		writeJSONResponse(w, 400, map[string]string{"error": "Terlalu banyak jenis menu dalam satu pesanan"})
		return
	}
	m, ok := warungKasvo(p.TokoUUID)
	if !ok || !koordinatValid(m.Lat, m.Lng) {
		writeJSONResponse(w, 404, map[string]string{"error": "Toko belum tergabung di bohFood"})
		return
	}
	if jarakKM(m.Lat, m.Lng, p.Lat, p.Lng) > jarakAntarMaksKM {
		writeJSONResponse(w, 422, map[string]string{"error": fmt.Sprintf("Lokasi di luar jangkauan antar (maksimal %.0f km dari toko)", jarakAntarMaksKM)})
		return
	}
	jemput := m.RestaurantName
	if alamat := strings.TrimSpace(m.Address); alamat != "" {
		jemput += " — " + alamat
	}
	if pesan := teksPesananKepanjangan(CreateOrderInput{
		Pickup: jemput, Dropoff: p.Alamat, PackageNotes: p.Patokan,
		ReceiverName: p.PenerimaNama, ReceiverPhone: p.PenerimaHP,
	}); pesan != "" {
		writeJSONResponse(w, 400, map[string]string{"error": pesan})
		return
	}

	kurirKasvoMu.Lock()
	defer kurirKasvoMu.Unlock()

	var adaID string
	if db.QueryRow(`SELECT id FROM orders WHERE kasvo_pengantaran_id = ?
		AND status IN ('pending', 'accepted', 'picked_up', 'completed')
		ORDER BY created_at DESC LIMIT 1`, p.PengantaranID).Scan(&adaID) == nil {
		if o, ada := dbGetOrder(adaID); ada {
			writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "order": o})
			return
		}
	}

	items := make([]OrderItem, 0, len(p.Items))
	for _, it := range p.Items {
		if it.Qty < 1 || it.Qty > maksPorsiPerMenu || strings.TrimSpace(it.Name) == "" {
			continue
		}
		it.Price = 0
		for i := range it.Options {
			it.Options[i].Price = 0
		}
		items = append(items, it)
	}

	t := ambilTarif("BohFood")
	fare := hitungTarif(t, m.Lat, m.Lng, p.Lat, p.Lng)
	now := time.Now().Format(time.RFC3339)
	o := Order{
		ID: newID("order"), RiderPhone: m.OwnerPhone, RiderName: m.RestaurantName,
		PickupAddress: jemput, DropoffAddress: p.Alamat,
		PickupLat: m.Lat, PickupLng: m.Lng, DropoffLat: p.Lat, DropoffLng: p.Lng,
		Fare: fare, Komisi: hitungKomisi(t, fare), BiayaJasa: t.BiayaJasa,
		PaymentMethod: "cash", Service: "BohFood", Status: "pending",
		CreatedAt: now, UpdatedAt: now,
		PackageNotes: p.Patokan, ReceiverName: p.PenerimaNama, ReceiverPhone: p.PenerimaHP,
		MerchantID: m.ID, MerchantName: m.RestaurantName, Items: items, FoodTotal: 0,
		KasvoPesananID: p.KasvoOrderID, KasvoPengantaranID: p.PengantaranID,
	}
	if err := dbSaveOrder(o); err != nil {
		log.Printf("kurir Kasvo: pesanan untuk pengantaran %d gagal disimpan: %v", p.PengantaranID, err)
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan pesanan kurir"})
		return
	}
	notifikasiDriverSiaga(o)
	writeJSONResponse(w, 201, map[string]interface{}{"status": "success", "order": o})
}

// kasvoKurirBatalHandler: POST /api/integrasi/kasvo/kurir/{id}/batal
//
// Kasvo menarik kurir: pesanan makanannya ditolak, atau toko memilih
// mengantar sendiri / pelanggan mengambil. Hanya selama makanan belum dibawa
// kurir — sesudah itu urusan admin, sama seperti pembatalan oleh penumpang.
func kasvoKurirBatalHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	if !tokenKasvoSah(r) {
		writeJSONResponse(w, 401, map[string]string{"error": "Token integrasi tidak sah"})
		return
	}
	id, akhiran, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/api/integrasi/kasvo/kurir/"), "/")
	o, ok := dbGetOrder(id)
	if akhiran != "batal" || !ok || o.KasvoPengantaranID == 0 {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan kurir tidak ditemukan"})
		return
	}
	if o.Status == "cancelled" || o.Status == "expired" {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "order_status": o.Status})
		return
	}
	batal, err := dbCancelOrder(id, []string{"pending", "accepted"}, time.Now().Format(time.RFC3339))
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membatalkan kurir"})
		return
	}
	if !batal {
		writeJSONResponse(w, 409, map[string]interface{}{
			"error":        "Pesanan sudah dibawa kurir, tidak bisa dibatalkan dari toko. Hubungi admin bohAntar.",
			"order_status": o.Status,
		})
		return
	}
	if o.DriverPhone != "" {
		notifikasiKe(o.DriverPhone, "Pengantaran dibatalkan", o.MerchantName+" membatalkan pengantaran ini. Tidak perlu ke toko.", map[string]string{
			"tipe":     "dibatalkan",
			"order_id": o.ID,
		})
	}
	go sinkronKasvo()
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "order_status": "cancelled"})
}

// kabarkanKurirKasvo mengirim status kurir ke Kasvo, supaya pelanggan di web
// Kasvo melihat kurirnya (nama, kendaraan, nomor). Dipanggil dari
// sinkronKasvo — seketika saat status berubah dan tiap menit sebagai pengulang.
//
// kasvo_status_terkirim mencatat "status:nomor driver" terakhir yang diterima
// Kasvo; yang berbeda dikirim (lagi), termasuk driver yang berganti setelah
// pesanan dilepas. Status yang berubah di sela kirim dan catat tidak hilang:
// putaran berikutnya melihat perbedaannya.
func kabarkanKurirKasvo() {
	type kabar struct {
		id                    string
		pengantaran           int64
		status, hpKurir, nama string
	}
	rows, err := db.Query(`SELECT id, kasvo_pengantaran_id, status, COALESCE(driver_phone, ''), COALESCE(driver_name, '')
		FROM orders WHERE kasvo_pengantaran_id IS NOT NULL
		  AND CONCAT(status, ':', COALESCE(driver_phone, '')) <> COALESCE(kasvo_status_terkirim, '')`)
	if err != nil {
		log.Printf("kabar kurir Kasvo: daftar gagal dibaca: %v", err)
		return
	}
	var daftar []kabar
	for rows.Next() {
		var k kabar
		if rows.Scan(&k.id, &k.pengantaran, &k.status, &k.hpKurir, &k.nama) == nil {
			daftar = append(daftar, k)
		}
	}
	rows.Close()

	for _, k := range daftar {
		isi := map[string]interface{}{"bohantar_order_id": k.id, "pengantaran_id": k.pengantaran, "status": k.status}
		if k.hpKurir != "" {
			info := infoDriver(k.hpKurir)
			isi["kurir"] = map[string]interface{}{"nama": k.nama, "hp": k.hpKurir, "kendaraan": info["kendaraan"], "plat": info["plat"]}
		}
		kode, err := kirimKasvo(http.MethodPost, "/api/bohfood/kurir/status", isi, nil)
		if kode == 0 || kode >= 500 {
			log.Printf("kabar kurir Kasvo: %s belum sampai, dicoba lagi nanti: %v", k.id, err)
			continue
		}
		if err != nil {
			// 4xx: Kasvo tidak mengenal pengantaran ini. Mengulang tidak akan
			// mengubah jawabannya, jadi dicatat terkirim.
			log.Printf("kabar kurir Kasvo: %s ditolak Kasvo: %v", k.id, err)
		}
		_, _ = db.Exec("UPDATE orders SET kasvo_status_terkirim = ? WHERE id = ?", k.status+":"+k.hpKurir, k.id)
	}
}
