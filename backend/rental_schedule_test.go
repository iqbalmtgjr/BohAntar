package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// connectTestDB memakai MySQL lokal apa adanya; tes dilewati kalau tidak ada.
func connectTestDB(t *testing.T) (carID string, as func(method, path, body string) *http.Request) {
	t.Helper()
	conn, err := sql.Open("mysql", fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&loc=Local",
		getEnv("DB_USER", "root"), getEnv("DB_PASSWORD", ""),
		getEnv("DB_HOST", "localhost"), getEnv("DB_PORT", "3306"), getEnv("DB_NAME", "bohantar")))
	if err != nil || conn.Ping() != nil {
		t.Skip("MySQL lokal tidak tersedia")
	}
	old := db
	db = conn
	t.Cleanup(func() { db = old; conn.Close() })

	// Kendaraan yang dipakai harus bebas dari jadwal/pesanan yang masih hidup,
	// supaya hasil tes tidak tergantung isi database saat itu.
	var owner string
	err = db.QueryRow(`
		SELECT c.id, c.owner_phone FROM rental_cars c
		WHERE NOT EXISTS (
			SELECT 1 FROM rental_car_schedules s
			WHERE s.car_id = c.id AND COALESCE(s.status, 'active') <> 'completed'
		) AND NOT EXISTS (
			SELECT 1 FROM rental_bookings b
			WHERE b.car_id = c.id AND b.status NOT IN ('cancelled', 'rejected', 'completed')
		)
		LIMIT 1`).Scan(&carID, &owner)
	if err != nil {
		t.Skip("tidak ada kendaraan bebas untuk diuji")
	}

	return carID, func(method, path, body string) *http.Request {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		ctx := context.WithValue(r.Context(), ctxPhone, owner)
		return r.WithContext(context.WithValue(ctx, ctxRole, "rental_partner"))
	}
}

// Menutup jadwal lewat PUT {"status":"completed"} tidak boleh menghapus barisnya
// (Laporan membacanya sebagai riwayat), tapi armadanya harus langsung bebas dipesan.
func TestScheduleCompleteKeepsRowAndFreesCar(t *testing.T) {
	carID, as := connectTestDB(t)

	start := time.Now().Add(300 * 24 * time.Hour).Format("2006-01-02 15:04:05")
	end := time.Now().Add(303 * 24 * time.Hour).Format("2006-01-02 15:04:05")
	payload := fmt.Sprintf(`{"car_id":%q,"start_time":%q,"end_time":%q,"reason":"Booking - Customer: Uji (0800) | Pembayaran: Tunai | Tipe: Full"}`, carID, start, end)

	w := httptest.NewRecorder()
	rentalSchedulesHandler(w, as(http.MethodPost, "/api/rental/schedules", payload))
	if w.Code != 200 {
		t.Fatalf("POST jadwal gagal: %d %s", w.Code, w.Body)
	}
	var created RentalCarSchedule
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatalf("respons POST tidak terbaca: %v", err)
	}
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", created.ID)

	if created.Status != "active" {
		t.Errorf("jadwal baru harusnya active, dapat %q", created.Status)
	}

	// Rentang yang sama harus ditolak selama jadwal masih aktif.
	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(http.MethodPost, "/api/rental/schedules", payload))
	if w.Code != 409 {
		db.Exec("DELETE FROM rental_car_schedules WHERE id != ? AND car_id = ? AND start_time = ?", created.ID, carID, start)
		t.Fatalf("jadwal bertabrakan harusnya ditolak 409, dapat %d %s", w.Code, w.Body)
	}

	w = httptest.NewRecorder()
	rentalScheduleDetailHandler(w, as(http.MethodPut, "/api/rental/schedules/"+created.ID, `{"status":"completed"}`))
	if w.Code != 200 {
		t.Fatalf("PUT status gagal: %d %s", w.Code, w.Body)
	}

	// Barisnya tetap ada sebagai riwayat untuk Laporan.
	var status string
	if err := db.QueryRow("SELECT status FROM rental_car_schedules WHERE id = ?", created.ID).Scan(&status); err != nil {
		t.Fatalf("jadwal selesai malah hilang dari database: %v", err)
	}
	if status != "completed" {
		t.Errorf("status jadwal = %q, mau completed", status)
	}

	// Dan armadanya sudah bebas: rentang yang sama boleh dipakai lagi.
	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(http.MethodPost, "/api/rental/schedules", payload))
	if w.Code != 200 {
		t.Fatalf("armada masih terkunci setelah jadwal selesai: %d %s", w.Code, w.Body)
	}
	var second RentalCarSchedule
	json.Unmarshal(w.Body.Bytes(), &second)
	db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", second.ID)
}

