package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

// ==================== PENCAIRAN SALDO (MANUAL) ====================
//
// Saldo driver dan mitra bertambah dari pesanan dompet dan tagihan QR, tapi
// sebelum ini tidak ada jalan untuk mengubahnya jadi uang. Keputusan user
// 9 Okt 2026: pencairan manual, bukan Xendit Disbursement.
//
//  1. Pemilik saldo mengajukan nominal dan rekening tujuan. Saldonya langsung
//     dipotong saat itu juga, jadi uang yang sedang dicairkan tidak bisa ikut
//     dipakai, ditagih, atau diajukan dua kali.
//  2. Admin mentransfer dari rekening bohAntar, lalu menandai "selesai".
//  3. Kalau tidak bisa ditransfer (rekening salah, dsb.), admin menolak dan
//     saldonya dikembalikan utuh.
//
// Satu pengajuan menunggu per akun: ketukan ganda tidak melahirkan dua
// transfer, dan admin tidak perlu menebak mana yang sungguhan.

const (
	// Di bawah ini biaya transfer antar bank bisa memakan sebagian besar
	// nominalnya, dan antrean admin penuh oleh pengajuan receh.
	pencairanMinimal  = 10000
	pencairanMaksimal = 10000000
)

// Peran yang punya saldo pendapatan. Penumpang sengaja tidak: saldonya hasil
// top up, dan mencairkannya kembali sama dengan meminjamkan rekening bohAntar
// sebagai tempat transit uang.
var peranBolehCair = []string{"driver", "food_merchant", "rental_partner"}

type pencairan struct {
	ID            string  `json:"id"`
	Phone         string  `json:"phone_number"`
	NamaAkun      string  `json:"nama_akun"`
	Peran         string  `json:"peran"`
	Amount        float64 `json:"amount"`
	Bank          string  `json:"bank"`
	NomorRekening string  `json:"nomor_rekening"`
	NamaPemilik   string  `json:"nama_pemilik"`
	Status        string  `json:"status"` // menunggu | selesai | ditolak
	Catatan       string  `json:"catatan"`
	CreatedAt     string  `json:"created_at"`
	ProcessedAt   string  `json:"processed_at,omitempty"`
}

// rekeningSah merapikan dan memeriksa isian rekening. Nomor rekening hanya
// angka; spasi dan strip yang biasa diketik dibuang dulu.
func rekeningSah(bank, nomor, nama string) (string, string, string, string) {
	bank = strings.TrimSpace(bank)
	nama = strings.TrimSpace(nama)
	nomor = strings.NewReplacer(" ", "", "-", "", ".", "").Replace(strings.TrimSpace(nomor))
	switch {
	case utf8.RuneCountInString(bank) < 2 || utf8.RuneCountInString(bank) > 50:
		return "", "", "", "Nama bank atau e-wallet harus 2–50 karakter"
	case len(nomor) < 5 || len(nomor) > 30:
		return "", "", "", "Nomor rekening harus 5–30 angka"
	case strings.Trim(nomor, "0123456789") != "":
		return "", "", "", "Nomor rekening hanya boleh berisi angka"
	case utf8.RuneCountInString(nama) < 2 || utf8.RuneCountInString(nama) > 100:
		return "", "", "", "Nama pemilik rekening harus 2–100 karakter"
	}
	return bank, nomor, nama, ""
}

