package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// ==================== SETORAN KOMISI TUNAI ====================
//
// Pesanan tunai membuat saldo driver minus: penumpang membayar langsung ke
// driver, dan komisi kami dipotong dari saldonya sampai ia menyetor. Sebelum ini
// tidak ada satu pun jalur untuk melunasinya — angkanya cuma menumpuk.
//
// Alurnya sengaja dua tangan:
//
//  1. Driver menyerahkan uang tunai ke petugas.
//  2. Petugas membuat setoran di dashboard sebesar uang yang DITERIMA, lalu
//     menunjukkan QR-nya.
//  3. Driver memindai QR itu; saldonya naik sebesar nominal tadi.
//
// Saldo tidak pernah naik hanya karena driver memindai sesuatu: barisnya dibuat
// petugas yang memegang uangnya, dan hanya berlaku untuk nomor driver itu.
const masaBerlakuSetoran = 15 * time.Minute

type setoran struct {
	ID          string  `json:"id"`
	DriverPhone string  `json:"driver_phone"`
	Amount      float64 `json:"amount"`
	CreatedAt   string  `json:"created_at"`
	ExpiresAt   string  `json:"expires_at"`
	ClaimedAt   string  `json:"claimed_at,omitempty"`
}

// adminSetoranHandler membuat setoran baru (POST) atau membaca statusnya (GET),
// supaya halaman petugas tahu kapan QR-nya sudah dipindai driver.
func adminSetoranHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		var input struct {
			DriverPhone string  `json:"driver_phone"`
			Amount      float64 `json:"amount"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data setoran tidak terbaca"})
			return
		}
		input.DriverPhone = normalizePhone(input.DriverPhone)
		if input.Amount <= 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Nominal setoran harus lebih dari nol"})
			return
		}

		// Menyetor melebihi utangnya berarti saldo driver jadi positif — itu uang
		// muka, bukan setoran komisi, dan belum ada alur penarikannya.
		var saldo float64
		var peran string
		err := db.QueryRow("SELECT balance, role FROM users WHERE phone_number = ?", input.DriverPhone).Scan(&saldo, &peran)
		if err == sql.ErrNoRows {
			writeJSONResponse(w, 404, map[string]string{"error": "Driver tidak ditemukan"})
			return
		} else if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca data driver"})
			return
		}
		if peran != "driver" {
			writeJSONResponse(w, 400, map[string]string{"error": "Nomor ini bukan driver"})
			return
		}
		if saldo >= 0 {
			writeJSONResponse(w, 409, map[string]string{"error": "Driver ini tidak punya komisi yang belum disetor"})
			return
		}
		if input.Amount > -saldo {
			writeJSONResponse(w, 409, map[string]string{"error": "Nominal melebihi komisi yang belum disetor"})
			return
		}

		s := setoran{
			ID:          newID("setor"),
			DriverPhone: input.DriverPhone,
			Amount:      input.Amount,
			CreatedAt:   time.Now().Format(time.RFC3339),
			ExpiresAt:   time.Now().Add(masaBerlakuSetoran).Format(time.RFC3339),
		}
		if _, err := db.Exec(
			"INSERT INTO setoran_komisi (id, driver_phone, amount, dibuat_oleh, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
			s.ID, s.DriverPhone, s.Amount, callerPhone(r), waktuKeDB(s.CreatedAt), waktuKeDB(s.ExpiresAt),
		); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan setoran"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "setoran": s})

	case http.MethodGet:
		s, ok := ambilSetoran(r.URL.Query().Get("id"))
		if !ok {
			writeJSONResponse(w, 404, map[string]string{"error": "Setoran tidak ditemukan"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "setoran": s})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// adminSetoranQRHandler menggambar QR-nya di server, jadi dashboard tidak perlu
// pustaka QR sendiri.
//
// Isi QR-nya cuma id setoran — tanpa nominal maupun nomor telepon. QR yang
// terfoto orang lain tidak membocorkan apa pun, dan tetap tidak bisa diklaim
// siapa pun selain driver yang barisnya menyebut nomornya.
func adminSetoranQRHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/admin/setoran/qr/")
	if _, ok := ambilSetoran(id); !ok {
		writeJSONResponse(w, 404, map[string]string{"error": "Setoran tidak ditemukan"})
		return
	}
	png, err := qrcode.Encode(awalanQRSetoran+id, qrcode.Medium, 320)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat QR"})
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(png)
}

const awalanQRSetoran = "bohantar:setoran:"

// driverKlaimSetoranHandler menaikkan saldo driver sebesar setoran yang dipindai.
func driverKlaimSetoranHandler(w http.ResponseWriter, r *http.Request) {
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
	if !strings.HasPrefix(isi, awalanQRSetoran) {
		writeJSONResponse(w, 400, map[string]string{"error": "QR ini bukan QR setoran bohAntar"})
		return
	}
	id := strings.TrimPrefix(isi, awalanQRSetoran)
	phone := callerPhone(r)
	sekarang := time.Now().Format(time.RFC3339)

	tx, err := db.Begin()
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memulai transaksi"})
		return
	}
	defer tx.Rollback()

	// UPDATE bersyarat, bukan SELECT lalu UPDATE: dua pemindaian yang datang
	// bersamaan hanya menyisakan satu yang benar-benar mengubah baris, jadi satu
	// setoran tidak pernah dikreditkan dua kali. Pola yang sama dipakai
	// dbClaimOrder untuk pesanan yang direbut banyak driver.
	res, err := tx.Exec(
		"UPDATE setoran_komisi SET claimed_at = ? WHERE id = ? AND driver_phone = ? AND claimed_at IS NULL AND expires_at > ?",
		waktuKeDB(sekarang), id, phone, waktuKeDB(sekarang),
	)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses setoran"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		jelaskanSetoranGagal(w, id, phone)
		return
	}

	var jumlah float64
	if err := tx.QueryRow("SELECT amount FROM setoran_komisi WHERE id = ?", id).Scan(&jumlah); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca nominal setoran"})
		return
	}
	if _, err := tx.Exec("UPDATE users SET balance = balance + ? WHERE phone_number = ?", jumlah, phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui saldo"})
		return
	}
	if err := tx.Commit(); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan setoran"})
		return
	}

	var saldo float64
	_ = db.QueryRow("SELECT balance FROM users WHERE phone_number = ?", phone).Scan(&saldo)
	writeJSONResponse(w, 200, map[string]interface{}{
		"status":  "success",
		"message": "Setoran diterima",
		"amount":  jumlah,
		"balance": saldo,
	})
}

// jelaskanSetoranGagal memberi tahu driver kenapa pemindaiannya tidak diterima.
// Tanpa ini semua kegagalan terlihat sama, dan driver tidak tahu harus meminta
// QR baru atau memang salah QR.
func jelaskanSetoranGagal(w http.ResponseWriter, id, phone string) {
	var pemilik string
	var claimed sql.NullTime
	var kedaluwarsa time.Time
	err := db.QueryRow("SELECT driver_phone, claimed_at, expires_at FROM setoran_komisi WHERE id = ?", id).
		Scan(&pemilik, &claimed, &kedaluwarsa)
	switch {
	case err == sql.ErrNoRows:
		writeJSONResponse(w, 404, map[string]string{"error": "Setoran tidak ditemukan"})
	case err != nil:
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses setoran"})
	case claimed.Valid:
		writeJSONResponse(w, 409, map[string]string{"error": "Setoran ini sudah pernah dipindai"})
	case pemilik != phone:
		writeJSONResponse(w, 403, map[string]string{"error": "QR ini dibuat untuk driver lain"})
	case kedaluwarsa.Before(time.Now()):
		writeJSONResponse(w, 410, map[string]string{"error": "QR sudah kedaluwarsa. Minta petugas membuat yang baru."})
	default:
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses setoran"})
	}
}

func ambilSetoran(id string) (setoran, bool) {
	if id == "" {
		return setoran{}, false
	}
	var s setoran
	var claimed sql.NullTime
	var created, expires time.Time
	err := db.QueryRow(
		"SELECT id, driver_phone, amount, created_at, expires_at, claimed_at FROM setoran_komisi WHERE id = ?", id,
	).Scan(&s.ID, &s.DriverPhone, &s.Amount, &created, &expires, &claimed)
	if err != nil {
		return setoran{}, false
	}
	s.CreatedAt = created.Format(time.RFC3339)
	s.ExpiresAt = expires.Format(time.RFC3339)
	if claimed.Valid {
		s.ClaimedAt = claimed.Time.Format(time.RFC3339)
	}
	return s, true
}
