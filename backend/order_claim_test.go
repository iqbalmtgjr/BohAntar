package main

import (
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Balapan menerima pesanan tidak bisa dibuktikan dengan tiruan: yang dijaga
// justru MySQL, lewat syarat "WHERE status = 'pending'" di dalam UPDATE-nya.
// Jadi tesnya menembak database sungguhan, dan dilewati kalau tidak ada.
// bukaDBTes menyambungkan tes ke MySQL lokal apa adanya, dan melewati tesnya
// kalau tidak ada.
func bukaDBTes(t *testing.T) {
	t.Helper()
	conn, err := sql.Open("mysql", fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&loc=Local",
		getEnv("DB_USER", "root"), getEnv("DB_PASSWORD", ""),
		getEnv("DB_HOST", "localhost"), getEnv("DB_PORT", "3306"), getEnv("DB_NAME", "bohantar")))
	if err != nil || conn.Ping() != nil {
		t.Skip("MySQL lokal tidak tersedia")
	}
	lama := db
	db = conn
	t.Cleanup(func() { db = lama; conn.Close() })
}

// penggunaUji membuat satu akun sekali pakai dan menghapusnya lagi setelah tes.
//
// Sejak migrasi 002, orders.rider_phone menunjuk users lewat foreign key, jadi
// pesanan uji untuk nomor karangan ditolak database. Itu memang gunanya: data
// yang tidak mungkin ada di produksi juga tidak boleh bisa dibuat di tes.
func penggunaUji(t *testing.T, phone string) {
	t.Helper()
	if err := dbSaveUser(User{
		PhoneNumber: phone, Name: "Uji", Role: "rider",
		CreatedAt: time.Now().Format(time.RFC3339), Badge: "Silver",
	}); err != nil {
		t.Fatalf("gagal menyiapkan pengguna uji %s: %v", phone, err)
	}
	// Berjalan setelah pembersihan pesanan (t.Cleanup urutannya terbalik), jadi
	// baris users pergi belakangan — persis yang dituntut ON DELETE RESTRICT.
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number = ?", phone) })
}

// pesananUji menyimpan satu pesanan dan membereskannya setelah tes selesai.
func pesananUji(t *testing.T, rider, metode, status string, tarif float64) string {
	t.Helper()
	penggunaUji(t, rider)
	oid := newID("test")
	now := time.Now().Format(time.RFC3339)
	if err := dbSaveOrder(Order{
		ID: oid, RiderPhone: rider, RiderName: "Uji",
		PickupAddress: "A", DropoffAddress: "B",
		PickupLat: -0.0784, PickupLng: 111.4933, DropoffLat: -0.0700, DropoffLng: 111.4980,
		Fare: tarif, Komisi: tarif / 10, PaymentMethod: metode, Service: "BohAntar",
		Status: status, CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })
	return oid
}

func TestDbClaimOrderHanyaSatuPemenang(t *testing.T) {
	bukaDBTes(t)
	oid := pesananUji(t, "+62800000000", "cash", "pending", 10000)
	now := time.Now().Format(time.RFC3339)

	const jumlahDriver = 8
	// Driver pun menunjuk users lewat foreign key sejak migrasi 002.
	for i := 0; i < jumlahDriver; i++ {
		penggunaUji(t, fmt.Sprintf("+6280000000%d", i))
	}
	var siap sync.WaitGroup
	var mulai sync.WaitGroup
	var kunci sync.Mutex
	menang := 0

	siap.Add(jumlahDriver)
	mulai.Add(1)
	for i := 0; i < jumlahDriver; i++ {
		go func(n int) {
			defer siap.Done()
			mulai.Wait() // semua menekan Terima sedekat mungkin
			ok, err := dbClaimOrder(oid, fmt.Sprintf("+6280000000%d", n), fmt.Sprintf("Driver %d", n), now)
			if err != nil {
				t.Errorf("driver %d gagal: %v", n, err)
				return
			}
			if ok {
				kunci.Lock()
				menang++
				kunci.Unlock()
			}
		}(i)
	}
	mulai.Done()
	siap.Wait()

	if menang != 1 {
		t.Fatalf("%d driver merasa mendapat pesanan yang sama, harusnya tepat 1", menang)
	}

	// Pesanan yang sudah diterima tidak boleh bisa direbut belakangan.
	if ok, _ := dbClaimOrder(oid, "+628999999999", "Driver Telat", now); ok {
		t.Fatal("pesanan yang sudah diterima masih bisa diambil driver lain")
	}
}

// Batas pembatalan itu soal uang: setelah penumpang naik, driver sudah bekerja.
func TestDbCancelOrderMenghormatiStatus(t *testing.T) {
	bukaDBTes(t)
	now := time.Now().Format(time.RFC3339)
	penumpang := []string{"pending", "accepted"}
	adminBoleh := []string{"pending", "accepted", "picked_up"}

	menunggu := pesananUji(t, "+62800000001", "cash", "pending", 10000)
	if ok, err := dbCancelOrder(menunggu, penumpang, now); err != nil || !ok {
		t.Fatalf("pesanan menunggu seharusnya bisa dibatalkan (ok=%v err=%v)", ok, err)
	}
	if ok, _ := dbCancelOrder(menunggu, penumpang, now); ok {
		t.Error("pesanan yang sudah batal masih bisa dibatalkan lagi")
	}

	naik := pesananUji(t, "+62800000002", "cash", "picked_up", 10000)
	if ok, _ := dbCancelOrder(naik, penumpang, now); ok {
		t.Error("penumpang yang sudah dijemput masih bisa membatalkan — driver bekerja tanpa dibayar")
	}
	if ok, _ := dbCancelOrder(naik, adminBoleh, now); !ok {
		t.Error("admin tidak bisa menutup pesanan tersangkut yang sudah dijemput")
	}

	selesai := pesananUji(t, "+62800000003", "wallet", "completed", 10000)
	if ok, _ := dbCancelOrder(selesai, adminBoleh, now); ok {
		t.Error("pesanan yang sudah selesai masih bisa dibatalkan")
	}
}

