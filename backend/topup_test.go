package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Top up manual: setujui menambah saldo tepat sekali, tolak tidak menambah
// apa pun, dan QR Xendit lama (PENDING) tidak bisa disetujui dari dashboard.
func TestTopUpManualSetujuiTolak(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000105"
	proses := func(id, aksi string) int {
		rec := httptest.NewRecorder()
		adminProsesTopUpHandler(rec, httptest.NewRequest(http.MethodPost, "/api/admin/topup/"+id+"/"+aksi, nil))
		return rec.Code
	}
	menunggu := func(nominal float64) string {
		id := invoiceTopUpUji(t, phone, nominal)
		db.Exec("UPDATE topup_invoices SET status = 'MENUNGGU' WHERE id = ?", id)
		return id
	}
	// Semua baris dibuat dulu: invoiceTopUpUji menyimpan ulang pengguna uji,
	// dan itu mengenolkan saldonya.
	a, b, lama := menunggu(30000), menunggu(20000), invoiceTopUpUji(t, phone, 40000)
	saldoAwal := saldoUji(t, phone)
	if kode := proses(a, "setujui"); kode != 200 {
		t.Fatalf("setujui dibalas %d", kode)
	}
	if kode := proses(a, "setujui"); kode != 409 {
		t.Fatalf("setujui kedua dibalas %d, harusnya 409", kode)
	}
	if kode := proses(b, "tolak"); kode != 200 {
		t.Fatalf("tolak dibalas %d", kode)
	}
	if kode := proses(b, "setujui"); kode != 409 {
		t.Fatalf("setujui setelah ditolak dibalas %d, harusnya 409", kode)
	}
	if kode := proses(lama, "setujui"); kode != 409 {
		t.Fatalf("QR Xendit lama disetujui (kode %d)", kode)
	}
	if saldo := saldoUji(t, phone); saldo != saldoAwal+30000 {
		t.Fatalf("saldo jadi %.0f, harusnya %.0f", saldo, saldoAwal+30000)
	}
}

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
			_, jumlah, err := dbKreditTopUp(id, "PENDING", nominal)
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

	if _, jumlah, err := dbKreditTopUp(id, "PENDING", 20000); !errors.Is(err, errTopUpKurangBayar) || jumlah != 0 {
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
	if _, jumlah, err := dbKreditTopUp("topup-karangan-xyz", "PENDING", 50000); !errors.Is(err, errTopUpTakDitemukan) || jumlah != 0 {
		t.Fatalf("invoice karangan diterima: jumlah %.0f, err %v", jumlah, err)
	}
}

// Tiap pengajuan top up mengirim email ke admin, jadi permintaan keenam dalam
// sepuluh menit harus ditahan.
func TestTopUpDiremSetelahLimaInvoice(t *testing.T) {
	bukaDBTes(t)
	t.Setenv("TOPUP_TUJUAN", "DANA uji")
	t.Setenv("SMTP_HOST", "") // jangan kirim email sungguhan dari tes
	const phone = "+62800000400"
	t.Cleanup(func() { db.Exec("DELETE FROM topup_invoices WHERE phone_number = ?", phone) })

	minta := func() int {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/api/users/topup", strings.NewReader(`{"amount":50000}`))
		r.Header.Set("Authorization", "Bearer "+mustToken(t, phone, "rider"))
		topUpHandler(w, r)
		return w.Code
	}

	for i := 0; i < batasTopUpPerJendela; i++ {
		invoiceTopUpUji(t, phone, 50000)
	}
	if kode := minta(); kode != 429 {
		t.Fatalf("permintaan ke-%d dibalas %d, harusnya 429", batasTopUpPerJendela+1, kode)
	}

	// Invoice yang sudah lewat jendela tidak ikut dihitung.
	db.Exec("UPDATE topup_invoices SET created_at = ? WHERE phone_number = ?",
		waktuKeDB(time.Now().Add(-jendelaTopUp-time.Minute).Format(time.RFC3339)), phone)
	if kode := minta(); kode != 200 {
		t.Fatalf("setelah jendela lewat dibalas %d, harusnya 200", kode)
	}
}

