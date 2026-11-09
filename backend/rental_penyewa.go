package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"time"
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
	// Rentang yang sudah terpakai, supaya penyewa tahu kapan kendaraan bebas
	// sebelum mengajukan. Sengaja tanpa data penyewa lain.
	Terpakai []Terpakai `json:"terpakai"`
}

// Terpakai satu rentang yang mengunci kendaraan. BelumKembali = sewa yang lewat
// jatuh tempo tapi kendaraannya belum dikembalikan (waktu bebasnya tak diketahui).
type Terpakai struct {
	Mulai        string `json:"mulai"`
	Selesai      string `json:"selesai"`
	BelumKembali bool   `json:"belum_kembali,omitempty"`
}

type rentangSewa struct {
	mulai, selesai time.Time
	belumKembali   bool
}

type penanya interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

// terpakaiKendaraan mengumpulkan rentang yang mengunci kendaraan untuk pemesanan
// dari aplikasi, dikelompokkan per car_id (carID "" = semua kendaraan):
//   - pesanan aplikasi yang masih hidup dan belum lewat; yang Sedang Berjalan
//     tapi lewat jatuh tempo = belum kembali;
//   - jadwal mitra di Kalender (sewa manual & perawatan) yang belum ditutup;
//     yang lewat jatuh tempo juga dianggap belum kembali.
//
// Pesanan "Menunggu"/"Disetujui" yang tanggalnya sudah lewat TIDAK mengunci:
// mitra yang tidak merespons atau penyewa yang tidak datang bukan alasan
// kendaraan ditolak untuk tanggal berapa pun (bug sebelum 10 Nov 2026).
func terpakaiKendaraan(q penanya, carID string) (map[string][]rentangSewa, error) {
	saring, args := "", []any{}
	if carID != "" {
		saring = " AND car_id = ?"
		args = []any{carID, carID}
	}
	rows, err := q.Query(`
		SELECT car_id, start_time, end_time, status = 'ongoing' AND end_time < NOW()
		FROM rental_bookings
		WHERE status NOT IN ('cancelled', 'rejected', 'completed') AND (end_time > NOW() OR status = 'ongoing')`+saring+`
		UNION ALL
		SELECT car_id, start_time, end_time, end_time < NOW()
		FROM rental_car_schedules
		WHERE COALESCE(status, 'active') <> 'completed'`+saring+`
		ORDER BY 2`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	hasil := map[string][]rentangSewa{}
	for rows.Next() {
		var id string
		var r rentangSewa
		if err := rows.Scan(&id, &r.mulai, &r.selesai, &r.belumKembali); err != nil {
			return nil, err
		}
		hasil[id] = append(hasil[id], r)
	}
	return hasil, rows.Err()
}

// bentrokDengan mengembalikan rentang pertama yang menghalangi sewa [mulai, selesai).
// Kendaraan yang belum kembali menghalangi tanggal berapa pun.
func bentrokDengan(daftar []rentangSewa, mulai, selesai time.Time) (rentangSewa, bool) {
	for _, r := range daftar {
		if r.belumKembali || (mulai.Before(r.selesai) && selesai.After(r.mulai)) {
			return r, true
		}
	}
	return rentangSewa{}, false
}

var bulanPendek = [...]string{"Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"}

func tglPendek(t time.Time) string {
	return fmt.Sprintf("%d %s %02d.%02d", t.Day(), bulanPendek[t.Month()-1], t.Hour(), t.Minute())
}

// pesanBentrok memberi arah ke penyewa, bukan sekadar "bertabrakan".
func pesanBentrok(r rentangSewa) string {
	if r.belumKembali {
		return "Kendaraan ini belum dikembalikan penyewa sebelumnya, jadi belum bisa dipesan. Hubungi mitranya atau pilih kendaraan lain, ya."
	}
	return fmt.Sprintf("Kendaraan ini sudah terpakai %s – %s. Pilih waktu di luar itu, ya.", tglPendek(r.mulai), tglPendek(r.selesai))
}

const catatanSewaKedaluwarsa = "Dibatalkan otomatis: mitra belum mengonfirmasi sampai lewat jam ambil."

// kedaluwarsakanSewa membatalkan permintaan sewa yang tidak ditanggapi mitra
// sampai 2 jam lewat jam ambil, lalu memberi tahu penyewanya. Dipanggil penyapu
// tiap menit (kedaluwarsakanPesanan).
//   - Tenggang 2 jam: mitra sering baru mengonfirmasi saat penyewa datang.
//   - Notifikasi hanya untuk jam ambil ≤ 1 hari lalu: saat binary ini pertama
//     naik, permintaan basi berbulan-bulan ikut dibatalkan diam-diam, bukan
//     membanjiri penyewanya dengan kabar sewa yang sudah lama dilupakan.
func kedaluwarsakanSewa() {
	rows, err := db.Query(`SELECT id, customer_phone, start_time > NOW() - INTERVAL 1 DAY FROM rental_bookings
		WHERE status = 'pending' AND start_time < NOW() - INTERVAL 2 HOUR`)
	if err != nil {
		log.Printf("Gagal membaca sewa kedaluwarsa: %v", err)
		return
	}
	type basi struct {
		id, penyewa string
		baru        bool
	}
	var daftar []basi
	for rows.Next() {
		var b basi
		if rows.Scan(&b.id, &b.penyewa, &b.baru) == nil {
			daftar = append(daftar, b)
		}
	}
	rows.Close()
	for _, b := range daftar {
		// Bersyarat 'pending': mitra yang menyetujui di detik yang sama menang.
		res, err := db.Exec("UPDATE rental_bookings SET status = 'cancelled', notes = ?, updated_at = ? WHERE id = ? AND status = 'pending'",
			catatanSewaKedaluwarsa, time.Now(), b.id)
		if err != nil {
			log.Printf("Gagal membatalkan sewa kedaluwarsa %s: %v", b.id, err)
			continue
		}
		if n, _ := res.RowsAffected(); n == 1 && b.baru {
			notifikasiKe(b.penyewa, "Sewa kedaluwarsa",
				"Mitra belum mengonfirmasi sewamu sampai lewat jam ambil, jadi permintaannya dibatalkan otomatis. Coba kendaraan lain, ya.",
				map[string]string{"tipe": "sewa"})
		}
	}
}

// Nama usaha dan alamat mitra, dengan o = baris users pemilik armada. Urutan
// sumbernya sama dengan businessNameOf: profil dulu, lalu pengajuan kemitraan
// yang disetujui.
const (
	sqlNamaMitra = `COALESCE(NULLIF(TRIM(o.business_name), ''),
		(SELECT NULLIF(TRIM(p.business_name), '') FROM partner_applications p
		 WHERE p.phone_number = o.phone_number AND p.status = 'approved' ORDER BY p.created_at DESC LIMIT 1),
		o.name, '')`
	// Alamat Rental yang diisi mitra di Akun Saya didahulukan.
	sqlAlamatMitra = `COALESCE(NULLIF(TRIM(o.business_address), ''), (SELECT p.address FROM partner_applications p
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
	rows.Close()
	// Satu kueri untuk semua kendaraan. Gagal dibaca bukan alasan katalog
	// kosong: kendaraan tetap tampil, server tetap menolak yang bentrok.
	terpakai, err := terpakaiKendaraan(db, "")
	if err != nil {
		log.Printf("Jadwal terpakai katalog gagal dibaca: %v", err)
	}
	for i := range daftar {
		daftar[i].Terpakai = []Terpakai{}
		for _, r := range terpakai[daftar[i].ID] {
			daftar[i].Terpakai = append(daftar[i].Terpakai, Terpakai{
				Mulai:        r.mulai.Format("2006-01-02 15:04:05"),
				Selesai:      r.selesai.Format("2006-01-02 15:04:05"),
				BelumKembali: r.belumKembali,
			})
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