// Penyewa yang telat mengembalikan kendaraan: jadwalnya sudah lewat jatuh tempo
// tapi belum ditutup, jadi armadanya harus tetap terkunci sampai ditandai selesai.
func TestOverdueScheduleStillBlocksCar(t *testing.T) {
	carID, as := connectTestDB(t)

	// Jatuh tempo sejam lalu, statusnya masih active — mobil belum kembali.
	lewat := RentalCarSchedule{
		ID:        newID("schedule"),
		CarID:     carID,
		StartTime: time.Now().Add(-12 * time.Hour).Format("2006-01-02 15:04:05"),
		EndTime:   time.Now().Add(-time.Hour).Format("2006-01-02 15:04:05"),
		Reason:    "Booking - Customer: Telat (0800) | Pembayaran: Tunai | Tipe: Full",
	}
	if _, err := db.Exec("INSERT INTO rental_car_schedules (id, car_id, start_time, end_time, reason, status, created_at) VALUES (?, ?, ?, ?, ?, 'active', ?)",
		lewat.ID, lewat.CarID, lewat.StartTime, lewat.EndTime, lewat.Reason, time.Now().Format(time.RFC3339)); err != nil {
		t.Fatalf("gagal menyiapkan jadwal telat: %v", err)
	}
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", lewat.ID)

	// Menjadwalkan mobil yang sama mulai sekarang harus ditolak.
	baru := fmt.Sprintf(`{"car_id":%q,"start_time":%q,"end_time":%q,"reason":"Servis"}`,
		carID,
		time.Now().Format("2006-01-02 15:04:05"),
		time.Now().Add(4*time.Hour).Format("2006-01-02 15:04:05"))

	w := httptest.NewRecorder()
	rentalSchedulesHandler(w, as(http.MethodPost, "/api/rental/schedules", baru))
	if w.Code != 409 {
		db.Exec("DELETE FROM rental_car_schedules WHERE car_id = ? AND reason = 'Servis'", carID)
		t.Fatalf("kendaraan yang telat kembali masih bisa dijadwalkan: %d %s", w.Code, w.Body)
	}

	// Tapi mitra tetap boleh mencatat booking untuk hari berikutnya (masukan
	// mitra 9 Nov: "harus di input dulu agar tidak lupa").
	besok := fmt.Sprintf(`{"car_id":%q,"start_time":%q,"end_time":%q,"reason":"Booking - Customer: Besok (0800) | Pembayaran: Tunai | Tipe: Full"}`,
		carID,
		time.Now().Add(24*time.Hour).Format("2006-01-02 15:04:05"),
		time.Now().Add(48*time.Hour).Format("2006-01-02 15:04:05"))
	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(http.MethodPost, "/api/rental/schedules", besok))
	if w.Code != 200 {
		t.Fatalf("booking besok untuk mobil yang belum kembali ditolak: %d %s", w.Code, w.Body)
	}
	var booking RentalCarSchedule
	json.Unmarshal(w.Body.Bytes(), &booking)
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", booking.ID)

	// Setelah ditandai selesai, armadanya baru bebas.
	w = httptest.NewRecorder()
	rentalScheduleDetailHandler(w, as(http.MethodPut, "/api/rental/schedules/"+lewat.ID, `{"status":"completed"}`))
	if w.Code != 200 {
		t.Fatalf("PUT status gagal: %d %s", w.Code, w.Body)
	}

	w = httptest.NewRecorder()
	rentalSchedulesHandler(w, as(http.MethodPost, "/api/rental/schedules", baru))
	if w.Code != 200 {
		t.Fatalf("armada masih terkunci padahal jadwalnya sudah selesai: %d %s", w.Code, w.Body)
	}
	var lanjutan RentalCarSchedule
	json.Unmarshal(w.Body.Bytes(), &lanjutan)
	db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", lanjutan.ID)
}

