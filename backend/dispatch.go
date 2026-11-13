package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

// Pantau driver & pesanan manual dari dashboard super admin (9 Nov 2026).
//
// Pelanggan yang menelepon/WA admin minta ojek dibuatkan pesanan oleh admin dan
// ditujukan ke satu driver. Pesanan itu tetap pesanan biasa — pending, driver
// menekan Terima di aplikasinya — hanya papan orderan yang menawarkannya ke
// driver tujuan saja. Jadi aplikasi driver tidak perlu diubah, dan gerbang
// saldo, kecocokan kendaraan, lepas, batal, serta kedaluwarsa 15 menit tetap
// berlaku tanpa jalur kedua.

// adminDriverOnlineHandler: GET /api/admin/driver-online
//
// "Online" = kriteria yang sama dengan siaran orderan: posisi terkirim dalam 10
// menit terakhir (tombol Offline mengosongkannya seketika).
func adminDriverOnlineHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	// Pesanan berjalan dibaca terpisah, bukan JOIN ke users: di MariaDB produksi
	// collation kolom nomor kedua tabel ini berbeda (lihat catatan 1267).
	mengantar := map[string]map[string]string{}
	rows, err := db.Query(`SELECT driver_phone, id, status, service, pickup, dropoff FROM orders
		WHERE status IN ('accepted', 'picked_up') AND driver_phone IS NOT NULL`)
	if err != nil {
		galatServer(w, r, err)
		return
	}
	for rows.Next() {
		var p, id, st, svc, dari, ke sql.NullString
		if rows.Scan(&p, &id, &st, &svc, &dari, &ke) == nil {
			mengantar[p.String] = map[string]string{"id": id.String, "status": st.String, "service": svc.String, "pickup": dari.String, "dropoff": ke.String}
		}
	}
	rows.Close()

	rows, err = db.Query(`SELECT phone_number, name, driver_lat, driver_lng, driver_loc_at, is_driver_active
		FROM users WHERE role = 'driver' AND driver_loc_at > ? ORDER BY name`, time.Now().Add(-10*time.Minute))
	if err != nil {
		galatServer(w, r, err)
		return
	}
	drivers := []map[string]interface{}{}
	siaga := 0
	for rows.Next() {
		var phone, nama string
		var lat, lng float64
		var at sql.NullString
		var aktif bool
		if rows.Scan(&phone, &nama, &lat, &lng, &at, &aktif) != nil {
			continue
		}
		// DATETIME (produksi, lewat parseTime) terbaca RFC3339; skema lama
		// sebelum migrasi 002 masih teks jam lokal.
		waktu, err := time.Parse(time.RFC3339, at.String)
		if err != nil {
			waktu, _ = time.ParseInLocation("2006-01-02 15:04:05", at.String, time.Local)
		}
		d := map[string]interface{}{
			"phone": phone, "name": nama, "lat": lat, "lng": lng, "aktif": aktif,
			"detik_lalu": int(time.Since(waktu).Seconds()),
		}
		if o, ok := mengantar[phone]; ok {
			d["pesanan"] = o
		} else if aktif {
			siaga++
		}
		drivers = append(drivers, d)
	}
	rows.Close()
	// ponytail: satu kueri kendaraan per driver, sama seperti siaran orderan;
	// gabungkan ke kueri di atas kalau armadanya ratusan.
	for _, d := range drivers {
		d["kendaraan"] = kendaraanDriver(d["phone"].(string))
	}
	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success", "drivers": drivers,
		"ringkasan": map[string]int{"online": len(drivers), "siaga": siaga, "mengantar": len(mengantar)},
	})
}

// layananManual: semua layanan antar yang bisa dipesan lewat admin. BohRental
// bukan pesanan antar (sewa per hari lewat mitra), jadi tidak ikut.
var layananManual = map[string]bool{"BohRide": true, "BohCar": true, "BohSend": true, "BohFood": true}

