package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
)

// ==================== BOHFOOD ====================
//
// Pesanan makanan menumpang tabel orders dan seluruh siklus hidup pesanan yang
// sudah ada — klaim anti-balapan, jemput, selesai, bagi hasil, bukti foto.
// Yang berbeda cuma tiga: titik jemputnya warung, isinya daftar menu, dan ada
// uang makanan yang ditalangi driver ke warung lalu ditagih kembali ke pemesan.
//
// ponytail: warung tidak menerima/menolak pesanan dan tidak punya status
// "sedang dimasak". Driver datang, memesan di tempat, membayar, mengantar —
// persis seperti orang menitip beli. Tambahkan tahap konfirmasi warung kalau
// warungnya mulai mengeluh driver datang sebelum makanannya siap.

// OrderItem adalah satu baris menu di pesanan. Nama dan harga disalin dari
// menu saat pesanan dibuat, supaya warung yang menaikkan harga besok tidak
// mengubah tagihan pesanan kemarin. Price adalah harga satu porsi SUDAH
// termasuk varian yang dipilih.
type OrderItem struct {
	MenuID  string         `json:"menu_id"`
	Name    string         `json:"name"`
	Price   float64        `json:"price"`
	Qty     int            `json:"qty"`
	Options []OpsiTerpilih `json:"options,omitempty"`
}

// OpsiTerpilih adalah varian yang ikut tersalin ke pesanan — cukup nama dan
// harganya, supaya driver tahu persis apa yang harus dibeli di kasir. ID-nya
// id varian di Kasvo, dipakai saat pesanan dikirim ke kasirnya (sinkronKasvo).
type OpsiTerpilih struct {
	ID    string  `json:"id,omitempty"`
	Group string  `json:"group"`
	Name  string  `json:"name"`
	Price float64 `json:"price"`
}

// itemPesanan adalah yang dikirim aplikasi: id menu, jumlah, dan id varian.
// Harga sengaja tidak ada di sini.
type itemPesanan struct {
	MenuID  string   `json:"menu_id"`
	Qty     int      `json:"qty"`
	Options []string `json:"options"`
}

const (
	maksJenisMenu    = 30
	maksPorsiPerMenu = 50
)

func pesananMakanan(o Order) bool { return o.Service == "BohFood" }

// susunItemMakanan mencocokkan keranjang aplikasi dengan menu warung yang
// sebenarnya. Harga selalu diambil dari menu, bukan dari aplikasi — siapa pun
// yang bisa mengirim HTTP bisa mengaku soto seharga seribu rupiah.
func susunItemMakanan(diminta []itemPesanan, menu []FoodMenu) ([]OrderItem, float64, string) {
	if len(diminta) == 0 {
		return nil, 0, "Keranjang masih kosong"
	}
	if len(diminta) > maksJenisMenu {
		return nil, 0, "Terlalu banyak jenis menu dalam satu pesanan"
	}
	byID := make(map[string]FoodMenu, len(menu))
	for _, m := range menu {
		byID[m.ID] = m
	}
	// Menu yang sama dengan varian yang sama digabung, bukan ditolak. Varian
	// berbeda tetap baris terpisah: es teh manis dan es teh tawar dua pesanan.
	baris := map[string]*OrderItem{}
	var urutan []string
	for _, d := range diminta {
		if d.Qty < 1 || d.Qty > maksPorsiPerMenu {
			return nil, 0, "Jumlah porsi tidak masuk akal"
		}
		m, ada := byID[d.MenuID]
		if !ada {
			return nil, 0, "Ada menu yang sudah tidak dijual warung ini"
		}
		if !m.IsAvailable {
			return nil, 0, m.Name + " sedang habis"
		}
		opsi, tambahan, pesan := pilihOpsi(m, d.Options)
		if pesan != "" {
			return nil, 0, pesan
		}
		if m.Price+tambahan < 0 {
			return nil, 0, "Harga " + m.Name + " tidak sah"
		}
		ids := append([]string(nil), d.Options...)
		sort.Strings(ids)
		kunci := d.MenuID + "|" + strings.Join(ids, ",")
		if b, ada := baris[kunci]; ada {
			b.Qty += d.Qty
			continue
		}
		baris[kunci] = &OrderItem{MenuID: m.ID, Name: m.Name, Price: m.Price + tambahan, Qty: d.Qty, Options: opsi}
		urutan = append(urutan, kunci)
	}
	if len(urutan) > maksJenisMenu {
		return nil, 0, "Terlalu banyak jenis menu dalam satu pesanan"
	}
	var hasil []OrderItem
	var total float64
	for _, k := range urutan {
		b := baris[k]
		if b.Qty > maksPorsiPerMenu {
			return nil, 0, "Jumlah porsi tidak masuk akal"
		}
		hasil = append(hasil, *b)
		total += b.Price * float64(b.Qty)
	}
	return hasil, total, ""
}

