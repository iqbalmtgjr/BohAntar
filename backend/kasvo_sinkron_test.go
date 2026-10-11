package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"
	"time"
)

// sinkronKasvo memindahkan stok toko orang: kiriman ganda berarti dapur memasak
// dua kali dan stok terpotong dua kali, pembatalan yang hilang berarti stoknya
// tidak pernah kembali. Kasvo-nya tiruan, database-nya sungguhan.
func TestSinkronKasvo(t *testing.T) {
	bukaDBTes(t)

	var mu sync.Mutex
	var jalur []string
	var badan map[string]interface{}
	jawab := http.StatusCreated
	milikTes := map[string]bool{}
	kasvo := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("X-Integrasi-Token") != "rahasia" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		jalur = append(jalur, r.URL.Path)
		if r.URL.Path == "/api/bohfood/pesanan" {
			badan = nil
			json.NewDecoder(r.Body).Decode(&badan)
			// Pesanan di DB lokal yang bukan milik tes ini dibiarkan apa adanya.
			if !milikTes[fmt.Sprint(badan["bohfood_order_id"])] {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.WriteHeader(jawab)
			fmt.Fprint(w, `{"id": 77, "total": 25000}`)
			return
		}
		fmt.Fprint(w, `{}`)
	}))
	defer kasvo.Close()
	lamaURL, lamaToken := kasvoURL, kasvoToken
	kasvoURL, kasvoToken = kasvo.URL, "rahasia"
	t.Cleanup(func() { kasvoURL, kasvoToken = lamaURL, lamaToken })

	pemilik := "+62800000091"
	penggunaUji(t, pemilik)
	mid := newID("merchant")
	if _, err := db.Exec(`INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, is_open, created_at, lat, lng, kasvo_toko_uuid)
		VALUES (?, ?, 'Warung Uji', '', 1, ?, -0.07, 111.49, 'uji-sinkron-kasvo')`, mid, pemilik, time.Now().Format(time.RFC3339)); err != nil {
		t.Fatalf("gagal menyiapkan warung uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM food_merchants WHERE id = ?", mid) })

	pesananMakananUji := func(rider string) string {
		oid := pesananUji(t, rider, "cash", "accepted", 8000)
		milikTes[oid] = true
		items := `[{"menu_id":"12","name":"Kopi","price":12500,"qty":2,"options":[{"id":"5","group":"Gula","name":"Sedikit","price":0}]}]`
		if _, err := db.Exec("UPDATE orders SET service = 'BohFood', merchant_id = ?, items_json = ?, food_total = 25000, driver_name = 'Budi' WHERE id = ?", mid, items, oid); err != nil {
			t.Fatalf("gagal menyiapkan pesanan makanan: %v", err)
		}
		return oid
	}
	kolom := func(oid string) int64 {
		var v int64
		db.QueryRow("SELECT COALESCE(kasvo_pesanan_id, -1) FROM orders WHERE id = ?", oid).Scan(&v)
		return v
	}
	kirimanKe := func(p string) int {
		mu.Lock()
		defer mu.Unlock()
		n := 0
		for _, j := range jalur {
			if j == p {
				n++
			}
		}
		return n
	}

	oid := pesananMakananUji("+62800000092")

	jawab = http.StatusInternalServerError
	sinkronKasvo()
	if v := kolom(oid); v != -1 {
		t.Fatalf("Kasvo galat: kolom harus tetap NULL supaya dicoba lagi, dapat %d", v)
	}

	jawab = http.StatusCreated
	sinkronKasvo()
	if v := kolom(oid); v != 77 {
		t.Fatalf("nomor pesanan kasir tidak tersimpan, dapat %d", v)
	}
	item := badan["items"].([]interface{})[0].(map[string]interface{})
	if badan["bohfood_order_id"] != oid || item["menu_id"] != "12" || item["qty"] != 2.0 ||
		!slices.Equal(item["options"].([]interface{}), []interface{}{"5"}) {
		t.Fatalf("isi kiriman salah: %v", badan)
	}

	terkirim := kirimanKe("/api/bohfood/pesanan")
	sinkronKasvo()
	if kirimanKe("/api/bohfood/pesanan") != terkirim {
		t.Fatal("pesanan yang sudah di kasir dikirim ulang")
	}

	db.Exec("UPDATE orders SET status = 'cancelled' WHERE id = ?", oid)
	sinkronKasvo()
	if kirimanKe("/api/bohfood/pesanan/"+oid+"/batal") != 1 {
		t.Fatal("pembatalan tidak diteruskan ke kasir")
	}
	if v := kolom(oid); v != -1 {
		t.Fatalf("setelah dibatalkan di kasir kolomnya harus NULL, dapat %d", v)
	}

	// Ditolak kasir (stok habis): tandai 0, jangan dicoba tiap menit, dan
	// tidak ada yang perlu dibatalkan di sana.
	ditolak := pesananMakananUji("+62800000093")
	jawab = http.StatusUnprocessableEntity
	sinkronKasvo()
	if v := kolom(ditolak); v != 0 {
		t.Fatalf("pesanan yang ditolak kasir harus ditandai 0, dapat %d", v)
	}
	db.Exec("UPDATE orders SET status = 'cancelled' WHERE id = ?", ditolak)
	sinkronKasvo()
	if kirimanKe("/api/bohfood/pesanan/"+ditolak+"/batal") != 0 {
		t.Fatal("pesanan yang tidak pernah masuk kasir ikut dibatalkan di sana")
	}
}
