package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// Pencairan memindahkan uang sungguhan keluar dari bohAntar, jadi yang diuji
// bukan "berhasil": saldo tertahan tidak ikut cair, ketukan ganda tidak jadi dua
// transfer, dan penolakan mengembalikan saldo tepat sekali.
func TestPencairanSaldoManual(t *testing.T) {
	bukaDBTes(t)
	const driver = "+62800000500"
	penggunaUji(t, driver)
	db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1, balance = 50000 WHERE phone_number = ?", driver)
	t.Cleanup(func() { db.Exec("DELETE FROM pencairan_saldo WHERE phone_number = ?", driver) })

	// Satu pesanan tunai sedang berjalan: komisinya 1000 sudah dijanjikan.
	oid := pesananUji(t, "+62800000501", "cash", "accepted", 10000)
	db.Exec("UPDATE orders SET driver_phone = ? WHERE id = ?", driver, oid)

	ajukan := func(nominal float64) (int, pencairan) {
		body, _ := json.Marshal(map[string]interface{}{
			"amount": nominal, "bank": "BRI", "nomor_rekening": "0123-4567 890", "nama_pemilik": "Driver Uji",
		})
		r := httptest.NewRequest(http.MethodPost, "/api/pencairan", bytes.NewReader(body))
		ctx := context.WithValue(r.Context(), ctxPhone, driver)
		w := httptest.NewRecorder()
		pencairanHandler(w, r.WithContext(context.WithValue(ctx, ctxRole, "driver")))
		var hasil struct {
			Pencairan pencairan `json:"pencairan"`
		}
		json.Unmarshal(w.Body.Bytes(), &hasil)
		return w.Code, hasil.Pencairan
	}
	proses := func(id, aksi string) int {
		r := httptest.NewRequest(http.MethodPost, "/api/admin/pencairan/"+id+"/"+aksi,
			bytes.NewReader([]byte(`{"catatan":"uji"}`)))
		w := httptest.NewRecorder()
		adminProsesPencairanHandler(w, r.WithContext(context.WithValue(r.Context(), ctxPhone, "+62800000599")))
		return w.Code
	}

	// 49.500 melewati saldo yang bebas (50.000 - 1.000 tertahan).
	if kode, _ := ajukan(49500); kode != 402 {
		t.Fatalf("mencairkan saldo yang tertahan dibalas %d, harusnya 402", kode)
	}

	// Lima ketukan berbarengan: tepat satu pengajuan lahir. Nominalnya sengaja
	// kecil — saldo bebas 49.000 cukup untuk empat kali 10.000, jadi yang
	// menahan di sini aturan satu-pengajuan-menunggu, bukan saldonya.
	var siap, mulai sync.WaitGroup
	var kunci sync.Mutex
	var id string
	berhasil := 0
	siap.Add(5)
	mulai.Add(1)
	for i := 0; i < 5; i++ {
		go func() {
			defer siap.Done()
			mulai.Wait()
			if kode, p := ajukan(10000); kode == 200 {
				kunci.Lock()
				berhasil++
				id = p.ID
				kunci.Unlock()
			}
		}()
	}
	mulai.Done()
	siap.Wait()
	if berhasil != 1 {
		t.Fatalf("%d pengajuan lahir dari ketukan berbarengan, harusnya tepat 1", berhasil)
	}
	if s := saldoUji(t, driver); s != 40000 {
		t.Fatalf("saldo %.0f setelah mengajukan 10.000, harusnya 40.000", s)
	}
	var nomor string
	db.QueryRow("SELECT nomor_rekening FROM pencairan_saldo WHERE id = ?", id).Scan(&nomor)
	if nomor != "01234567890" {
		t.Errorf("nomor rekening tersimpan %q, harusnya angkanya saja", nomor)
	}

	// Ditolak: saldo kembali, dan menolak dua kali tidak mengembalikan dua kali.
	if kode := proses(id, "tolak"); kode != 200 {
		t.Fatalf("penolakan dibalas %d", kode)
	}
	if kode := proses(id, "tolak"); kode != 409 {
		t.Errorf("penolakan kedua dibalas %d, harusnya 409", kode)
	}
	if s := saldoUji(t, driver); s != 50000 {
		t.Fatalf("saldo %.0f setelah ditolak, harusnya kembali 50.000", s)
	}

	// Diajukan lagi lalu ditandai selesai: saldo tetap terpotong.
	kode, p := ajukan(30000)
	if kode != 200 {
		t.Fatalf("pengajuan ulang setelah ditolak dibalas %d", kode)
	}
	if kode := proses(p.ID, "selesai"); kode != 200 {
		t.Fatalf("menandai selesai dibalas %d", kode)
	}
	if s := saldoUji(t, driver); s != 20000 {
		t.Errorf("saldo %.0f setelah transfer selesai, harusnya 20.000", s)
	}
	if kode := proses(p.ID, "tolak"); kode != 409 {
		t.Errorf("pencairan yang sudah selesai masih bisa ditolak (%d) — saldonya akan kembali padahal uangnya sudah keluar", kode)
	}

	// Urutannya tidak diperiksa: kedua baris lahir di detik yang sama, dan
	// DATETIME tidak lebih teliti dari detik.
	daftar, err := daftarPencairan("phone_number = ?", driver)
	status := map[string]bool{}
	for _, d := range daftar {
		status[d.Status] = d.CreatedAt != "" && d.ProcessedAt != ""
	}
	if err != nil || len(daftar) != 2 || !status["selesai"] || !status["ditolak"] {
		t.Errorf("riwayat tidak sesuai: %+v (err %v)", daftar, err)
	}
}

func TestRekeningSah(t *testing.T) {
	if _, nomor, _, alasan := rekeningSah(" BCA ", "123 456-7890", "Budi"); alasan != "" || nomor != "1234567890" {
		t.Fatalf("rekening wajar ditolak atau tidak dirapikan: %q %q", nomor, alasan)
	}
	for _, k := range [][3]string{
		{"BCA", "12a4567", "Budi"}, // huruf di nomor
		{"BCA", "123", "Budi"},     // terlalu pendek
		{"", "1234567890", "Budi"}, // bank kosong
		{"BCA", "1234567890", ""},  // pemilik kosong
	} {
		if _, _, _, alasan := rekeningSah(k[0], k[1], k[2]); alasan == "" {
			t.Errorf("%v seharusnya ditolak", k)
		}
	}
}
