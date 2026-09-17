package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// tokenUji menerbitkan token sesi driver untuk dipasang di header Authorization.
func tokenUji(t *testing.T, phone string) string {
	t.Helper()
	tok, err := issueToken(phone, "driver")
	if err != nil {
		t.Fatalf("gagal menerbitkan token uji: %v", err)
	}
	return tok
}

// Saldo tertahan penumpang harus menutup SELURUH yang akan didebit saat pesanan
// ditutup. Biaya jasa pernah tertinggal dari penjumlahan ini, dan akibatnya
// penumpang boleh memesan melebihi saldonya lalu berakhir minus — tanpa ada
// jalur penagihan untuk saldo penumpang yang minus.
func TestSaldoTertahanIkutMenghitungBiayaJasa(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000200"
	penggunaUji(t, phone)

	// Dua pesanan dompet berjalan, masing-masing ongkos 10000 + biaya jasa 1000.
	for i := 0; i < 2; i++ {
		oid := newID("test")
		now := time.Now().Format(time.RFC3339)
		if err := dbSaveOrder(Order{
			ID: oid, RiderPhone: phone, RiderName: "Uji",
			PickupAddress: "A", DropoffAddress: "B",
			PickupLat: -0.0784, PickupLng: 111.4933, DropoffLat: -0.0700, DropoffLng: 111.4980,
			Fare: 10000, Komisi: 2000, BiayaJasa: 1000,
			PaymentMethod: "wallet", Service: "BohRide",
			Status: "pending", CreatedAt: now, UpdatedAt: now,
		}); err != nil {
			t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
		}
		t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })
	}

	tertahan, err := dbSaldoTertahan(phone)
	if err != nil {
		t.Fatalf("gagal membaca saldo tertahan: %v", err)
	}
	// 2 x (10000 ongkos + 1000 biaya jasa). Kalau biaya jasa terlewat, hasilnya
	// 20000 dan penumpang diizinkan memesan melebihi saldonya.
	if tertahan != 22000 {
		t.Fatalf("saldo tertahan %v, harusnya 22000 (ongkos + biaya jasa untuk dua pesanan)", tertahan)
	}
}