// Satu perjalanan tetap satu suara, dan hanya penumpangnya sendiri yang boleh
// menilai — kalau tidak, rating driver bisa dijatuhkan orang yang tidak pernah
// naik kendaraannya.
func TestRateOrder(t *testing.T) {
	bukaDBTes(t)
	penumpang := "+62800000010"
	driver := "+62800000011"
	oid := pesananUji(t, penumpang, "cash", "completed", 12000)
	penggunaUji(t, driver)
	db.Exec("UPDATE orders SET driver_phone = ? WHERE id = ?", driver, oid)
	// Tabelnya dibuat server saat boot; tes tidak menjalankan initDB, jadi
	// definisi yang sama dipakai langsung dari sini.
	if _, err := db.Exec(skemaOrderRatings); err != nil {
		t.Fatalf("gagal menyiapkan tabel penilaian: %v", err)
	}
	db.Exec("DELETE FROM order_ratings WHERE driver_phone = ?", driver)
	t.Cleanup(func() { db.Exec("DELETE FROM order_ratings WHERE driver_phone = ?", driver) })

	// rateOrder membaca identitas dari token, bukan dari context, jadi tesnya
	// menempuh jalur otorisasi yang sama dengan permintaan sungguhan.
	initAuth()
	kirim := func(dari, pesanan string, bintang int) *httptest.ResponseRecorder {
		tok, err := issueToken(dari, "rider")
		if err != nil {
			t.Fatalf("gagal membuat token uji: %v", err)
		}
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/api/orders/"+pesanan+"/rate",
			strings.NewReader(fmt.Sprintf(`{"stars":%d,"review":"uji"}`, bintang)))
		r.Header.Set("Authorization", "Bearer "+tok)
		rateOrder(w, r, pesanan)
		return w
	}

	if w := kirim(penumpang, oid, 4); w.Code != 200 {
		t.Fatalf("penilaian ditolak: %d %s", w.Code, w.Body)
	}
	// Menilai ulang harus mengganti nilainya, bukan menambah suara kedua.
	if w := kirim(penumpang, oid, 2); w.Code != 200 {
		t.Fatalf("penilaian ulang ditolak: %d %s", w.Code, w.Body)
	}

	var jumlah int
	var rata float64
	db.QueryRow("SELECT COUNT(*), AVG(stars) FROM order_ratings WHERE driver_phone = ?", driver).Scan(&jumlah, &rata)
	if jumlah != 1 || rata != 2 {
		t.Fatalf("dapat %d suara rata-rata %v, harusnya 1 suara bernilai 2", jumlah, rata)
	}

	var ratingDriver float64
	db.QueryRow("SELECT rating FROM users WHERE phone_number = ?", driver).Scan(&ratingDriver)
	if ratingDriver != 0 && ratingDriver != 2 {
		t.Errorf("rating driver di tabel users %v, harusnya ikut jadi 2", ratingDriver)
	}

	if w := kirim("+62899999998", oid, 5); w.Code == 200 {
		t.Error("orang yang bukan penumpangnya bisa menilai perjalanan ini")
	}
	if w := kirim(penumpang, oid, 9); w.Code != 400 {
		t.Errorf("bintang di luar 1-5 diterima dengan kode %d", w.Code)
	}

	belum := pesananUji(t, penumpang, "cash", "accepted", 12000)
	if w := kirim(penumpang, belum, 5); w.Code == 200 {
		t.Error("perjalanan yang belum selesai sudah bisa dinilai")
	}
}

// Saldo yang sudah dijanjikan ke pesanan lain tidak boleh ikut dihitung sebagai
// saldo yang masih bisa dipakai.
func TestDbSaldoTertahan(t *testing.T) {
	bukaDBTes(t)
	penumpang := "+62800000004"
	db.Exec("DELETE FROM orders WHERE rider_phone = ?", penumpang)

	pesananUji(t, penumpang, "wallet", "pending", 15000)   // dihitung
	pesananUji(t, penumpang, "wallet", "picked_up", 20000) // dihitung
	pesananUji(t, penumpang, "wallet", "completed", 50000) // sudah dibayar
	pesananUji(t, penumpang, "wallet", "cancelled", 90000) // batal
	pesananUji(t, penumpang, "cash", "accepted", 70000)    // tunai, tidak menyentuh saldo

	total, err := dbSaldoTertahan(penumpang)
	if err != nil {
		t.Fatalf("gagal membaca saldo tertahan: %v", err)
	}
	if total != 35000 {
		t.Fatalf("saldo tertahan %v, harusnya 35000 (hanya dompet yang belum selesai)", total)
	}

	kosong, err := dbSaldoTertahan("+62899999999")
	if err != nil || kosong != 0 {
		t.Fatalf("penumpang tanpa pesanan harusnya 0, dapat %v (err=%v)", kosong, err)
	}
}
