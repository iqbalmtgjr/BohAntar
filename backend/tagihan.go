package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// ==================== TAGIHAN QR — BAYAR PAKAI SALDO ====================
//
// Kebalikan setoran komisi: di sana petugas menaikkan saldo driver, di sini
// penumpang memindahkan saldonya sendiri ke warung.
//
//  1. Warung memasukkan nominal di dashboard; QR-nya muncul di layar.
//  2. Penumpang memindai, melihat nama warung dan nominalnya, lalu menekan bayar.
//  3. Saldo penumpang turun, saldo warung naik — sekali saja.
//
// Isi QR cuma id tagihan. Nominal dan penerimanya selalu dibaca dari database,
// tidak pernah dari isi QR: QR yang diedit orang lain tidak bisa memindahkan
// uang ke nomor lain, dan QR yang terfoto tidak membocorkan apa-apa.
const masaBerlakuTagihan = 15 * time.Minute

// Batas atas yang sama dengan top up. Satu nol kelebihan saat mengetik nominal
// ditolak sebelum QR-nya sempat dipindai siapa pun.
const maksTagihan = 2000000

const awalanQRTagihan = "bohantar:tagihan:"

type tagihan struct {
	ID string `json:"id"`
	// Nomor penerima sengaja tidak ikut ke JSON: yang memindai cukup tahu nama
	// warungnya, dan id tagihan bisa dibaca siapa pun yang melihat QR-nya.
	PenerimaPhone string  `json:"-"`
	PenerimaNama  string  `json:"penerima_nama"`
	Amount        float64 `json:"amount"` // yang dibayar pelanggan
	Komisi        float64 `json:"komisi"` // potongan bohAntar; penerima mendapat amount - komisi
	CreatedAt     string  `json:"created_at"`
	ExpiresAt     string  `json:"expires_at"`
	PaidAt        string  `json:"paid_at,omitempty"`
}