// pencairanHandler: GET daftar pengajuan milik pemanggil, POST pengajuan baru.
func pencairanHandler(w http.ResponseWriter, r *http.Request) {
	phone := callerPhone(r)
	switch r.Method {
	case http.MethodGet:
		daftar, err := daftarPencairan("phone_number = ?", phone)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca riwayat pencairan"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "pencairan": daftar})

	case http.MethodPost:
		var input struct {
			Amount        float64 `json:"amount"`
			Bank          string  `json:"bank"`
			NomorRekening string  `json:"nomor_rekening"`
			NamaPemilik   string  `json:"nama_pemilik"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data pencairan tidak terbaca"})
			return
		}
		nominal := math.Round(input.Amount)
		if nominal < pencairanMinimal || nominal > pencairanMaksimal {
			writeJSONResponse(w, 400, map[string]string{"error": fmt.Sprintf("Nominal pencairan Rp%.0f – Rp%.0f", float64(pencairanMinimal), float64(pencairanMaksimal))})
			return
		}
		bank, nomor, nama, alasan := rekeningSah(input.Bank, input.NomorRekening, input.NamaPemilik)
		if alasan != "" {
			writeJSONResponse(w, 400, map[string]string{"error": alasan})
			return
		}
		kode, pesan, p := ajukanPencairan(phone, nominal, bank, nomor, nama)
		if kode != 200 {
			writeJSONResponse(w, kode, map[string]string{"error": pesan})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "pencairan": p})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// ajukanPencairan memotong saldo dan mencatat pengajuannya dalam satu transaksi.
//
// Berjalan di bawah gerbangSaldoMu, kunci yang sama dengan klaim pesanan:
// komisi pesanan tunai yang sedang berjalan dan ongkos pesanan dompet yang
// belum ditutup sudah dijanjikan, jadi tidak boleh ikut dicairkan — dan klaim
// pesanan baru tidak boleh menyelinap di antara hitungan dan potongannya.
func ajukanPencairan(phone string, nominal float64, bank, nomor, nama string) (int, string, pencairan) {
	gerbangSaldoMu.Lock()
	defer gerbangSaldoMu.Unlock()

	var menunggu int
	if err := db.QueryRow("SELECT COUNT(*) FROM pencairan_saldo WHERE phone_number = ? AND status = 'menunggu'", phone).Scan(&menunggu); err != nil {
		return 500, "Gagal memeriksa pengajuan sebelumnya", pencairan{}
	}
	if menunggu > 0 {
		return 409, "Masih ada pencairan yang menunggu diproses admin. Tunggu sampai selesai dulu.", pencairan{}
	}

	tertahanPenumpang, err1 := dbSaldoTertahan(phone)
	tertahanDriver, err2 := dbKomisiTertahan(phone)
	if err1 != nil || err2 != nil {
		return 500, "Gagal memeriksa saldo", pencairan{}
	}
	tertahan := tertahanPenumpang + tertahanDriver

	u, ada := dbGetUser(phone)
	if !ada {
		return 404, "Akun tidak ditemukan", pencairan{}
	}
	p := pencairan{
		ID: newID("cair"), Phone: phone, NamaAkun: u.Name, Peran: u.Role,
		Amount: nominal, Bank: bank, NomorRekening: nomor, NamaPemilik: nama,
		Status: "menunggu", CreatedAt: time.Now().Format(time.RFC3339),
	}

	tx, err := db.Begin()
	if err != nil {
		return 500, "Gagal memulai transaksi", pencairan{}
	}
	defer tx.Rollback()

	// Saldo diperiksa di dalam UPDATE, bukan dibaca lalu dibandingkan, supaya
	// pembayaran tagihan yang mendebit akun yang sama di saat bersamaan tidak
	// bisa membuat saldonya minus.
	res, err := tx.Exec(
		"UPDATE users SET balance = balance - ? WHERE phone_number = ? AND balance >= ?",
		nominal, phone, nominal+tertahan,
	)
	if err != nil {
		return 500, "Gagal memperbarui saldo", pencairan{}
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if tertahan > 0 {
			return 402, fmt.Sprintf("Saldo tidak cukup. Rp%.0f sedang tertahan untuk pesanan yang belum selesai.", tertahan), pencairan{}
		}
		return 402, "Saldo tidak cukup untuk nominal ini", pencairan{}
	}
	if _, err := tx.Exec(`
		INSERT INTO pencairan_saldo (id, phone_number, nama_akun, peran, amount, bank, nomor_rekening, nama_pemilik, status, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'menunggu', ?)`,
		p.ID, p.Phone, p.NamaAkun, p.Peran, p.Amount, p.Bank, p.NomorRekening, p.NamaPemilik, waktuKeDB(p.CreatedAt),
	); err != nil {
		log.Printf("Pencairan %s gagal dicatat: %v", phone, err)
		return 500, "Gagal menyimpan pengajuan", pencairan{}
	}
	if err := tx.Commit(); err != nil {
		return 500, "Gagal menyimpan pengajuan", pencairan{}
	}
	return 200, "", p
}

// adminPencairanHandler: GET /api/admin/pencairan?status=menunggu|selesai|ditolak
func adminPencairanHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	status := r.URL.Query().Get("status")
	if status == "" {
		status = "menunggu"
	}
	daftar, err := daftarPencairan("status = ?", status)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca daftar pencairan"})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "pencairan": daftar})
}

// adminProsesPencairanHandler: POST /api/admin/pencairan/{id}/selesai atau /tolak
//
// catatan wajib untuk keduanya: nomor referensi transfer untuk yang selesai
// (bukti kalau pemiliknya bertanya), alasan untuk yang ditolak.
func adminProsesPencairanHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	bagian := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/admin/pencairan/"), "/"), "/")
	if len(bagian) != 2 || (bagian[1] != "selesai" && bagian[1] != "tolak") {
		writeJSONResponse(w, 404, map[string]string{"error": "Not found"})
		return
	}
	id, aksi := bagian[0], bagian[1]
	var input struct {
		Catatan string `json:"catatan"`
	}
	_ = json.NewDecoder(r.Body).Decode(&input)
	catatan := strings.TrimSpace(input.Catatan)
	if catatan == "" || utf8.RuneCountInString(catatan) > 200 {
		writeJSONResponse(w, 400, map[string]string{"error": "Isi catatan (nomor referensi transfer atau alasan penolakan), maksimal 200 karakter"})
		return
	}

	statusBaru := "selesai"
	if aksi == "tolak" {
		statusBaru = "ditolak"
	}
	sekarang := waktuKeDB(time.Now().Format(time.RFC3339))

	tx, err := db.Begin()
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memulai transaksi"})
		return
	}
	defer tx.Rollback()

	// Bersyarat status 'menunggu': dua admin yang menekan bersamaan, atau satu
	// admin yang menekan dua kali, hanya menghasilkan satu perubahan — dan
	// pengembalian saldo saat menolak tidak pernah terjadi dua kali.
	res, err := tx.Exec(
		"UPDATE pencairan_saldo SET status = ?, catatan = ?, diproses_oleh = ?, processed_at = ? WHERE id = ? AND status = 'menunggu'",
		statusBaru, catatan, callerPhone(r), sekarang, id,
	)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses pencairan"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONResponse(w, 409, map[string]string{"error": "Pencairan ini tidak ada atau sudah diproses"})
		return
	}

	var phone string
	var jumlah float64
	if err := tx.QueryRow("SELECT phone_number, amount FROM pencairan_saldo WHERE id = ?", id).Scan(&phone, &jumlah); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca pencairan"})
		return
	}
	if aksi == "tolak" {
		res, err := tx.Exec("UPDATE users SET balance = balance + ? WHERE phone_number = ?", jumlah, phone)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal mengembalikan saldo"})
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			writeJSONResponse(w, 410, map[string]string{"error": "Akun pemiliknya sudah tidak ada, saldo tidak bisa dikembalikan"})
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan"})
		return
	}

	judul, isi := "Pencairan saldo selesai", fmt.Sprintf("Rp%.0f sudah ditransfer. Ref: %s", jumlah, catatan)
	if aksi == "tolak" {
		judul, isi = "Pencairan saldo ditolak", fmt.Sprintf("Rp%.0f dikembalikan ke saldo. Alasan: %s", jumlah, catatan)
	}
	notifikasiKe(phone, judul, isi, map[string]string{"tipe": "pencairan", "id": id})
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": judul})
}

// daftarPencairan membaca paling banyak 100 pengajuan terbaru yang cocok
// dengan satu syarat sederhana. Nama dan peran dibaca dari salinan di barisnya
// sendiri — tidak ada JOIN ke users, yang kolasinya berbeda dari tabel baru.
func daftarPencairan(syarat string, nilai string) ([]pencairan, error) {
	rows, err := db.Query(`
		SELECT id, phone_number, nama_akun, peran, amount, bank, nomor_rekening, nama_pemilik,
		       status, COALESCE(catatan, ''), created_at, processed_at
		FROM pencairan_saldo WHERE `+syarat+` ORDER BY created_at DESC LIMIT 100`, nilai)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	daftar := make([]pencairan, 0)
	for rows.Next() {
		var p pencairan
		var dibuat time.Time
		var diproses sql.NullTime
		if err := rows.Scan(&p.ID, &p.Phone, &p.NamaAkun, &p.Peran, &p.Amount, &p.Bank, &p.NomorRekening,
			&p.NamaPemilik, &p.Status, &p.Catatan, &dibuat, &diproses); err != nil {
			return nil, err
		}
		p.CreatedAt = dibuat.Format(time.RFC3339)
		if diproses.Valid {
			p.ProcessedAt = diproses.Time.Format(time.RFC3339)
		}
		daftar = append(daftar, p)
	}
	return daftar, rows.Err()
}
