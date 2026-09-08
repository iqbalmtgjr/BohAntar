package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// permintaanKlaim menyusun permintaan klaim seolah-olah sudah lolos middleware
// requireRole("driver") — nomor pemanggil ditaruh di context, sama seperti yang
// dilakukan requireRole di produksi.
func permintaanKlaim(token, phone string) *http.Request {
	body, _ := json.Marshal(map[string]string{"token": token})
	r := httptest.NewRequest(http.MethodPost, "/api/driver/setoran/klaim", bytes.NewReader(body))
	ctx := context.WithValue(r.Context(), ctxPhone, phone)
	return r.WithContext(context.WithValue(ctx, ctxRole, "driver"))
}

// Setoran memindahkan uang sungguhan ke saldo driver, jadi yang diuji bukan
// "berhasil": satu QR harus mengkredit tepat sekali walau dipindai bersamaan,
// dan QR milik driver lain harus ditolak.
func TestSetoranKomisiSekaliPakai(t *testing.T) {
	bukaDBTes(t)

	stempel := time.Now().Format("150405")
	driver := "+62877" + stempel
	lain := "+62866" + stempel
	penggunaUji(t, driver)
	penggunaUji(t, lain)
	t.Cleanup(func() {
		db.Exec("DELETE FROM setoran_komisi WHERE driver_phone IN (?, ?)", driver, lain)
	})

	// Driver berutang komisi 50.000 dari pesanan tunai.
	for _, p := range []string{driver, lain} {
		if _, err := db.Exec("UPDATE users SET role = 'driver', balance = -50000 WHERE phone_number = ?", p); err != nil {
			t.Fatalf("gagal menyiapkan driver uji: %v", err)
		}
	}

	buat := func(phone string, nominal float64) *httptest.ResponseRecorder {
		body, _ := json.Marshal(map[string]interface{}{"driver_phone": phone, "amount": nominal})
		req := httptest.NewRequest(http.MethodPost, "/api/admin/setoran", bytes.NewReader(body))
		rec := httptest.NewRecorder()
		adminSetoranHandler(rec, req)
		return rec
	}

	// Nominal di atas utangnya ditolak: saldo positif berarti uang muka, dan
	// belum ada jalur penarikannya.
	if rec := buat(driver, 90000); rec.Code != 409 {
		t.Errorf("setoran melebihi utang dibalas %d, harusnya 409", rec.Code)
	}

	rec := buat(driver, 30000)
	if rec.Code != 200 {
		t.Fatalf("gagal membuat setoran: %d %s", rec.Code, rec.Body.String())
	}
	var dibuat struct {
		Setoran struct {
			ID string `json:"id"`
		} `json:"setoran"`
	}
	json.Unmarshal(rec.Body.Bytes(), &dibuat)
	if dibuat.Setoran.ID == "" {
		t.Fatalf("id setoran kosong: %s", rec.Body.String())
	}

	// Delapan pemindaian berbarengan: tepat satu boleh berhasil.
	var siap sync.WaitGroup
	var mulai sync.WaitGroup
	var kunci sync.Mutex
	berhasil := 0
	const jumlahPemindai = 8
	siap.Add(jumlahPemindai)
	mulai.Add(1)
	for i := 0; i < jumlahPemindai; i++ {
		go func() {
			defer siap.Done()
			mulai.Wait()
			rec := httptest.NewRecorder()
			driverKlaimSetoranHandler(rec, permintaanKlaim(awalanQRSetoran+dibuat.Setoran.ID, driver))
			if rec.Code == 200 {
				kunci.Lock()
				berhasil++
				kunci.Unlock()
			}
		}()
	}
	mulai.Done()
	siap.Wait()

	if berhasil != 1 {
		t.Errorf("%d pemindaian berhasil, harusnya tepat 1", berhasil)
	}

	var saldo float64
	db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", driver).Scan(&saldo)
	if saldo != -20000 {
		t.Errorf("saldo driver %v, harusnya -20000 (utang 50.000 dikurangi setoran 30.000)", saldo)
	}

	// QR yang sama di tangan driver lain tidak boleh mengubah apa pun.
	rec2 := buat(lain, 10000)
	if rec2.Code != 200 {
		t.Fatalf("gagal membuat setoran kedua: %d %s", rec2.Code, rec2.Body.String())
	}
	rec3 := httptest.NewRecorder()
	driverKlaimSetoranHandler(rec3, permintaanKlaim(awalanQRSetoran+dibuat.Setoran.ID, lain))
	if rec3.Code != 409 && rec3.Code != 403 {
		t.Errorf("QR driver lain dibalas %d, harusnya 403/409", rec3.Code)
	}
	var saldoLain float64
	db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", lain).Scan(&saldoLain)
	if saldoLain != -50000 {
		t.Errorf("saldo driver lain berubah jadi %v — QR orang lain tidak boleh mengkreditkan apa pun", saldoLain)
	}
}