// pesananManual menyusun pesanan dari isian admin. Dipisah dari handler supaya
// aturannya bisa diuji tanpa HTTP. Pesan galat kosong = boleh disimpan.
// Aturan isiannya sama dengan createOrderHandler: kelas BohCar, paket BohSend,
// warung & menu BohFood (titik jemputnya ditulis ulang jadi lokasi warung).
func pesananManual(nama, hp, driverTujuan string, in CreateOrderInput) (Order, string) {
	nama = strings.TrimSpace(nama)
	in.Pickup, in.Dropoff = strings.TrimSpace(in.Pickup), strings.TrimSpace(in.Dropoff)
	hp = strings.NewReplacer(" ", "", "-", "").Replace(strings.TrimSpace(hp))
	layanan := in.ServiceType
	switch {
	case nama == "" || hp == "":
		return Order{}, "Nama dan nomor HP pelanggan wajib diisi"
	case utf8.RuneCountInString(nama) > 60:
		return Order{}, "Nama pelanggan maksimal 60 karakter"
	case len(hp) < 9 || len(hp) > 15 || strings.Trim(hp, "+0123456789") != "":
		return Order{}, "Nomor HP pelanggan tidak valid"
	case !layananManual[layanan]:
		return Order{}, "Layanan harus BohRide, BohCar, BohSend, atau BohFood"
	}
	if pesan := teksPesananKepanjangan(in); pesan != "" {
		return Order{}, pesan
	}
	var warung FoodMerchant
	var items []OrderItem
	var foodTotal float64
	if layanan == "BohFood" {
		var pesan string
		if warung, items, foodTotal, pesan, _ = siapkanPesananMakanan(&in); pesan != "" {
			return Order{}, pesan
		}
	}
	switch {
	case in.Pickup == "" || in.Dropoff == "":
		return Order{}, "Alamat jemput dan tujuan wajib diisi"
	case !koordinatValid(in.PickupLat, in.PickupLng) || !koordinatValid(in.DropoffLat, in.DropoffLng):
		return Order{}, "Titik jemput dan tujuan harus dipilih di peta"
	case !dalamWilayahLayanan(in.PickupLat, in.PickupLng) || !dalamWilayahLayanan(in.DropoffLat, in.DropoffLng):
		return Order{}, pesanLuarWilayah
	}
	kelas := kelasPesanan(layanan, in.Kelas)

	// Pelanggan yang punya akun: pesanan tercatat atas akunnya, jadi ia ikut
	// melihat drivernya di aplikasi, dan tombol Telepon/Chat driver sampai ke
	// dia. Yang tidak punya akun: rider_phone kosong (foreign key ke users
	// melarang nomor sembarang), dan nomornya ditaruh di nama — satu-satunya
	// kolom yang ditampilkan kartu driver untuk BohRide.
	riderPhone, riderName := "", nama+" · "+hp
	if u, ada := dbGetUser(normalizePhone(hp)); ada && u.Role != "admin" {
		riderPhone, riderName = u.PhoneNumber, u.Name
	}

	if driverTujuan != "" {
		d, ada := dbGetUser(driverTujuan)
		if !ada || d.Role != "driver" {
			return Order{}, "Driver tidak ditemukan"
		}
		if !d.IsDriverActive {
			return Order{}, "Driver itu sedang dinonaktifkan"
		}
		if driverTujuan == riderPhone {
			return Order{}, "Driver tidak bisa mengantar pesanannya sendiri"
		}
		if !cocokKendaraan(layanan, kendaraanDriver(driverTujuan)) {
			return Order{}, "Kendaraan driver itu tidak cocok untuk " + layanan
		}
		if !cocokKelas(kelas, driverTujuan) {
			return Order{}, "Pesanan ini untuk mobil besar, mobil driver itu terdaftar sedang"
		}
	}

	t := ambilTarif(barisTarif(layanan, kelas))
	fare := hitungTarif(t, in.PickupLat, in.PickupLng, in.DropoffLat, in.DropoffLng)
	now := time.Now().Format(time.RFC3339)
	return Order{
		ID: newID("order"), RiderPhone: riderPhone, RiderName: riderName,
		PickupAddress: in.Pickup, DropoffAddress: in.Dropoff,
		PickupLat: in.PickupLat, PickupLng: in.PickupLng, DropoffLat: in.DropoffLat, DropoffLng: in.DropoffLng,
		Fare: fare, Komisi: hitungKomisi(t, fare), BiayaJasa: t.BiayaJasa,
		PaymentMethod: "cash", Service: layanan, Kelas: kelas, Status: "pending",
		CreatedAt: now, UpdatedAt: now, DriverTujuan: driverTujuan,
		PackageType: strings.TrimSpace(in.PackageType), PackageNotes: strings.TrimSpace(in.PackageNotes),
		ReceiverName: strings.TrimSpace(in.ReceiverName), ReceiverPhone: strings.TrimSpace(in.ReceiverPhone),
		MerchantID: warung.ID, MerchantName: warung.RestaurantName, Items: items, FoodTotal: foodTotal,
	}, ""
}

