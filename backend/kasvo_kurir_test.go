package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Kurir untuk pelanggan toko Kasvo menyentuh uang tiga pihak: pelanggan
// membayar ongkir yang dilihatnya di checkout, kurir menagih sebesar itu, dan
// makanan yang sudah dibayar tidak boleh ikut batal saat kurirnya kedaluwarsa.
// Kasvo-nya tiruan, database-nya sungguhan.
func TestKurirKasvo(t *testing.T) {
	bukaDBTes(t)

	var mu sync.Mutex
	var kabar []map[string]interface{} // status kurir yang diterima Kasvo
	var jalurLain []string             // panggilan fase 3 (pesanan aplikasi)
	kasvo := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path == "/api/bohfood/kurir/status" {
			var isi map[string]interface{}
			json.NewDecoder(r.Body).Decode(&isi)
			kabar = append(kabar, isi)
			fmt.Fprint(w, `{"ok":true}`)
			return
		}
		var isi map[string]interface{}
		json.NewDecoder(r.Body).Decode(&isi)
		jalurLain = append(jalurLain, r.URL.Path+" "+fmt.Sprint(isi["bohfood_order_id"]))
		w.WriteHeader(http.StatusInternalServerError) // pesanan lokal lain dibiarkan
	}))
	defer kasvo.Close()
	lamaURL, lamaToken := kasvoURL, kasvoToken
	kasvoURL, kasvoToken = kasvo.URL, "rahasia"
	t.Cleanup(func() { kasvoURL, kasvoToken = lamaURL, lamaToken })

	pemilik, kurir := "+62800000097", "+62800000098"
	penggunaUji(t, pemilik)
	penggunaUji(t, kurir)
	mid := newID("merchant")
	if _, err := db.Exec(`INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, is_open, created_at, lat, lng, kasvo_toko_uuid)
		VALUES (?, ?, 'Warung Kurir', 'Jl. Uji', 1, ?, -0.07, 111.49, 'uji-kurir-kasvo')`, mid, pemilik, time.Now().Format(time.RFC3339)); err != nil {
		t.Fatalf("gagal menyiapkan warung uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM food_merchants WHERE id = ?", mid) })
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE kasvo_pengantaran_id = 501") })

	panggil := func(h http.HandlerFunc, metode, jalur string, isi interface{}, token string) (int, map[string]interface{}) {
		var badan bytes.Buffer
		if isi != nil {
			json.NewEncoder(&badan).Encode(isi)
		}
		r := httptest.NewRequest(metode, jalur, &badan)
		r.Header.Set("X-Integrasi-Token", token)
		w := httptest.NewRecorder()
		h(w, r)
		var hasil map[string]interface{}
		json.Unmarshal(w.Body.Bytes(), &hasil)
		return w.Code, hasil
	}
	kabarUntuk := func(id string) []string {
		mu.Lock()
		defer mu.Unlock()
		var s []string
		for _, k := range kabar {
			if k["bohantar_order_id"] == id {
				s = append(s, fmt.Sprint(k["status"]))
			}
		}
		return s
	}
	fase3Menyentuh := func(id string) bool {
		mu.Lock()
		defer mu.Unlock()
		for _, j := range jalurLain {
			if strings.Contains(j, id) {
				return true
			}
		}
		return false
	}

	// Ongkir checkout = ongkir yang nanti ditagih kurir.
	tarif := ambilTarif("BohFood")
	harap := hitungTarif(tarif, -0.07, 111.49, -0.08, 111.50)
	kode, o := panggil(kasvoOngkirHandler, http.MethodGet, "/api/integrasi/kasvo/ongkir?uuid=uji-kurir-kasvo&lat=-0.08&lng=111.50", nil, "rahasia")
	if kode != 200 || o["ongkir"] != harap || o["biaya_jasa"] != tarif.BiayaJasa {
		t.Fatalf("ongkir checkout salah: %d %v (harap %v)", kode, o, harap)
	}
	if _, o := panggil(kasvoOngkirHandler, http.MethodGet, "/api/integrasi/kasvo/ongkir?uuid=uji-kurir-kasvo&lat=-0.07&lng=111.60", nil, "rahasia"); o["bisa"] != false || !strings.Contains(fmt.Sprint(o["alasan"]), "jangkauan") {
		t.Fatalf("lokasi di luar 10 km harus ditolak: %v", o)
	}
	if kode, _ := panggil(kasvoOngkirHandler, http.MethodGet, "/api/integrasi/kasvo/ongkir?uuid=uji-kurir-kasvo", nil, "salah"); kode != 401 {
		t.Fatalf("token salah harus 401, dapat %d", kode)
	}

	minta := map[string]interface{}{
		"pengantaran_id": 501, "kasvo_order_id": 9001, "toko_uuid": "uji-kurir-kasvo",
		"penerima_nama": "Andi", "penerima_hp": "081234567890", "alamat": "Jl. Mawar 5", "patokan": "pagar hijau",
		"lat": -0.08, "lng": 111.50,
		"items": []map[string]interface{}{{"menu_id": "12", "name": "Soto", "price": 15000, "qty": 2}},
	}
	kode, hasil := panggil(kasvoKurirHandler, http.MethodPost, "/api/integrasi/kasvo/kurir", minta, "rahasia")
	if kode != 201 {
		t.Fatalf("minta kurir gagal: %d %v", kode, hasil)
	}
	id := hasil["order"].(map[string]interface{})["id"].(string)
	p, _ := dbGetOrder(id)
	if p.RiderPhone != pemilik || p.Service != "BohFood" || p.PaymentMethod != "cash" || p.FoodTotal != 0 || p.Fare != harap ||
		p.ReceiverName != "Andi" || p.KasvoPengantaranID != 501 || p.KasvoPesananID != 9001 || p.Items[0].Price != 0 {
		t.Fatalf("pesanan kurir tersimpan salah: %+v", p)
	}

	if kode, hasil := panggil(kasvoKurirHandler, http.MethodPost, "/api/integrasi/kasvo/kurir", minta, "rahasia"); kode != 200 ||
		hasil["order"].(map[string]interface{})["id"] != id {
		t.Fatalf("kiriman ulang harus mendapat kurir yang sama: %d %v", kode, hasil)
	}
	jauh := map[string]interface{}{}
	for k, v := range minta {
		jauh[k] = v
	}
	jauh["lng"] = 111.60
	if kode, _ := panggil(kasvoKurirHandler, http.MethodPost, "/api/integrasi/kasvo/kurir", jauh, "rahasia"); kode != 422 {
		t.Fatalf("minta kurir di luar 10 km harus 422, dapat %d", kode)
	}

	sinkronKasvo()
	if s := kabarUntuk(id); len(s) != 1 || s[0] != "pending" {
		t.Fatalf("Kasvo harus dikabari 'pending' sekali: %v", s)
	}
	sinkronKasvo()
	if s := kabarUntuk(id); len(s) != 1 {
		t.Fatalf("status yang sama dikirim ulang: %v", s)
	}

	// Driver menerima: Kasvo dikabari beserta kurirnya, dan fase 3 TIDAK
	// mengirimnya ke kasir sebagai pesanan aplikasi kedua.
	db.Exec("UPDATE orders SET status = 'accepted', driver_phone = ?, driver_name = 'Budi' WHERE id = ?", kurir, id)
	sinkronKasvo()
	mu.Lock()
	terakhir := kabar[len(kabar)-1]
	mu.Unlock()
	if s := kabarUntuk(id); s[len(s)-1] != "accepted" || terakhir["kurir"].(map[string]interface{})["hp"] != kurir {
		t.Fatalf("kurir yang menerima harus dikabarkan: %v %v", s, terakhir)
	}

	// Toko membatalkan: kurir ditarik, makanan di kasir TIDAK ikut dibatalkan.
	if kode, _ := panggil(kasvoKurirBatalHandler, http.MethodPost, "/api/integrasi/kasvo/kurir/"+id+"/batal", nil, "rahasia"); kode != 200 {
		t.Fatalf("batal kurir harus 200, dapat %d", kode)
	}
	sinkronKasvo()
	if s := kabarUntuk(id); s[len(s)-1] != "cancelled" {
		t.Fatalf("pembatalan harus dikabarkan: %v", s)
	}
	if fase3Menyentuh(id) {
		t.Fatal("mesin fase 3 ikut mengirim/membatalkan pesanan kurir di kasir")
	}

	// Cari ulang setelah batal: kurir baru untuk pengantaran yang sama.
	if kode, hasil := panggil(kasvoKurirHandler, http.MethodPost, "/api/integrasi/kasvo/kurir", minta, "rahasia"); kode != 201 ||
		hasil["order"].(map[string]interface{})["id"] == id {
		t.Fatalf("cari ulang harus membuat kurir baru: %d %v", kode, hasil)
	}

	// Pesanan biasa tidak boleh dibatalkan lewat jalur integrasi.
	biasa := pesananUji(t, "+62800000099", "cash", "pending", 8000)
	if kode, _ := panggil(kasvoKurirBatalHandler, http.MethodPost, "/api/integrasi/kasvo/kurir/"+biasa+"/batal", nil, "rahasia"); kode != 404 {
		t.Fatalf("pesanan non-kurir harus 404, dapat %d", kode)
	}
}