// Uang makanan BohFood juga harus ikut tertahan, bersama biaya jasanya.
func TestSaldoTertahanIkutMenghitungUangMakanan(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000201"
	penggunaUji(t, phone)

	oid := newID("test")
	now := time.Now().Format(time.RFC3339)
	if err := dbSaveOrder(Order{
		ID: oid, RiderPhone: phone, RiderName: "Uji",
		PickupAddress: "A", DropoffAddress: "B",
		PickupLat: -0.0784, PickupLng: 111.4933, DropoffLat: -0.0700, DropoffLng: 111.4980,
		Fare: 10000, Komisi: 2000, BiayaJasa: 1000, FoodTotal: 45000,
		PaymentMethod: "wallet", Service: "BohFood",
		Status: "accepted", CreatedAt: now, UpdatedAt: now,
	}); err != nil {
		t.Fatalf("gagal menyiapkan pesanan uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })

	tertahan, err := dbSaldoTertahan(phone)
	if err != nil {
		t.Fatalf("gagal membaca saldo tertahan: %v", err)
	}
	if tertahan != 56000 {
		t.Fatalf("saldo tertahan %v, harusnya 56000 (10000 + 1000 + 45000)", tertahan)
	}
}

// Yang tertahan harus sama persis dengan yang didebit saat pesanan ditutup.
// Kalau dua angka ini berbeda, saldo penumpang pasti melenceng — arah mana pun.
func TestSaldoTertahanSamaDenganYangDidebit(t *testing.T) {
	kasus := []struct{ fare, komisi, biayaJasa, talangan float64 }{
		{10000, 2000, 1000, 0},
		{10000, 2000, 1000, 45000},
		{18000, 1440, 2000, 0},
		{8000, 0, 0, 0},
	}
	for _, k := range kasus {
		debit, _ := bagiPembayaran("wallet", k.fare, k.komisi, k.talangan, k.biayaJasa)
		tertahan := k.fare + k.biayaJasa + k.talangan // rumus yang sama dengan SUM di dbSaldoTertahan
		if debit != tertahan {
			t.Errorf("fare %v biayaJasa %v talangan %v: didebit %v tapi tertahan %v",
				k.fare, k.biayaJasa, k.talangan, debit, tertahan)
		}
	}
}

// Driver yang tidak bisa melanjutkan harus punya jalan melepas pesanan, kalau
// tidak komisinya tertahan selamanya: penyapu kedaluwarsa hanya menyentuh
// pesanan pending, dan yang boleh membatalkan cuma penumpang atau admin.
func TestLepasPesananMengembalikanKePapanOrderan(t *testing.T) {
	bukaDBTes(t)
	const driver = "+62800000202"
	penggunaUji(t, driver)
	oid := pesananUji(t, "+62800000203", "cash", "pending", 10000)

	now := time.Now().Format(time.RFC3339)
	menang, err := dbClaimOrder(oid, driver, "Driver Uji", now)
	if err != nil || !menang {
		t.Fatalf("gagal menyiapkan pesanan yang sudah diterima: menang=%v err=%v", menang, err)
	}

	// Komisi pesanan ini tertahan selama statusnya accepted.
	tertahan, err := dbKomisiTertahan(driver)
	if err != nil {
		t.Fatalf("gagal membaca komisi tertahan: %v", err)
	}
	if tertahan == 0 {
		t.Fatal("komisi pesanan berjalan seharusnya tertahan, dapat 0")
	}

	req := httptest.NewRequest(http.MethodPost, "/api/orders/"+oid+"/lepas", nil)
	req.Header.Set("Authorization", "Bearer "+tokenUji(t, driver))
	rec := httptest.NewRecorder()
	releaseOrder(rec, req, oid)

	if rec.Code != 200 {
		t.Fatalf("lepas ditolak: HTTP %d, body %s", rec.Code, rec.Body.String())
	}

	o, ada := dbGetOrder(oid)
	if !ada {
		t.Fatal("pesanan hilang setelah dilepas")
	}
	if o.Status != "pending" {
		t.Fatalf("status setelah dilepas %q, harusnya pending supaya driver lain bisa mengambil", o.Status)
	}
	if o.DriverPhone != "" {
		t.Fatalf("driver_phone masih terisi %q setelah dilepas", o.DriverPhone)
	}

	// Inti perbaikannya: komisinya tidak lagi menahan saldo driver.
	if tertahan, err := dbKomisiTertahan(driver); err != nil || tertahan != 0 {
		t.Fatalf("komisi masih tertahan %v setelah pesanan dilepas (err %v)", tertahan, err)
	}
}

// Sesudah penumpang atau barangnya diambil, driver sudah memegang sesuatu milik
// orang lain. Melepas di titik itu urusan admin, bukan tombol di aplikasi.
func TestLepasPesananDitolakSesudahDijemput(t *testing.T) {
	bukaDBTes(t)
	const driver = "+62800000204"
	penggunaUji(t, driver)
	oid := pesananUji(t, "+62800000205", "cash", "pending", 10000)

	now := time.Now().Format(time.RFC3339)
	if menang, err := dbClaimOrder(oid, driver, "Driver Uji", now); err != nil || !menang {
		t.Fatalf("gagal menyiapkan pesanan: %v", err)
	}
	if _, err := db.Exec("UPDATE orders SET status = 'picked_up' WHERE id = ?", oid); err != nil {
		t.Fatalf("gagal menyiapkan status picked_up: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/orders/"+oid+"/lepas", nil)
	req.Header.Set("Authorization", "Bearer "+tokenUji(t, driver))
	rec := httptest.NewRecorder()
	releaseOrder(rec, req, oid)

	if rec.Code != 400 {
		t.Fatalf("lepas setelah picked_up dapat HTTP %d, harusnya 400", rec.Code)
	}
	if o, _ := dbGetOrder(oid); o.Status != "picked_up" {
		t.Fatalf("status berubah jadi %q padahal permintaannya ditolak", o.Status)
	}
}

// Pesanan orang lain tidak boleh bisa dilepas.
func TestLepasPesananDriverLainDitolak(t *testing.T) {
	bukaDBTes(t)
	const pemilik = "+62800000206"
	const penyusup = "+62800000207"
	penggunaUji(t, pemilik)
	penggunaUji(t, penyusup)
	oid := pesananUji(t, "+62800000208", "cash", "pending", 10000)

	now := time.Now().Format(time.RFC3339)
	if menang, err := dbClaimOrder(oid, pemilik, "Pemilik", now); err != nil || !menang {
		t.Fatalf("gagal menyiapkan pesanan: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/orders/"+oid+"/lepas", nil)
	req.Header.Set("Authorization", "Bearer "+tokenUji(t, penyusup))
	rec := httptest.NewRecorder()
	releaseOrder(rec, req, oid)

	if rec.Code != 403 {
		t.Fatalf("driver lain dapat HTTP %d, harusnya 403", rec.Code)
	}
	if o, _ := dbGetOrder(oid); o.DriverPhone != pemilik {
		t.Fatalf("pesanan berpindah dari pemiliknya jadi %q", o.DriverPhone)
	}
}

// Top up tanpa kunci Xendit harus menolak terang-terangan di produksi. Versi
// sebelumnya membalas alamat localhost yang rutenya memang tidak didaftarkan di
// produksi — gagal yang membingungkan, plus satu tagihan menggantung di tabel.
func TestTopUpTanpaKunci(t *testing.T) {
	kasus := []struct {
		nama     string
		produksi bool
		kunci    string
		mauTolak bool
	}{
		{"produksi tanpa kunci", true, "", true},
		{"produksi kunci masih mock", true, "mock", true},
		{"produksi kunci sungguhan", true, "xnd_production_abc", false},
		{"lokal tanpa kunci pakai jalur mock", false, "", false},
		{"lokal kunci mock pakai jalur mock", false, "mock", false},
		{"lokal kunci sungguhan", false, "xnd_development_abc", false},
	}
	for _, k := range kasus {
		if got := topUpTanpaKunci(k.produksi, k.kunci); got != k.mauTolak {
			t.Errorf("%s: topUpTanpaKunci(%v, %q) = %v, mau %v", k.nama, k.produksi, k.kunci, got, k.mauTolak)
		}
	}
}