// adminPesananManualHandler: POST /api/admin/pesanan-manual
// driver_phone kosong = disiarkan ke semua driver seperti pesanan aplikasi.
func adminPesananManualHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var in struct {
		Nama        string  `json:"nama"`
		HP          string  `json:"hp"`
		Layanan     string  `json:"layanan"`
		Jemput      string  `json:"jemput"`
		Tujuan      string  `json:"tujuan"`
		JemputLat   float64 `json:"jemput_lat"`
		JemputLng   float64 `json:"jemput_lng"`
		TujuanLat   float64 `json:"tujuan_lat"`
		TujuanLng   float64 `json:"tujuan_lng"`
		DriverPhone string  `json:"driver_phone"`
		// Opsional, per layanan: lihat CreateOrderInput.
		Kelas         string        `json:"kelas"`
		PackageType   string        `json:"package_type"`
		PackageNotes  string        `json:"package_notes"`
		ReceiverName  string        `json:"receiver_name"`
		ReceiverPhone string        `json:"receiver_phone"`
		MerchantID    string        `json:"merchant_id"`
		Items         []itemPesanan `json:"items"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Data pesanan tidak valid"})
		return
	}
	o, pesan := pesananManual(in.Nama, in.HP, in.DriverPhone, CreateOrderInput{
		ServiceType: in.Layanan, Kelas: in.Kelas,
		Pickup: in.Jemput, Dropoff: in.Tujuan,
		PickupLat: in.JemputLat, PickupLng: in.JemputLng, DropoffLat: in.TujuanLat, DropoffLng: in.TujuanLng,
		PackageType: in.PackageType, PackageNotes: in.PackageNotes,
		ReceiverName: in.ReceiverName, ReceiverPhone: in.ReceiverPhone,
		MerchantID: in.MerchantID, Items: in.Items,
	})
	if pesan != "" {
		writeJSONResponse(w, 400, map[string]string{"error": pesan})
		return
	}
	if err := dbSaveOrder(o); err != nil {
		galatServer(w, r, err)
		return
	}
	notifikasiDriverSiaga(o)
	writeJSONResponse(w, 201, map[string]interface{}{"status": "success", "order": o})
}

// adminTujukanPesananHandler: POST /api/admin/pesanan-tujukan {order_id, driver_phone}
//
// Mengalihkan pesanan yang masih menunggu ke driver lain — driver tujuan tidak
// menanggapi, atau pesanan aplikasi yang tak kunjung diambil siapa pun.
// driver_phone kosong = lepaskan ke semua driver.
func adminTujukanPesananHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var in struct {
		OrderID     string `json:"order_id"`
		DriverPhone string `json:"driver_phone"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || in.OrderID == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Data tidak valid"})
		return
	}
	o, ada := dbGetOrder(in.OrderID)
	if !ada {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}
	if in.DriverPhone != "" {
		d, ada := dbGetUser(in.DriverPhone)
		switch {
		case !ada || d.Role != "driver":
			writeJSONResponse(w, 400, map[string]string{"error": "Driver tidak ditemukan"})
			return
		case !d.IsDriverActive:
			writeJSONResponse(w, 400, map[string]string{"error": "Driver itu sedang dinonaktifkan"})
			return
		case in.DriverPhone == o.RiderPhone:
			writeJSONResponse(w, 400, map[string]string{"error": "Driver tidak bisa mengantar pesanannya sendiri"})
			return
		case !cocokKendaraan(o.Service, kendaraanDriver(in.DriverPhone)):
			writeJSONResponse(w, 400, map[string]string{"error": "Kendaraan driver itu tidak cocok untuk " + o.Service})
			return
		case !cocokKelas(o.Kelas, in.DriverPhone):
			writeJSONResponse(w, 400, map[string]string{"error": "Pesanan ini untuk mobil besar, mobil driver itu terdaftar sedang"})
			return
		}
	}
	// Syarat pending dititipkan ke MySQL: driver yang menekan Terima di saat
	// yang sama menang atau kalah utuh, tidak setengah.
	res, err := db.Exec("UPDATE orders SET driver_tujuan = ?, updated_at = ? WHERE id = ? AND status = 'pending'",
		kosongJadiNULL(in.DriverPhone), time.Now(), in.OrderID)
	if err != nil {
		galatServer(w, r, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONResponse(w, 409, map[string]string{"error": "Pesanan sudah tidak menunggu driver"})
		return
	}
	o.DriverTujuan = in.DriverPhone
	notifikasiDriverSiaga(o)
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "order": o})
}
