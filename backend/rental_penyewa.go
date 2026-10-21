package main

import (
	"log"
	"net/http"
)

// Sisi penyewa BohRental di aplikasi. Sisi mitra (armada, jadwal, pesanan
// masuk) ada di main.go dan dashboard web; memesan dan membatalkan sewa
// memakai /api/rental/bookings yang sama.

// KendaraanSewa satu kendaraan di katalog aplikasi. Plat nomor sengaja tidak
// ikut: penyewa baru butuh itu setelah sewanya jadi.
type KendaraanSewa struct {
	ID           string  `json:"id"`
	Brand        string  `json:"brand"`
	Model        string  `json:"model"`
	Transmission string  `json:"transmission"`
	Seats        int     `json:"seats"`
	PricePerDay  float64 `json:"price_per_day"`
	ImageURL     string  `json:"image_url"`
	VehicleType  string  `json:"vehicle_type"`
	MitraNama    string  `json:"mitra_nama"`
	MitraAlamat  string  `json:"mitra_alamat"`
}

// Nama usaha dan alamat mitra, dengan o = baris users pemilik armada. Urutan
// sumbernya sama dengan businessNameOf: profil dulu, lalu pengajuan kemitraan
// yang disetujui.
const (
	sqlNamaMitra = `COALESCE(NULLIF(TRIM(o.business_name), ''),
		(SELECT NULLIF(TRIM(p.business_name), '') FROM partner_applications p
		 WHERE p.phone_number = o.phone_number AND p.status = 'approved' ORDER BY p.created_at DESC LIMIT 1),
		o.name, '')`
	sqlAlamatMitra = `COALESCE((SELECT p.address FROM partner_applications p
		 WHERE p.phone_number = o.phone_number AND p.status = 'approved' ORDER BY p.created_at DESC LIMIT 1), '')`
)

// GET /api/rental/katalog — kendaraan aktif semua mitra rental. Mitra yang
// langganannya habis disembunyikan: ia tidak bisa membuka pesanan masuk (402),
// jadi permintaan sewa ke armadanya akan menggantung tanpa ada yang membaca.
func katalogRentalHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	rows, err := db.Query(`
		SELECT c.id, c.brand, c.model, c.transmission, c.seats, c.price_per_day,
			COALESCE(c.image_url, ''), COALESCE(c.vehicle_type, 'car'), ` + sqlNamaMitra + `, ` + sqlAlamatMitra + `
		FROM rental_cars c
		JOIN users o ON o.phone_number = c.owner_phone
		LEFT JOIN partner_subscriptions s ON s.phone_number = c.owner_phone
		WHERE c.status = 'active' AND o.role = 'rental_partner'
			AND (s.phone_number IS NULL OR (s.status <> 'EXPIRED' AND s.valid_until > NOW()))
		ORDER BY c.price_per_day, c.brand, c.model`)
	if err != nil {
		log.Printf("Katalog rental gagal dibaca: %v", err)
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memuat kendaraan"})
		return
	}
	defer rows.Close()
	daftar := []KendaraanSewa{}
	for rows.Next() {
		var k KendaraanSewa
		if err := rows.Scan(&k.ID, &k.Brand, &k.Model, &k.Transmission, &k.Seats, &k.PricePerDay,
			&k.ImageURL, &k.VehicleType, &k.MitraNama, &k.MitraAlamat); err == nil {
			daftar = append(daftar, k)
		}
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "kendaraan": daftar})
}

// kabarSewa: judul dan isi notifikasi untuk penyewa saat mitra mengubah status
// sewanya. Tanpa ini penyewa harus membuka "Sewa saya" berulang-ulang.
func kabarSewa(status, catatan string) (judul, isi string) {
	switch status {
	case "confirmed":
		return "Sewa dikonfirmasi", "Mitra sudah menyetujui sewamu. Ambil kendaraannya sesuai jadwal, ya."
	case "rejected":
		return "Sewa ditolak mitra", catatan
	case "cancelled":
		if catatan == "" {
			catatan = "Mitra membatalkan sewamu. Coba kendaraan lain, ya."
		}
		return "Sewa dibatalkan mitra", catatan
	case "ongoing":
		return "Sewa dimulai", "Selamat jalan! Kembalikan kendaraannya tepat waktu, ya."
	case "completed":
		return "Sewa selesai", "Terima kasih sudah menyewa lewat BohRental."
	}
	return "", ""
}
