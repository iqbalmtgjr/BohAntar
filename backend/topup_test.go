package main

import (
	"errors"
	"sync"
	"testing"
	"time"
)

func TestNominalTopUpSah(t *testing.T) {
	kasus := []struct {
		nama    string
		minta   float64
		mau     float64
		ditolak bool
	}{
		{"nominal wajar", 50000, 50000, false},
		{"pecahan dibulatkan", 50000.4, 50000, false},
		{"pas di batas bawah", topUpMinimal, topUpMinimal, false},
		{"pas di batas atas", topUpMaksimal, topUpMaksimal, false},
		{"di bawah batas", 5000, 0, true},
		{"kelebihan nol", 20000000, 0, true},
	}
	for _, k := range kasus {
		t.Run(k.nama, func(t *testing.T) {
			nominal, alasan := nominalTopUpSah(k.minta)
			if k.ditolak {
				if alasan == "" {
					t.Fatalf("%.0f seharusnya ditolak, malah lolos jadi %.0f", k.minta, nominal)
				}
				return
			}
			if alasan != "" {
				t.Fatalf("%.0f ditolak tanpa alasan yang benar: %s", k.minta, alasan)
			}
			if nominal != k.mau {
				t.Fatalf("%.0f jadi %.0f, harusnya %.0f", k.minta, nominal, k.mau)
			}
		})
	}
}

// invoiceTopUpUji menulis satu tagihan PENDING dan membereskannya setelah tes.
func invoiceTopUpUji(t *testing.T, phone string, nominal float64) string {
	t.Helper()
	penggunaUji(t, phone)
	id := newID("test-topup")
	if _, err := db.Exec(
		"INSERT INTO topup_invoices (id, phone_number, amount, status, payment_url, created_at) VALUES (?, ?, ?, 'PENDING', '', ?)",
		id, phone, nominal, waktuKeDB(time.Now().Format(time.RFC3339)),
	); err != nil {
		t.Fatalf("gagal menyiapkan invoice top up uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM topup_invoices WHERE id = ?", id) })
	return id
}

func saldoUji(t *testing.T, phone string) float64 {
	t.Helper()
	var saldo float64
	if err := db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", phone).Scan(&saldo); err != nil {
		t.Fatalf("gagal membaca saldo %s: %v", phone, err)
	}
	return saldo
}

// Webhook Xendit mengulang kiriman yang tidak dibalas 200, jadi satu pembayaran
// bisa tiba beberapa kali — kadang bersamaan. Yang dijaga di sini MySQL, lewat
// syarat "AND status = 'PENDING'" di dalam UPDATE, jadi tesnya menembak database
// sungguhan dan dilewati kalau tidak ada.
func TestDbKreditTopUpHanyaSekali(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000100"
	const nominal = 50000
	id := invoiceTopUpUji(t, phone, nominal)
	saldoAwal := saldoUji(t, phone)

	const kiriman = 6
	var siap sync.WaitGroup
	var mulai sync.WaitGroup
	var kunci sync.Mutex
	dikreditkan := 0

	siap.Add(kiriman)
	mulai.Add(1)
	for i := 0; i < kiriman; i++ {
		go func() {
			defer siap.Done()
			mulai.Wait() // semua webhook tiba sedekat mungkin
			_, jumlah, err := dbKreditTopUp(id, nominal)
			if err != nil {
				t.Errorf("webhook gagal: %v", err)
				return
			}
			if jumlah > 0 {
				kunci.Lock()
				dikreditkan++
				kunci.Unlock()
			}
		}()
	}
	mulai.Done()
	siap.Wait()

	if dikreditkan != 1 {
		t.Fatalf("%d webhook merasa menambah saldo, harusnya tepat 1", dikreditkan)
	}
	if saldo := saldoUji(t, phone); saldo != saldoAwal+nominal {
		t.Fatalf("saldo jadi %.0f, harusnya %.0f", saldo, saldoAwal+nominal)
	}
}

// Kurang bayar tidak boleh menambah saldo sama sekali. QRIS dinamis mengunci
// nominal di dalam QR, jadi selisih apa pun berarti ada yang tidak beres.
func TestDbKreditTopUpTolakKurangBayar(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000101"
	id := invoiceTopUpUji(t, phone, 50000)
	saldoAwal := saldoUji(t, phone)

	if _, jumlah, err := dbKreditTopUp(id, 20000); !errors.Is(err, errTopUpKurangBayar) || jumlah != 0 {
		t.Fatalf("bayar 20000 untuk tagihan 50000 diterima: jumlah %.0f, err %v", jumlah, err)
	}
	if saldo := saldoUji(t, phone); saldo != saldoAwal {
		t.Fatalf("saldo berubah jadi %.0f padahal pembayaran kurang", saldo)
	}

	// Tagihan tetap PENDING, jadi pembayaran yang benar setelahnya masih bisa masuk.
	var status string
	if err := db.QueryRow("SELECT status FROM topup_invoices WHERE id = ?", id).Scan(&status); err != nil {
		t.Fatalf("gagal membaca status invoice: %v", err)
	}
	if status != "PENDING" {
		t.Fatalf("status invoice jadi %q setelah kurang bayar, harusnya tetap PENDING", status)
	}
}

// Invoice karangan tidak boleh menambah saldo siapa pun. Tanpa ini, siapa saja
// yang bisa memalsukan webhook cukup mengarang ID untuk mencetak saldo.
func TestDbKreditTopUpInvoiceTakDikenal(t *testing.T) {
	bukaDBTes(t)
	if _, jumlah, err := dbKreditTopUp("topup-karangan-xyz", 50000); !errors.Is(err, errTopUpTakDitemukan) || jumlah != 0 {
		t.Fatalf("invoice karangan diterima: jumlah %.0f, err %v", jumlah, err)
	}
}