// pilihOpsi memeriksa varian yang dipilih untuk satu menu, dengan aturan yang
// sama seperti kasir Kasvo: grup "single" paling banyak satu pilihan, grup
// wajib minimal satu (grup "multiple" wajib minimal min_pilih), dan grup
// "multiple" dengan max lebih dari satu dibatasi max-nya. Hasilnya diurutkan
// mengikuti urutan grup di menu, bukan urutan kiriman aplikasi.
func pilihOpsi(m FoodMenu, ids []string) ([]OpsiTerpilih, float64, string) {
	dipilih := make(map[string]bool, len(ids))
	for _, id := range ids {
		if dipilih[id] {
			return nil, 0, "Pilihan varian " + m.Name + " tidak sah"
		}
		dipilih[id] = true
	}
	var hasil []OpsiTerpilih
	var tambahan float64
	terpakai := 0
	for _, g := range m.OptionGroups {
		n := 0
		for _, o := range g.Options {
			if dipilih[o.ID] {
				n++
				hasil = append(hasil, OpsiTerpilih{ID: o.ID, Group: g.Name, Name: o.Name, Price: o.Price})
				tambahan += o.Price
			}
		}
		terpakai += n
		minimal := 0
		if g.Required {
			minimal = 1
			if g.Type != "single" && g.Min > 1 {
				minimal = g.Min
			}
		}
		switch {
		case g.Type == "single" && n > 1:
			return nil, 0, "Pilih satu saja untuk " + g.Name
		case n < minimal:
			return nil, 0, "Pilih " + g.Name + " untuk " + m.Name
		case g.Type != "single" && g.Max > 1 && n > g.Max:
			return nil, 0, fmt.Sprintf("%s paling banyak %d pilihan", g.Name, g.Max)
		}
	}
	// Id yang tidak ada di grup mana pun: varian yang baru dihapus warung, atau
	// kiriman karangan.
	if terpakai != len(dipilih) {
		return nil, 0, "Ada varian " + m.Name + " yang sudah tidak tersedia"
	}
	return hasil, tambahan, ""
}

// uraiItems membaca kolom items_json. Kosong atau rusak sama-sama jadi nil —
// pesanan lama memang tidak punya item.
func uraiItems(s string) []OrderItem {
	if s == "" {
		return nil
	}
	var items []OrderItem
	if err := json.Unmarshal([]byte(s), &items); err != nil {
		return nil
	}
	return items
}

func dbGetFoodMerchant(id string) (FoodMerchant, bool) {
	var m FoodMerchant
	err := db.QueryRow(
		"SELECT id, owner_phone, restaurant_name, address, COALESCE(image_url, ''), is_open, created_at, lat, lng, COALESCE(kasvo_toko_uuid, '') FROM food_merchants WHERE id = ?", id,
	).Scan(&m.ID, &m.OwnerPhone, &m.RestaurantName, &m.Address, &m.ImageURL, &m.IsOpen, &m.CreatedAt, &m.Lat, &m.Lng, &m.KasvoTokoUUID)
	return m, err == nil
}

// menuWarung adalah menu yang berlaku untuk satu warung, plus apakah warung itu
// sedang menerima pesanan. Toko Kasvo dibaca langsung dari kasirnya, termasuk
// jam bukanya; is_open di sini tetap berlaku sebagai saklar dari sisi bohAntar.
func menuWarung(m FoodMerchant) ([]FoodMenu, bool, error) {
	if m.KasvoTokoUUID == "" {
		menus, err := dbGetFoodMenus(m.ID)
		return menus, m.IsOpen, err
	}
	buka, menus, err := ambilMenuKasvo(m.KasvoTokoUUID)
	for i := range menus {
		menus[i].MerchantID = m.ID
	}
	return menus, buka && m.IsOpen, err
}

