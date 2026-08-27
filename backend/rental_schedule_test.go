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