// Riwayat super admin: invoice bulan ini tampil dengan nama driver dan status
// lunasnya, invoice bulan lalu tidak ikut.
func TestAdminTopUpPerBulan(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000104"
	lunas := invoiceTopUpUji(t, phone, 25000)
	belum := invoiceTopUpUji(t, phone, 15000)
	lama := invoiceTopUpUji(t, phone, 99000)
	if _, _, err := dbKreditTopUp(lunas, "PENDING", 25000); err != nil {
		t.Fatalf("gagal melunasi: %v", err)
	}
	db.Exec("UPDATE topup_invoices SET created_at = ? WHERE id = ?",
		waktuKeDB(time.Now().AddDate(0, -1, -1).Format(time.RFC3339)), lama)

	rec := httptest.NewRecorder()
	adminTopUpHandler(rec, httptest.NewRequest(http.MethodGet, "/api/admin/topup", nil))
	var res struct {
		Topup      []barisTopUp `json:"topup"`
		TotalLunas float64      `json:"total_lunas"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil || rec.Code != 200 {
		t.Fatalf("status %d, body %s", rec.Code, rec.Body.String())
	}
	status := map[string]string{}
	for _, b := range res.Topup {
		if b.Phone == phone {
			status[b.ID] = b.Status
			if b.Nama == "" {
				t.Errorf("invoice %s tanpa nama driver", b.ID)
			}
		}
	}
	if status[lunas] != "PAID" || status[belum] != "PENDING" {
		t.Fatalf("status salah: %v", status)
	}
	if _, ada := status[lama]; ada {
		t.Fatal("invoice bulan lalu ikut tampil")
	}
	if res.TotalLunas < 25000 {
		t.Fatalf("total lunas %.0f belum memuat 25.000", res.TotalLunas)
	}
}

// Halaman bayar menampilkan QRIS bila TOPUP_QRIS diisi, dan kembali ke
// petunjuk transfer bila kosong.
func TestHalamanBayarTopUpQRIS(t *testing.T) {
	bukaDBTes(t)
	t.Setenv("TOPUP_TUJUAN", "DANA Bisnis uji")
	id := invoiceTopUpUji(t, "+62800000401", 50000)
	db.Exec("UPDATE topup_invoices SET status = 'MENUNGGU' WHERE id = ?", id)

	buka := func() string {
		w := httptest.NewRecorder()
		topUpBayarHandler(w, httptest.NewRequest(http.MethodGet, "/api/topup/bayar/"+id, nil))
		return w.Body.String()
	}

	t.Setenv("TOPUP_QRIS", "/uploads/qris-topup.png")
	if h := buka(); !strings.Contains(h, `src="/uploads/qris-topup.png"`) || strings.Contains(h, "berita transfer") {
		t.Fatalf("halaman QRIS salah:\n%s", h)
	}
	t.Setenv("TOPUP_QRIS", "")
	if h := buka(); strings.Contains(h, "<img") || !strings.Contains(h, "berita transfer") {
		t.Fatalf("halaman transfer salah:\n%s", h)
	}
}

// Kode unik: total nominal+kode tidak boleh kembar dengan pengajuan MENUNGGU,
// pengajuan yang sudah lunas tidak menghalangi, dan totalnya yang tersimpan
// (jadi yang dikreditkan).
func TestTopUpKodeUnik(t *testing.T) {
	bukaDBTes(t)
	t.Setenv("TOPUP_TUJUAN", "DANA uji")
	t.Setenv("SMTP_HOST", "")
	const phone = "+62800000402"
	db.Exec("DELETE FROM topup_invoices WHERE status = 'MENUNGGU' AND amount > 77000 AND amount < 78000")
	t.Cleanup(func() { db.Exec("DELETE FROM topup_invoices WHERE phone_number = ?", phone) })

	menunggu := invoiceTopUpUji(t, "+62800000403", 77001)
	db.Exec("UPDATE topup_invoices SET status = 'MENUNGGU' WHERE id = ?", menunggu)
	invoiceTopUpUji(t, "+62800000403", 77002) // PENDING lama, tidak menghalangi
	penggunaUji(t, phone)

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/api/users/topup", strings.NewReader(`{"amount":77000}`))
	r.Header.Set("Authorization", "Bearer "+mustToken(t, phone, "rider"))
	topUpHandler(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"amount":77002`) {
		t.Fatalf("balasan %d %s, harusnya amount 77002", w.Code, w.Body.String())
	}
	var tersimpan float64
	db.QueryRow("SELECT amount FROM topup_invoices WHERE phone_number = ? AND status = 'MENUNGGU'", phone).Scan(&tersimpan)
	if tersimpan != 77002 {
		t.Fatalf("tersimpan %.0f, harusnya 77002", tersimpan)
	}
}