// Denda keterlambatan memakai aturan milik pemilik armada dan dikunci saat sewa
// ditutup, bukan dihitung ulang tiap laporan dibuka.
func TestLateFeeLockedOnCompletion(t *testing.T) {
	carID, as := connectTestDB(t)

	var owner string
	var pricePerDay float64
	if err := db.QueryRow("SELECT owner_phone, price_per_day FROM rental_cars WHERE id = ?", carID).Scan(&owner, &pricePerDay); err != nil {
		t.Fatalf("data mobil tidak terbaca: %v", err)
	}

	// Aturan mitra lain tidak boleh ikut terpakai.
	var lain string
	if db.QueryRow("SELECT phone_number FROM users WHERE role = 'rental_partner' AND phone_number <> ? LIMIT 1", owner).Scan(&lain) == nil {
		db.Exec("INSERT INTO rental_settings (owner_phone, late_fee_mode, late_fee_value, updated_at) VALUES (?, 'amount', 999999, ?) ON DUPLICATE KEY UPDATE late_fee_mode = 'amount', late_fee_value = 999999", lain, time.Now().Format(time.RFC3339))
		defer db.Exec("DELETE FROM rental_settings WHERE owner_phone = ?", lain)
	}

	simpanAturan := func(mode string, nilai float64, toleransi int) {
		if _, err := db.Exec(`INSERT INTO rental_settings (owner_phone, late_fee_mode, late_fee_value, late_fee_grace_minutes, updated_at) VALUES (?, ?, ?, ?, ?)
			ON DUPLICATE KEY UPDATE late_fee_mode = VALUES(late_fee_mode), late_fee_value = VALUES(late_fee_value), late_fee_grace_minutes = VALUES(late_fee_grace_minutes)`,
			owner, mode, nilai, toleransi, time.Now().Format(time.RFC3339)); err != nil {
			t.Fatalf("gagal menyimpan aturan denda: %v", err)
		}
	}
	var aturanLama RentalSettings
	adaAturanLama := db.QueryRow("SELECT late_fee_mode, late_fee_value, COALESCE(late_fee_grace_minutes, 0) FROM rental_settings WHERE owner_phone = ?", owner).
		Scan(&aturanLama.LateFeeMode, &aturanLama.LateFeeVal, &aturanLama.GraceMinutes) == nil
	defer func() {
		if adaAturanLama {
			simpanAturan(aturanLama.LateFeeMode, aturanLama.LateFeeVal, aturanLama.GraceMinutes)
		} else {
			db.Exec("DELETE FROM rental_settings WHERE owner_phone = ?", owner)
		}
	}()

	// Jadwal yang jatuh temponya lewat sekian menit lalu.
	buatJadwalTelatMenit := func(menit int) string {
		id := newID("schedule")
		if _, err := db.Exec("INSERT INTO rental_car_schedules (id, car_id, start_time, end_time, reason, status, late_fee, created_at) VALUES (?, ?, ?, ?, 'Booking - Customer: Telat (0800) | Pembayaran: Tunai | Tipe: Full', 'active', 0, ?)",
			id, carID, time.Now().Add(-72*time.Hour).Format("2006-01-02 15:04:05"),
			time.Now().Add(-time.Duration(menit)*time.Minute).Format("2006-01-02 15:04:05"), time.Now().Format(time.RFC3339)); err != nil {
			t.Fatalf("gagal menyiapkan jadwal telat: %v", err)
		}
		return id
	}

	// Jatuh tempo 25 jam lalu -> 2 hari telat setelah pembulatan ke atas.
	buatJadwalTelat := func() string { return buatJadwalTelatMenit(25 * 60) }

	tutup := func(id string) float64 {
		w := httptest.NewRecorder()
		rentalScheduleDetailHandler(w, as(http.MethodPut, "/api/rental/schedules/"+id, `{"status":"completed"}`))
		if w.Code != 200 {
			t.Fatalf("gagal menutup jadwal: %d %s", w.Code, w.Body)
		}
		var tersimpan float64
		if err := db.QueryRow("SELECT late_fee FROM rental_car_schedules WHERE id = ?", id).Scan(&tersimpan); err != nil {
			t.Fatalf("denda tidak tersimpan: %v", err)
		}
		return tersimpan
	}

	// Mode nominal: 2 hari telat x Rp 50.000.
	simpanAturan("amount", 50000, 0)
	id := buatJadwalTelat()
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", id)
	if got := tutup(id); got != 100000 {
		t.Errorf("denda nominal = %v, mau 100000", got)
	}

	// Mode persen: 2 hari telat x 10% tarif harian.
	simpanAturan("percent", 10, 0)
	id2 := buatJadwalTelat()
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", id2)
	if got, mau := tutup(id2), 2*pricePerDay*0.1; got != mau {
		t.Errorf("denda persen = %v, mau %v", got, mau)
	}

	// Dimatikan: tidak ada denda meski telat.
	simpanAturan("off", 0, 0)
	id3 := buatJadwalTelat()
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", id3)
	if got := tutup(id3); got != 0 {
		t.Errorf("denda saat mode off = %v, mau 0", got)
	}

	// Toleransi 1 jam: telat 30 menit masih gratis, telat 90 menit kena 1 hari.
	simpanAturan("amount", 50000, 60)
	dalamToleransi := buatJadwalTelatMenit(30)
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", dalamToleransi)
	if got := tutup(dalamToleransi); got != 0 {
		t.Errorf("telat 30 menit dengan toleransi 1 jam = %v, mau 0", got)
	}
	lewatToleransi := buatJadwalTelatMenit(90)
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", lewatToleransi)
	if got := tutup(lewatToleransi); got != 50000 {
		t.Errorf("telat 90 menit dengan toleransi 1 jam = %v, mau 50000", got)
	}

	// Toleransi memundurkan titik hitung, bukan sekadar ambang: telat 25 jam
	// dengan toleransi 3 jam berarti 22 jam terhitung -> 1 hari, bukan 2.
	simpanAturan("amount", 50000, 180)
	toleransiMemundurkan := buatJadwalTelatMenit(25 * 60)
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", toleransiMemundurkan)
	if got := tutup(toleransiMemundurkan); got != 50000 {
		t.Errorf("telat 25 jam dengan toleransi 3 jam = %v, mau 50000", got)
	}

	// Selesai tepat waktu tidak kena denda apa pun.
	simpanAturan("amount", 50000, 0)
	tepatWaktu := newID("schedule")
	db.Exec("INSERT INTO rental_car_schedules (id, car_id, start_time, end_time, reason, status, late_fee, created_at) VALUES (?, ?, ?, ?, 'Servis', 'active', 0, ?)",
		tepatWaktu, carID, time.Now().Add(-time.Hour).Format("2006-01-02 15:04:05"),
		time.Now().Add(6*time.Hour).Format("2006-01-02 15:04:05"), time.Now().Format(time.RFC3339))
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", tepatWaktu)
	if got := tutup(tepatWaktu); got != 0 {
		t.Errorf("denda untuk sewa tepat waktu = %v, mau 0", got)
	}
}