func dbGetFoodMenus(merchantID string) ([]FoodMenu, error) {
	rows, err := db.Query("SELECT id, merchant_id, name, COALESCE(description, ''), price, COALESCE(category, ''), COALESCE(image_url, ''), is_available FROM food_menus WHERE merchant_id = ? ORDER BY category, name", merchantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	menus := []FoodMenu{}
	for rows.Next() {
		var m FoodMenu
		if err := rows.Scan(&m.ID, &m.MerchantID, &m.Name, &m.Description, &m.Price, &m.Category, &m.ImageURL, &m.IsAvailable); err == nil {
			menus = append(menus, m)
		}
	}
	return menus, rows.Err()
}

// siapkanPesananMakanan memuat warung dan menunya, lalu menulis ulang titik
// jemput pesanan menjadi lokasi warung. Alamat jemput dari aplikasi diabaikan:
// driver harus ke warung, ke mana pun pemesan sedang berdiri.
func siapkanPesananMakanan(input *CreateOrderInput) (FoodMerchant, []OrderItem, float64, string, int) {
	m, ok := dbGetFoodMerchant(input.MerchantID)
	if !ok {
		return m, nil, 0, "Warung tidak ditemukan", 404
	}
	if !koordinatValid(m.Lat, m.Lng) {
		return m, nil, 0, "Warung ini belum mengatur lokasinya, jadi belum bisa menerima pesanan", 400
	}
	menu, buka, err := menuWarung(m)
	if err != nil {
		return m, nil, 0, "Gagal membaca menu warung, coba lagi sebentar", 502
	}
	if !buka {
		return m, nil, 0, "Warung sedang tutup", 400
	}
	items, total, pesan := susunItemMakanan(input.Items, menu)
	if pesan != "" {
		return m, nil, 0, pesan, 400
	}
	// Alamat warung boleh kosong sampai mitra mengisinya di portal; nama saja
	// lebih baik daripada nama diikuti pemisah yang menggantung.
	input.Pickup = m.RestaurantName
	if alamat := strings.TrimSpace(m.Address); alamat != "" {
		input.Pickup += " — " + alamat
	}
	input.PickupLat, input.PickupLng = m.Lat, m.Lng
	return m, items, total, "", 0
}

// foodMerchantsHandler: daftar warung untuk pemesan. Warung yang belum
// mengatur lokasinya tidak ikut — ongkirnya tidak bisa dihitung dan driver tidak
// tahu harus ke mana. Yang tutup tetap tampil (ditandai), supaya pelanggan tahu
// warung itu ada dan bisa kembali nanti.
func foodMerchantsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	rows, err := db.Query("SELECT id, restaurant_name, address, COALESCE(image_url, ''), is_open, lat, lng, COALESCE(kasvo_toko_uuid, '') FROM food_merchants WHERE lat <> 0 AND lng <> 0")
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca daftar warung"})
		return
	}
	defer rows.Close()

	type warung struct {
		ID      string  `json:"id"`
		Nama    string  `json:"restaurant_name"`
		Alamat  string  `json:"address"`
		Gambar  string  `json:"image_url"`
		Buka    bool    `json:"is_open"`
		Lat     float64 `json:"lat"`
		Lng     float64 `json:"lng"`
		JarakKM float64 `json:"jarak_km"` // -1 kalau pemesan tidak mengirim posisinya
		// Ongkir kalau diantar ke posisi pemesan sekarang. Rumus dan jaraknya
		// sama dengan /api/tarif/estimasi, jadi angkanya sama dengan yang nanti
		// ditagih. 0 kalau posisinya tidak diketahui.
		Ongkir    float64 `json:"ongkir"`
		InfoBuka  string  `json:"info_buka"`  // selama tutup, mis. "Buka lagi besok 07.00"
		CocokMenu string  `json:"cocok_menu"` // menu yang cocok dengan pencarian ?q=
		kasvo     string
	}
	lat, _ := strconv.ParseFloat(r.URL.Query().Get("lat"), 64)
	lng, _ := strconv.ParseFloat(r.URL.Query().Get("lng"), 64)
	adaPosisi := koordinatValid(lat, lng)
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	tarif := ambilTarif("BohFood")

	daftar := make([]warung, 0)
	var uuids []string
	for rows.Next() {
		var x warung
		if err := rows.Scan(&x.ID, &x.Nama, &x.Alamat, &x.Gambar, &x.Buka, &x.Lat, &x.Lng, &x.kasvo); err != nil {
			continue
		}
		x.JarakKM = -1
		if adaPosisi {
			x.JarakKM = jarakKM(lat, lng, x.Lat, x.Lng)
			x.Ongkir = hitungOngkos(tarif, x.JarakKM*1000)
		}
		if x.kasvo != "" {
			uuids = append(uuids, x.kasvo)
		}
		daftar = append(daftar, x)
	}
	// Jam buka toko Kasvo diatur di Kasvo; satu panggilan untuk semuanya.
	if len(uuids) > 0 {
		status := bukaKasvo(uuids)
		for i := range daftar {
			if s, ok := status[daftar[i].kasvo]; daftar[i].kasvo != "" {
				daftar[i].Buka = daftar[i].Buka && ok && s.Buka
				if ok && !s.Buka {
					daftar[i].InfoBuka = s.Info
				}
			}
		}
	}
	// Pencarian mencocokkan nama warung, alamat, dan nama menu: "soto" harus
	// menemukan warung yang menjual soto walau namanya "Warung Bu Ani".
	if q != "" {
		menuLokal := map[string]string{}
		if rs, err := db.Query("SELECT merchant_id, MIN(name) FROM food_menus WHERE name LIKE ? GROUP BY merchant_id", "%"+q+"%"); err == nil {
			for rs.Next() {
				var id, nama string
				if rs.Scan(&id, &nama) == nil {
					menuLokal[id] = nama
				}
			}
			rs.Close()
		}
		menuKasvo := map[string]string{}
		if len(uuids) > 0 {
			menuKasvo = cariMenuKasvo(q, uuids)
		}
		tersaring := daftar[:0]
		for _, x := range daftar {
			if x.kasvo != "" {
				x.CocokMenu = menuKasvo[x.kasvo]
			} else {
				x.CocokMenu = menuLokal[x.ID]
			}
			if strings.Contains(strings.ToLower(x.Nama), q) || strings.Contains(strings.ToLower(x.Alamat), q) || x.CocokMenu != "" {
				tersaring = append(tersaring, x)
			}
		}
		daftar = tersaring
	}
	// Yang buka dulu, lalu yang terdekat.
	sort.SliceStable(daftar, func(i, j int) bool {
		if daftar[i].Buka != daftar[j].Buka {
			return daftar[i].Buka
		}
		return daftar[i].JarakKM < daftar[j].JarakKM
	})
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "merchants": daftar})
}