// tagihanHandler membuat tagihan baru (POST, hanya warung) atau membacanya
// (GET, siapa pun yang sudah login).
//
// GET dipakai dua sisi: dashboard warung menanyakannya berulang untuk tahu
// kapan sudah dibayar, dan aplikasi penumpang memanggilnya sekali sesudah
// memindai supaya nominal yang dikonfirmasi datang dari server, bukan dari QR.
func tagihanHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		peran := callerRole(r)
		if peran != "food_merchant" && peran != "rental_partner" {
			writeJSONResponse(w, 403, map[string]string{"error": "Hanya mitra warung dan rental yang bisa membuat tagihan"})
			return
		}
		var input struct {
			Amount float64 `json:"amount"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data tagihan tidak terbaca"})
			return
		}
		if input.Amount <= 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Nominal tagihan harus lebih dari nol"})
			return
		}
		if input.Amount > maksTagihan {
			writeJSONResponse(w, 400, map[string]string{"error": "Nominal tagihan terlalu besar"})
			return
		}

		// Nama usaha, bukan nama pemiliknya: itu yang dikenali pelanggan di
		// layar konfirmasi. Disalin ke barisnya supaya tagihan lama tetap
		// menyebut nama yang tertulis saat itu — dan supaya tidak ada JOIN ke
		// users, yang kolasinya berbeda dari tabel-tabel baru.
		penerima := callerPhone(r)
		nama, kode, pesan := namaPenerimaTagihan(penerima, peran)
		if pesan != "" {
			writeJSONResponse(w, kode, map[string]string{"error": pesan})
			return
		}

		t := tagihan{
			ID:            newID("tagih"),
			PenerimaPhone: penerima,
			PenerimaNama:  nama,
			Amount:        input.Amount,
			// Dikunci di sini, bukan dihitung saat dibayar: mitra harus tahu
			// berapa yang ia terima sebelum menyodorkan QR-nya, dan super admin
			// yang mengubah persen siang ini tidak boleh mengubah tagihan pagi.
			Komisi:    komisiTagihan(input.Amount),
			CreatedAt: time.Now().Format(time.RFC3339),
			ExpiresAt: time.Now().Add(masaBerlakuTagihan).Format(time.RFC3339),
		}
		if _, err := db.Exec(
			"INSERT INTO tagihan_qr (id, penerima_phone, penerima_nama, amount, komisi, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
			t.ID, t.PenerimaPhone, t.PenerimaNama, t.Amount, t.Komisi, waktuKeDB(t.CreatedAt), waktuKeDB(t.ExpiresAt),
		); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan tagihan"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "tagihan": t})

	case http.MethodGet:
		t, ok := ambilTagihan(r.URL.Query().Get("id"))
		if !ok {
			writeJSONResponse(w, 404, map[string]string{"error": "Tagihan tidak ditemukan"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "tagihan": t})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// namaPenerimaTagihan mencari nama yang ditampilkan ke pelanggan saat memindai.
// Warung wajib sudah punya baris food_merchants; mitra rental memakai nama
// usahanya, atau nama akunnya kalau nama usaha belum pernah diisi.
func namaPenerimaTagihan(phone, peran string) (nama string, kode int, pesan string) {
	if peran == "rental_partner" {
		if nama = businessNameOf(phone); nama == "" {
			_ = db.QueryRow("SELECT COALESCE(name, '') FROM users WHERE phone_number = ?", phone).Scan(&nama)
		}
		if nama == "" {
			return "", 409, "Isi nama usaha di halaman Akun dulu sebelum menagih"
		}
		// penerima_nama VARCHAR(100); nama usaha dibatasi 100 di profil, tapi
		// nama dari pengajuan lama belum tentu.
		if r := []rune(nama); len(r) > 100 {
			nama = string(r[:100])
		}
		return nama, 0, ""
	}
	err := db.QueryRow("SELECT restaurant_name FROM food_merchants WHERE owner_phone = ?", phone).Scan(&nama)
	if err == sql.ErrNoRows {
		return "", 409, "Lengkapi profil warung dulu sebelum menagih"
	} else if err != nil {
		return "", 500, "Gagal membaca data warung"
	}
	return nama, 0, ""
}

// komisiTagihan menghitung potongan bohAntar dari satu tagihan, memakai persen
// di baris tarif 'TagihanQR' yang diatur super admin.
//
// Sengaja tidak lewat ambilTarif: kalau barisnya tidak terbaca, ambilTarif
// jatuh ke tarif cadangan yang komisinya 20%, dan mitra akan dipotong
// seperlima tanpa pernah ada yang memutuskannya. Gagal baca di sini berarti nol.
func komisiTagihan(jumlah float64) float64 {
	var persen float64
	if err := db.QueryRow("SELECT komisi_persen FROM tarif WHERE layanan = ?", layananTagihanQR).Scan(&persen); err != nil {
		return 0
	}
	return hitungKomisi(tarifLayanan{KomisiPersen: persen}, jumlah)
}

// tagihanQRHandler menggambar QR-nya di server, jadi dashboard tidak perlu
// pustaka QR sendiri — sama seperti QR setoran.
func tagihanQRHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/tagihan/qr/")
	if _, ok := ambilTagihan(id); !ok {
		writeJSONResponse(w, 404, map[string]string{"error": "Tagihan tidak ditemukan"})
		return
	}
	png, err := qrcode.Encode(awalanQRTagihan+id, qrcode.Medium, 320)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat QR"})
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(png)
}

// bayarTagihanHandler memindahkan saldo pemindai ke penerima tagihan.
func bayarTagihanHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "QR tidak terbaca"})
		return
	}
	isi := strings.TrimSpace(input.Token)
	if !strings.HasPrefix(isi, awalanQRTagihan) {
		writeJSONResponse(w, 400, map[string]string{"error": "QR ini bukan QR pembayaran bohAntar"})
		return
	}
	id := strings.TrimPrefix(isi, awalanQRTagihan)
	pembayar := callerPhone(r)

	// Uang pesanan dompet yang sedang berjalan sudah dijanjikan walau belum
	// berpindah. Tanpa ikut dihitung, penumpang bisa membayar tagihan dengan
	// saldo yang sebentar lagi dipakai ongkos, lalu pesanannya tekor.
	tertahan, err := dbSaldoTertahan(pembayar)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memeriksa saldo"})
		return
	}

	sekarang := time.Now().Format(time.RFC3339)
	tx, err := db.Begin()
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memulai transaksi"})
		return
	}
	defer tx.Rollback()

	// UPDATE bersyarat, bukan SELECT lalu UPDATE: dua pemindaian yang datang
	// bersamaan hanya menyisakan satu yang benar-benar mengubah baris, jadi satu
	// tagihan tidak pernah didebit dua kali. Pola yang sama dipakai
	// driverKlaimSetoranHandler dan dbClaimOrder.
	res, err := tx.Exec(
		"UPDATE tagihan_qr SET paid_at = ?, payer_phone = ? WHERE id = ? AND paid_at IS NULL AND expires_at > ?",
		waktuKeDB(sekarang), pembayar, id, waktuKeDB(sekarang),
	)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses pembayaran"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		jelaskanTagihanGagal(w, id)
		return
	}

	var jumlah, komisi float64
	var penerima, namaPenerima string
	if err := tx.QueryRow(
		"SELECT amount, komisi, penerima_phone, penerima_nama FROM tagihan_qr WHERE id = ?", id,
	).Scan(&jumlah, &komisi, &penerima, &namaPenerima); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca nominal tagihan"})
		return
	}
	if penerima == pembayar {
		writeJSONResponse(w, 400, map[string]string{"error": "QR ini tagihan Anda sendiri"})
		return
	}

	// Saldo diperiksa di dalam UPDATE, bukan dibaca dulu lalu dibandingkan: dua
	// pembayaran berbarengan dari satu akun tidak boleh sama-sama lolos
	// terhadap saldo yang sama.
	res, err = tx.Exec(
		"UPDATE users SET balance = balance - ? WHERE phone_number = ? AND balance >= ?",
		jumlah, pembayar, jumlah+tertahan,
	)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui saldo"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONResponse(w, 402, map[string]string{"error": "Saldo tidak cukup. Top up dulu, lalu pindai lagi."})
		return
	}

	// Pelanggan didebit penuh, mitra dikredit setelah potongan. Selisihnya
	// tidak dikreditkan ke mana pun — sama seperti komisi pesanan dompet, bagian
	// bohAntar adalah uang yang tidak sampai ke saldo siapa pun.
	res, err = tx.Exec("UPDATE users SET balance = balance + ? WHERE phone_number = ?", jumlah-komisi, penerima)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui saldo penerima"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONResponse(w, 410, map[string]string{"error": "Penerima tagihan sudah tidak aktif"})
		return
	}
	if err := tx.Commit(); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan pembayaran"})
		return
	}

	var saldo float64
	_ = db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", pembayar).Scan(&saldo)
	writeJSONResponse(w, 200, map[string]interface{}{
		"status":        "success",
		"message":       "Pembayaran berhasil",
		"amount":        jumlah,
		"penerima_nama": namaPenerima,
		"balance":       saldo,
	})
}

// jelaskanTagihanGagal memberi tahu kenapa pemindaiannya tidak diterima. Tanpa
// ini semua kegagalan terlihat sama, dan penumpang tidak tahu harus meminta QR
// baru atau memang salah QR.
func jelaskanTagihanGagal(w http.ResponseWriter, id string) {
	var dibayar sql.NullTime
	var kedaluwarsa time.Time
	err := db.QueryRow("SELECT paid_at, expires_at FROM tagihan_qr WHERE id = ?", id).Scan(&dibayar, &kedaluwarsa)
	switch {
	case err == sql.ErrNoRows:
		writeJSONResponse(w, 404, map[string]string{"error": "Tagihan tidak ditemukan"})
	case err != nil:
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses pembayaran"})
	case dibayar.Valid:
		writeJSONResponse(w, 409, map[string]string{"error": "Tagihan ini sudah pernah dibayar"})
	case kedaluwarsa.Before(time.Now()):
		writeJSONResponse(w, 410, map[string]string{"error": "QR sudah kedaluwarsa. Minta kasir membuat yang baru."})
	default:
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses pembayaran"})
	}
}

func ambilTagihan(id string) (tagihan, bool) {
	if id == "" {
		return tagihan{}, false
	}
	var t tagihan
	var dibayar sql.NullTime
	var created, expires time.Time
	err := db.QueryRow(
		"SELECT id, penerima_phone, penerima_nama, amount, komisi, created_at, expires_at, paid_at FROM tagihan_qr WHERE id = ?", id,
	).Scan(&t.ID, &t.PenerimaPhone, &t.PenerimaNama, &t.Amount, &t.Komisi, &created, &expires, &dibayar)
	if err != nil {
		return tagihan{}, false
	}
	t.CreatedAt = created.Format(time.RFC3339)
	t.ExpiresAt = expires.Format(time.RFC3339)
	if dibayar.Valid {
		t.PaidAt = dibayar.Time.Format(time.RFC3339)
	}
	return t, true
}