// Tandai Lunas: hanya pemilik armada, metode & nominal divalidasi, tercatat di
// daftar jadwal (dasar dashboard menerbitkan kuitansi), dan bisa dibatalkan.
func TestTandaiLunasJadwalManual(t *testing.T) {
	carID, as := connectTestDB(t)
	migrasiPelunasan()

	s := RentalCarSchedule{
		ID: newID("schedule"), CarID: carID,
		StartTime: time.Now().Add(400 * 24 * time.Hour).Format("2006-01-02 15:04:05"),
		EndTime:   time.Now().Add(402 * 24 * time.Hour).Format("2006-01-02 15:04:05"),
		Reason:    "Booking - Customer: Lunas (0800) | Pembayaran: Tunai | Tipe: DP | Nominal DP: 100000",
	}
	if _, err := db.Exec("INSERT INTO rental_car_schedules (id, car_id, start_time, end_time, reason, status, created_at) VALUES (?, ?, ?, ?, ?, 'active', ?)",
		s.ID, s.CarID, s.StartTime, s.EndTime, s.Reason, time.Now()); err != nil {
		t.Fatalf("gagal menyiapkan jadwal: %v", err)
	}
	defer db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", s.ID)

	lunas := func(req *http.Request) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		rentalLunasHandler(w, req)
		return w
	}
	kemarin := time.Now().Add(-24 * time.Hour).Format("2006-01-02 15:04:05")
	body := fmt.Sprintf(`{"sumber":"manual","id":%q,"waktu":%q,"metode":"Transfer","nominal":700000}`, s.ID, kemarin)

	// Orang lain (penyewa, mitra lain) tidak boleh menyatakan uangnya diterima.
	orangLain := httptest.NewRequest(http.MethodPut, "/api/rental/lunas", strings.NewReader(body))
	orangLain = orangLain.WithContext(context.WithValue(context.WithValue(orangLain.Context(), ctxPhone, "+62800000000"), ctxRole, "rental_partner"))
	if w := lunas(orangLain); w.Code != 403 {
		t.Fatalf("bukan pemilik bisa menandai lunas: %d %s", w.Code, w.Body)
	}
	if w := lunas(as(http.MethodPut, "/api/rental/lunas", strings.Replace(body, "Transfer", "Ngutang", 1))); w.Code != 400 {
		t.Errorf("metode asing diterima: %d", w.Code)
	}
	if w := lunas(as(http.MethodPut, "/api/rental/lunas", strings.Replace(body, "700000", "0", 1))); w.Code != 400 {
		t.Errorf("nominal 0 diterima: %d", w.Code)
	}

	if w := lunas(as(http.MethodPut, "/api/rental/lunas", body)); w.Code != 200 {
		t.Fatalf("tandai lunas gagal: %d %s", w.Code, w.Body)
	}
	cari := func() RentalCarSchedule {
		w := httptest.NewRecorder()
		rentalSchedulesHandler(w, as(http.MethodGet, "/api/rental/schedules?car_id="+carID, ""))
		var semua []RentalCarSchedule
		json.Unmarshal(w.Body.Bytes(), &semua)
		for _, x := range semua {
			if x.ID == s.ID {
				return x
			}
		}
		t.Fatalf("jadwal uji tidak ada di daftar: %s", w.Body)
		return RentalCarSchedule{}
	}
	if got := cari(); got.LunasAt != kemarin || got.LunasNominal != 700000 || got.LunasMetode != "Transfer" {
		t.Errorf("pelunasan tersimpan salah: %+v", got.Pelunasan)
	}

	if w := lunas(as(http.MethodPut, "/api/rental/lunas", fmt.Sprintf(`{"sumber":"manual","id":%q,"batal":true}`, s.ID))); w.Code != 200 {
		t.Fatalf("batal lunas gagal: %d %s", w.Code, w.Body)
	}
	if got := cari(); got.LunasAt != "" || got.LunasNominal != 0 {
		t.Errorf("pelunasan tidak terhapus: %+v", got.Pelunasan)
	}
}

