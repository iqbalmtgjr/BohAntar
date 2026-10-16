package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// Halaman /privasi menjanjikan dua jalur hapus akun: dari aplikasi, dan lewat
// email yang diproses admin di dashboard. Yang dijaga: jalur admin tidak lagi
// mentok di riwayat pesanan, yang tersisa dari pesanan tidak menunjuk ke
// pemesannya, dokumen KTP/SIM/STNK ikut lenyap dari disk, dan saldo yang bisa
// dicairkan tidak hangus diam-diam.
func TestHapusAkunLewatAdmin(t *testing.T) {
	bukaDBTes(t)
	const rider, driver = "+62800000700", "+62800000701"
	penggunaUji(t, driver)
	oid := pesananUji(t, rider, "cash", "completed", 10000)

	berkasUji := func() string {
		os.MkdirAll("uploads", os.ModePerm)
		nama := newID("f") + ".jpg"
		if err := os.WriteFile(filepath.Join("uploads", nama), []byte{0xFF, 0xD8, 0xFF}, 0o644); err != nil {
			t.Fatalf("gagal menyiapkan berkas: %v", err)
		}
		t.Cleanup(func() { os.Remove(filepath.Join("uploads", nama)) })
		return "/uploads/" + nama
	}
	ada := func(url string) bool {
		_, err := os.Stat(filepath.Join("uploads", filepath.Base(url)))
		return err == nil
	}

	bukti, ktp := berkasUji(), berkasUji()
	db.Exec(`UPDATE orders SET driver_phone = ?, receiver_name = 'Ibu Penerima', receiver_phone = '+6281111',
		delivery_photo_url = ? WHERE id = ?`, driver, bukti, oid)
	db.Exec("INSERT INTO order_ratings (order_id, driver_phone, rider_phone, stars, created_at) VALUES (?, ?, ?, 5, NOW())", oid, driver, rider)
	db.Exec("INSERT INTO driver_applications (id, phone_number, ktp_photo_url, status, created_at) VALUES (?, ?, ?, 'approved', NOW())", newID("app"), rider, ktp)
	db.Exec("INSERT INTO partner_applications (id, type, phone_number, ktp_number, created_at) VALUES (?, 'food', ?, '6101', NOW())", newID("pa"), rider)
	t.Cleanup(func() {
		db.Exec("DELETE FROM driver_applications WHERE phone_number = ?", rider)
		db.Exec("DELETE FROM partner_applications WHERE phone_number = ?", rider)
		db.Exec("DELETE FROM pencairan_saldo WHERE phone_number = ?", driver)
	})

	hapus := func(phone string) int {
		r := httptest.NewRequest(http.MethodDelete, "/api/admin/users/"+phone[1:], nil)
		w := httptest.NewRecorder()
		adminUserDetailHandler(w, r.WithContext(context.WithValue(r.Context(), ctxPhone, "+62800000799")))
		return w.Code
	}

	// Driver dengan pendapatan yang belum dicairkan: ditolak, saldonya utuh.
	db.Exec("UPDATE users SET role = 'driver', balance = 5000 WHERE phone_number = ?", driver)
	if k := hapus(driver); k != 409 {
		t.Fatalf("driver bersaldo 5000 dihapus dengan kode %d, harusnya 409", k)
	}
	// Saldo sudah dipotong untuk pengajuan yang menunggu: tetap ditolak.
	db.Exec("UPDATE users SET balance = 0 WHERE phone_number = ?", driver)
	db.Exec(`INSERT INTO pencairan_saldo (id, phone_number, nama_akun, peran, amount, bank, nomor_rekening, nama_pemilik, created_at)
		VALUES (?, ?, 'Uji', 'driver', 5000, 'BRI', '1', 'Uji', NOW())`, newID("cair"), driver)
	if k := hapus(driver); k != 409 {
		t.Fatalf("driver dengan pencairan menunggu dihapus dengan kode %d, harusnya 409", k)
	}

	// Penumpang yang punya riwayat pesanan: dulu 409 dari foreign key.
	if k := hapus(rider); k != 200 {
		t.Fatalf("hapus penumpang lewat admin dibalas %d, harusnya 200", k)
	}
	if _, masih := dbGetUser(rider); masih {
		t.Fatal("baris users penumpang masih ada")
	}

	var riderPhone, ratingRider *string
	var pickup, penerima, foto string
	var lat float64
	if err := db.QueryRow("SELECT rider_phone, pickup, pickup_lat, receiver_name, delivery_photo_url FROM orders WHERE id = ?", oid).
		Scan(&riderPhone, &pickup, &lat, &penerima, &foto); err != nil {
		t.Fatalf("pesanan ikut hilang, padahal dibutuhkan untuk pembukuan: %v", err)
	}
	if riderPhone != nil || pickup != "" || lat != 0 || penerima != "" || foto != "" {
		t.Fatalf("pesanan masih menunjuk pemesannya: phone=%v pickup=%q lat=%v penerima=%q foto=%q", riderPhone, pickup, lat, penerima, foto)
	}
	db.QueryRow("SELECT rider_phone FROM order_ratings WHERE order_id = ?", oid).Scan(&ratingRider)
	if ratingRider != nil {
		t.Fatal("penilaian masih menyimpan nomor penumpang")
	}
	var sisaPengajuan int
	db.QueryRow("SELECT (SELECT COUNT(*) FROM driver_applications WHERE phone_number = ?) + (SELECT COUNT(*) FROM partner_applications WHERE phone_number = ?)", rider, rider).Scan(&sisaPengajuan)
	if sisaPengajuan != 0 {
		t.Fatalf("%d pengajuan berisi nomor KTP tertinggal", sisaPengajuan)
	}
	if ada(ktp) || ada(bukti) {
		t.Fatalf("berkas tertinggal di disk: ktp=%v bukti=%v", ada(ktp), ada(bukti))
	}
}
