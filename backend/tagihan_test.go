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

// permintaanBayar menyusun pembayaran seolah-olah sudah lolos requireAuth —
// nomor pemanggil ditaruh di context, persis yang dilakukan middleware aslinya.
func permintaanBayar(token, phone string) *http.Request {
	body, _ := json.Marshal(map[string]string{"token": token})
	r := httptest.NewRequest(http.MethodPost, "/api/tagihan/bayar", bytes.NewReader(body))
	ctx := context.WithValue(r.Context(), ctxPhone, phone)
	return r.WithContext(context.WithValue(ctx, ctxRole, "rider"))
}

// Tagihan memindahkan uang sungguhan antar akun, jadi yang diuji bukan
// "berhasil": satu QR harus mendebit tepat sekali walau dipindai bersamaan, dan
// saldo yang tidak cukup harus ditolak sebelum baris tagihannya ikut terpakai.
func TestTagihanQRSekaliBayar(t *testing.T) {
	bukaDBTes(t)

	stempel := time.Now().Format("150405")
	warung := "+62855" + stempel
	penumpang := "+62844" + stempel
	penggunaUji(t, warung)
	penggunaUji(t, penumpang)
	t.Cleanup(func() {
		db.Exec("DELETE FROM tagihan_qr WHERE penerima_phone = ?", warung)
	})

	if _, err := db.Exec("UPDATE users SET role = 'food_merchant' WHERE phone_number = ?", warung); err != nil {
		t.Fatalf("gagal menyiapkan warung uji: %v", err)
	}
	if _, err := db.Exec(
		"INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, created_at) VALUES (?, ?, ?, ?, ?)",
		newID("wrg"), warung, "Warung Uji", "Jl. Uji", waktuKeDB(time.Now().Format(time.RFC3339)),
	); err != nil {
		t.Fatalf("gagal menyiapkan profil warung: %v", err)
	}

	buat := func(nominal float64) *httptest.ResponseRecorder {
		body, _ := json.Marshal(map[string]interface{}{"amount": nominal})
		req := httptest.NewRequest(http.MethodPost, "/api/tagihan", bytes.NewReader(body))
		ctx := context.WithValue(req.Context(), ctxPhone, warung)
		req = req.WithContext(context.WithValue(ctx, ctxRole, "food_merchant"))
		rec := httptest.NewRecorder()
		tagihanHandler(rec, req)
		return rec
	}
	idTagihan := func(rec *httptest.ResponseRecorder) string {
		var hasil struct {
			Tagihan struct {
				ID string `json:"id"`
			} `json:"tagihan"`
		}
		json.Unmarshal(rec.Body.Bytes(), &hasil)
		return hasil.Tagihan.ID
	}

	// Saldo kosong: tagihan tidak boleh ikut hangus karena percobaan yang gagal.
	rec := buat(25000)
	if rec.Code != 200 {
		t.Fatalf("gagal membuat tagihan: %d %s", rec.Code, rec.Body.String())
	}
	id := idTagihan(rec)
	if id == "" {
		t.Fatalf("id tagihan kosong: %s", rec.Body.String())
	}
	rec = httptest.NewRecorder()
	bayarTagihanHandler(rec, permintaanBayar(awalanQRTagihan+id, penumpang))
	if rec.Code != 402 {
		t.Fatalf("bayar tanpa saldo dibalas %d, harusnya 402", rec.Code)
	}

	db.Exec("UPDATE users SET balance = 100000 WHERE phone_number = ?", penumpang)

	// Delapan pemindaian berbarengan: tepat satu boleh mendebit.
	var siap, mulai sync.WaitGroup
	var kunci sync.Mutex
	berhasil := 0
	const jumlahPemindai = 8
	siap.Add(jumlahPemindai)
	mulai.Add(1)
	var selesai sync.WaitGroup
	selesai.Add(jumlahPemindai)
	for i := 0; i < jumlahPemindai; i++ {
		go func() {
			defer selesai.Done()
			siap.Done()
			mulai.Wait()
			r := httptest.NewRecorder()
			bayarTagihanHandler(r, permintaanBayar(awalanQRTagihan+id, penumpang))
			if r.Code == 200 {
				kunci.Lock()
				berhasil++
				kunci.Unlock()
			}
		}()
	}
	siap.Wait()
	mulai.Done()
	selesai.Wait()
	if berhasil != 1 {
		t.Errorf("%d pemindaian berhasil, harusnya tepat 1", berhasil)
	}

	var saldoPenumpang, saldoWarung float64
	db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", penumpang).Scan(&saldoPenumpang)
	db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", warung).Scan(&saldoWarung)
	if saldoPenumpang != 75000 {
		t.Errorf("saldo penumpang %.0f, harusnya 75000", saldoPenumpang)
	}
	if saldoWarung != 25000 {
		t.Errorf("saldo warung %.0f, harusnya 25000", saldoWarung)
	}

	// QR yang sama sesudahnya: ditolak dengan alasan yang benar, bukan diam-diam
	// mendebit lagi.
	rec = httptest.NewRecorder()
	bayarTagihanHandler(rec, permintaanBayar(awalanQRTagihan+id, penumpang))
	if rec.Code != 409 {
		t.Errorf("bayar ulang dibalas %d, harusnya 409", rec.Code)
	}

	// Warung tidak boleh membayar tagihannya sendiri — uang yang berputar di
	// satu akun hanya menghanguskan tagihannya.
	rec = buat(10000)
	idSendiri := idTagihan(rec)
	rec = httptest.NewRecorder()
	bayarTagihanHandler(rec, permintaanBayar(awalanQRTagihan+idSendiri, warung))
	if rec.Code != 400 {
		t.Errorf("warung membayar tagihannya sendiri dibalas %d, harusnya 400", rec.Code)
	}
	var masihKosong int
	db.QueryRow("SELECT COUNT(*) FROM tagihan_qr WHERE id = ? AND paid_at IS NULL", idSendiri).Scan(&masihKosong)
	if masihKosong != 1 {
		t.Errorf("tagihan yang ditolak ikut ditandai lunas")
	}
}