// Perpanjangan manual oleh super admin sampai tanggal pilihan (dashboard yang
// menghitung tanggalnya dari jumlah bulan); tercatat MANUAL di laporan.
func TestPerpanjangLanggananManual(t *testing.T) {
	carID, _ := connectTestDB(t)
	migrasiPelunasan()
	var mitra string
	if err := db.QueryRow("SELECT owner_phone FROM rental_cars WHERE id = ?", carID).Scan(&mitra); err != nil {
		t.Skip("pemilik kendaraan uji tidak ditemukan")
	}

	// Simpan langganan aslinya, kembalikan setelah tes.
	var asliStatus string
	var asliSampai sql.NullTime
	adaAsli := db.QueryRow("SELECT status, valid_until FROM partner_subscriptions WHERE phone_number = ?", mitra).Scan(&asliStatus, &asliSampai) == nil
	t.Cleanup(func() {
		if adaAsli {
			db.Exec("UPDATE partner_subscriptions SET status = ?, valid_until = ? WHERE phone_number = ?", asliStatus, asliSampai, mitra)
		} else {
			db.Exec("DELETE FROM partner_subscriptions WHERE phone_number = ?", mitra)
		}
		db.Exec("DELETE FROM subscription_invoices WHERE phone_number = ? AND status = 'MANUAL' AND catatan LIKE 'uji-perpanjang%'", mitra)
	})
	setSampai := func(t0 time.Time) {
		db.Exec(`INSERT INTO partner_subscriptions (phone_number, status, valid_until, updated_at) VALUES (?, 'ACTIVE', ?, NOW())
			ON DUPLICATE KEY UPDATE valid_until = ?`, mitra, t0, t0)
	}
	adminReq := func(body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/api/admin/rental/langganan", strings.NewReader(body))
		r = r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, "+62800admin"), ctxRole, "admin"))
		w := httptest.NewRecorder()
		adminLanggananRentalHandler(w, r)
		return w
	}
	sampai := func() time.Time {
		var vu time.Time
		db.QueryRow("SELECT valid_until FROM partner_subscriptions WHERE phone_number = ?", mitra).Scan(&vu)
		return vu
	}

	// Mitra yang sudah habis diperpanjang sampai tanggal pilihan: berlaku hingga
	// akhir hari itu, status kembali aktif.
	setSampai(time.Now().Add(-10 * 24 * time.Hour))
	tujuan := time.Now().AddDate(0, 2, 7)
	if w := adminReq(fmt.Sprintf(`{"phone_number":%q,"sampai":%q,"nominal":250000,"catatan":"uji-perpanjang transfer"}`, mitra, tujuan.Format("2006-01-02"))); w.Code != 200 {
		t.Fatalf("perpanjang gagal: %d %s", w.Code, w.Body)
	}
	mau := time.Date(tujuan.Year(), tujuan.Month(), tujuan.Day(), 23, 59, 59, 0, time.Local)
	if got := sampai(); !got.Equal(mau) {
		t.Errorf("valid_until = %v, mau %v", got, mau)
	}
	var status string
	db.QueryRow("SELECT status FROM partner_subscriptions WHERE phone_number = ?", mitra).Scan(&status)
	if status != "ACTIVE" {
		t.Errorf("status = %q, mau ACTIVE", status)
	}

	// Tercatat MANUAL di laporan pembayaran beserta nominal dan catatannya.
	var nominal float64
	db.QueryRow("SELECT amount FROM subscription_invoices WHERE phone_number = ? AND status = 'MANUAL' AND catatan = 'uji-perpanjang transfer'", mitra).Scan(&nominal)
	if nominal != 250000 {
		t.Errorf("baris MANUAL di laporan: nominal = %v, mau 250000", nominal)
	}

	// Tanggal yang sudah lewat, terlalu jauh, atau rusak ditolak; begitu juga
	// nomor yang bukan mitra rental.
	besok := time.Now().AddDate(0, 0, 1).Format("2006-01-02")
	for _, salah := range []string{time.Now().AddDate(0, 0, -1).Format("2006-01-02"), time.Now().AddDate(11, 0, 0).Format("2006-01-02"), "31-12-2026", ""} {
		if w := adminReq(fmt.Sprintf(`{"phone_number":%q,"sampai":%q}`, mitra, salah)); w.Code != 400 {
			t.Errorf("tanggal %q diterima: %d", salah, w.Code)
		}
	}
	if w := adminReq(fmt.Sprintf(`{"phone_number":"+62800tidakada","sampai":%q}`, besok)); w.Code != 404 {
		t.Errorf("nomor asing diterima: %d", w.Code)
	}
}

// Kolom created_at tagihan yang masih teks berisi jam lokal tanpa zona; dulu
// dibaca sebagai UTC sehingga dashboard menampilkannya +7 jam.
func TestWaktuInvoiceTeksJamLokal(t *testing.T) {
	mau := time.Date(2026, 11, 9, 1, 26, 14, 0, time.Local).Format(time.RFC3339)
	for _, teks := range []string{"2026-11-09 01:26:14", "2026-11-09 01:26:14.3789168", mau} {
		if got := waktuInvoice(teks); got != mau {
			t.Errorf("waktuInvoice(%q) = %s, mau %s", teks, got, mau)
		}
	}
}