// foodOrdersHandler: pesanan yang masuk ke warung milik pemanggil, terbaru
// dulu. Warung tidak mengubah status apa pun — driverlah yang mengambil dan
// mengantar — jadi ini jendela, bukan tombol.
func foodOrdersHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var merchantID string
	if err := db.QueryRow("SELECT id FROM food_merchants WHERE owner_phone = ?", callerPhone(r)).Scan(&merchantID); err != nil {
		writeJSONResponse(w, 404, map[string]string{"error": "Merchant not found"})
		return
	}
	rows, err := db.Query(`
		SELECT id, COALESCE(rider_name, ''), status, fare, COALESCE(food_total, 0), COALESCE(items_json, ''),
		       COALESCE(package_notes, ''), COALESCE(driver_name, ''), created_at, updated_at
		FROM orders WHERE merchant_id = ? ORDER BY created_at DESC LIMIT 50`, merchantID)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca pesanan"})
		return
	}
	defer rows.Close()

	daftar := make([]map[string]interface{}, 0)
	for rows.Next() {
		var o Order
		var itemsJSON string
		if err := rows.Scan(&o.ID, &o.RiderName, &o.Status, &o.Fare, &o.FoodTotal, &itemsJSON, &o.PackageNotes, &o.DriverName, &o.CreatedAt, &o.UpdatedAt); err != nil {
			continue
		}
		daftar = append(daftar, map[string]interface{}{
			"id": o.ID, "rider_name": o.RiderName, "status": o.Status,
			"fare": o.Fare, "food_total": o.FoodTotal, "items": uraiItems(itemsJSON),
			"package_notes": o.PackageNotes, "driver_name": o.DriverName,
			"created_at": o.CreatedAt, "updated_at": o.UpdatedAt,
		})
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "orders": daftar})
}