// Mitra rental ikut bisa menagih, dan potongan bohAntar dikunci saat tagihan
// dibuat: persen yang diubah sesudahnya tidak boleh menggeser uang yang sudah
// dijanjikan ke mitra di layar QR.
func TestTagihanQRPotonganUntukMitraRental(t *testing.T) {
	bukaDBTes(t)

	stempel := time.Now().Format("150405")
	rental := "+62866" + stempel
	penumpang := "+62877" + stempel
	penggunaUji(t, rental)
	penggunaUji(t, penumpang)
	db.Exec("UPDATE users SET role = 'rental_partner' WHERE phone_number = ?", rental)
	db.Exec("UPDATE users SET balance = 100000 WHERE phone_number = ?", penumpang)
	t.Cleanup(func() { db.Exec("DELETE FROM tagihan_qr WHERE penerima_phone = ?", rental) })

	// Baris tarif potongan dipasang 10%, lalu dikembalikan seperti semula.
	var persenLama float64
	adaLama := db.QueryRow("SELECT komisi_persen FROM tarif WHERE layanan = ?", layananTagihanQR).Scan(&persenLama) == nil
	if err := simpanTarif(tarifLayanan{Layanan: layananTagihanQR, Pembulatan: 100, KomisiPersen: 10}); err != nil {
		t.Fatalf("gagal memasang persen potongan: %v", err)
	}
	t.Cleanup(func() {
		if adaLama {
			db.Exec("UPDATE tarif SET komisi_persen = ? WHERE layanan = ?", persenLama, layananTagihanQR)
		} else {
			db.Exec("DELETE FROM tarif WHERE layanan = ?", layananTagihanQR)
		}
	})

	body, _ := json.Marshal(map[string]interface{}{"amount": 50000})
	req := httptest.NewRequest(http.MethodPost, "/api/tagihan", bytes.NewReader(body))
	ctx := context.WithValue(req.Context(), ctxPhone, rental)
	req = req.WithContext(context.WithValue(ctx, ctxRole, "rental_partner"))
	rec := httptest.NewRecorder()
	tagihanHandler(rec, req)
	if rec.Code != 200 {
		t.Fatalf("mitra rental gagal membuat tagihan: %d %s", rec.Code, rec.Body.String())
	}
	var hasil struct {
		Tagihan tagihan `json:"tagihan"`
	}
	json.Unmarshal(rec.Body.Bytes(), &hasil)
	if hasil.Tagihan.Komisi != 5000 {
		t.Fatalf("potongan %v, harusnya 5000 (10%% dari 50000)", hasil.Tagihan.Komisi)
	}

	// Persen diubah setelah QR disodorkan: tagihan ini tetap memakai 10%.
	db.Exec("UPDATE tarif SET komisi_persen = 50 WHERE layanan = ?", layananTagihanQR)

	rec = httptest.NewRecorder()
	bayarTagihanHandler(rec, permintaanBayar(awalanQRTagihan+hasil.Tagihan.ID, penumpang))
	if rec.Code != 200 {
		t.Fatalf("pembayaran ditolak: %d %s", rec.Code, rec.Body.String())
	}
	if s := saldoUji(t, penumpang); s != 50000 {
		t.Errorf("saldo penumpang %.0f, harusnya 50000 — pelanggan membayar penuh", s)
	}
	if s := saldoUji(t, rental); s != 45000 {
		t.Errorf("saldo mitra %.0f, harusnya 45000 — nominal dikurangi potongan yang dikunci", s)
	}
}
