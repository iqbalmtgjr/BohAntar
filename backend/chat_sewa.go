package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"
)

// ==================== CHAT PENYEWA ↔ MITRA RENTAL ====================
//
// Satu percakapan per sewa (rental_bookings). Penyewa di aplikasi, mitra di
// dashboard web. Sengaja REST + polling, bukan WebSocket seperti chat driver:
// urusan sewa tidak sedang ditunggu di depan gerbang, dan dashboard mitra tidak
// punya sambungan terbuka.
// ponytail: polling 4 detik selama layar chat terbuka; WebSocket kalau ramai.
//
// Tabel baru → collation bisa beda dengan rental_bookings di MariaDB produksi,
// jadi tanpa foreign key dan tanpa JOIN ke tabel lama: booking_id selalu
// dibandingkan dengan parameter.

func migrasiChatSewa() {
	migrasiSkema(`CREATE TABLE IF NOT EXISTS chat_sewa (
		id BIGINT AUTO_INCREMENT PRIMARY KEY,
		booking_id VARCHAR(50) NOT NULL,
		sender_phone VARCHAR(20) NOT NULL,
		sender_name VARCHAR(100) NOT NULL DEFAULT '',
		content TEXT NOT NULL,
		timestamp DATETIME NOT NULL,
		dibaca TINYINT(1) NOT NULL DEFAULT 0,
		INDEX idx_chat_sewa_booking (booking_id, id)
	)`)
}

type pesanSewa struct {
	ID          int64  `json:"id,string"`
	SenderPhone string `json:"sender_phone"`
	SenderName  string `json:"sender_name"`
	Content     string `json:"content"`
	Timestamp   string `json:"timestamp"`
}

const maksPesanSewa = 1000

// chatSewaHandler:
//
//	GET  /api/rental/chat/{bookingID} → {messages}, sekaligus menandai pesan lawan terbaca
//	POST /api/rental/chat/{bookingID} {content}
func chatSewaHandler(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/rental/chat/")
	me := callerPhone(r)
	var penyewa, mitra, kendaraan string
	err := db.QueryRow(`SELECT b.customer_phone, c.owner_phone, CONCAT(c.brand, ' ', c.model)
		FROM rental_bookings b JOIN rental_cars c ON c.id = b.car_id WHERE b.id = ?`, id).Scan(&penyewa, &mitra, &kendaraan)
	if err == sql.ErrNoRows {
		writeJSONResponse(w, 404, map[string]string{"error": "Sewa tidak ditemukan"})
		return
	} else if err != nil {
		galatServer(w, r, err)
		return
	}
	peserta := me == penyewa || me == mitra
	if !peserta && !isAdmin(r) {
		denyOwnership(w)
		return
	}

	switch r.Method {
	case http.MethodGet:
		// Admin yang mengintip tidak ikut menghapus lencana milik peserta.
		if peserta {
			db.Exec("UPDATE chat_sewa SET dibaca = 1 WHERE booking_id = ? AND sender_phone <> ? AND dibaca = 0", id, me)
		}
		rows, err := db.Query(`SELECT id, sender_phone, sender_name, content, DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i:%s')
			FROM chat_sewa WHERE booking_id = ? ORDER BY id`, id)
		if err != nil {
			galatServer(w, r, err)
			return
		}
		defer rows.Close()
		pesan := []pesanSewa{}
		for rows.Next() {
			var p pesanSewa
			if rows.Scan(&p.ID, &p.SenderPhone, &p.SenderName, &p.Content, &p.Timestamp) == nil {
				pesan = append(pesan, p)
			}
		}
		// Judul halaman chat di portal mitra, supaya bisa dibuka langsung dari tautan /chat/{id}.
		namaPenyewa := ""
		if u, ok := dbGetUser(penyewa); ok {
			namaPenyewa = u.Name
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "messages": pesan, "penyewa": namaPenyewa, "kendaraan": kendaraan})

	case http.MethodPost:
		if !peserta {
			writeJSONResponse(w, 403, map[string]string{"error": "Hanya penyewa dan mitra yang bisa mengirim pesan"})
			return
		}
		var input struct {
			Content string `json:"content"`
		}
		if json.NewDecoder(r.Body).Decode(&input) != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data yang dikirim tidak terbaca. Coba lagi."})
			return
		}
		isi := strings.TrimSpace(input.Content)
		if isi == "" || utf8.RuneCountInString(isi) > maksPesanSewa {
			writeJSONResponse(w, 400, map[string]string{"error": "Pesan wajib diisi, maksimal 1000 karakter"})
			return
		}
		nama := ""
		if u, ok := dbGetUser(me); ok {
			nama = u.Name
		}
		// Penyewa kenal mitranya dari nama usaha di katalog, bukan nama pemilik akun.
		if me == mitra {
			if n := businessNameOf(mitra); n != "" {
				nama = n
			}
		}
		if _, err := db.Exec("INSERT INTO chat_sewa (booking_id, sender_phone, sender_name, content, timestamp) VALUES (?, ?, ?, ?, NOW())",
			id, me, nama, isi); err != nil {
			galatServer(w, r, err)
			return
		}
		lawan := mitra
		if me == mitra {
			lawan = penyewa
		}
		judul := nama
		if judul == "" {
			judul = "Pesan baru"
		}
		notifikasiKe(lawan, judul+" · "+kendaraan, isi, map[string]string{"tipe": "chat_sewa", "booking_id": id})
		writeJSONResponse(w, 201, map[string]string{"status": "success"})

	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// isiChatBelum mengisi ringkasan chat tiap sewa untuk `me`: jumlah pesan lawan
// yang belum dibaca + pesan terakhir (daftar Chat di portal mitra). Satu kueri
// untuk semua sewa, ID dikirim sebagai parameter.
func isiChatBelum(bookings []RentalBooking, me string) {
	if len(bookings) == 0 {
		return
	}
	args := []any{me}
	for _, b := range bookings {
		args = append(args, b.ID)
	}
	rows, err := db.Query(`SELECT booking_id, belum, content, sender_phone, DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i:%s') FROM (
			SELECT booking_id, content, sender_phone, timestamp,
				ROW_NUMBER() OVER (PARTITION BY booking_id ORDER BY id DESC) AS urut,
				SUM(CASE WHEN dibaca = 0 AND sender_phone <> ? THEN 1 ELSE 0 END) OVER (PARTITION BY booking_id) AS belum
			FROM chat_sewa WHERE booking_id IN (`+strings.TrimSuffix(strings.Repeat("?,", len(bookings)), ",")+`)
		) t WHERE urut = 1`, args...)
	if err != nil {
		log.Printf("ringkasan chat sewa gagal dibaca: %v", err)
		return
	}
	defer rows.Close()
	type ringkas struct {
		belum            int
		isi, dari, waktu string
	}
	per := map[string]ringkas{}
	for rows.Next() {
		var id string
		var r ringkas
		if rows.Scan(&id, &r.belum, &r.isi, &r.dari, &r.waktu) == nil {
			per[id] = r
		}
	}
	for i := range bookings {
		r := per[bookings[i].ID]
		bookings[i].ChatBelum, bookings[i].ChatTerakhir, bookings[i].ChatWaktu = r.belum, r.isi, r.waktu
		bookings[i].ChatDariSaya = r.dari == me
	}
}

// hapusChatSewa: bagian hapusAkun. Sewa milik akun ini (sebagai penyewa atau
// pemilik armada) ikut terhapus lewat ON DELETE CASCADE, percakapannya tidak —
// tabel ini sengaja tanpa foreign key.
func hapusChatSewa(tx *sql.Tx, phone string) error {
	rows, err := tx.Query(`SELECT b.id FROM rental_bookings b JOIN rental_cars c ON c.id = b.car_id
		WHERE b.customer_phone = ? OR c.owner_phone = ?`, phone, phone)
	if err != nil {
		return err
	}
	var ids []any
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if _, err := tx.Exec("DELETE FROM chat_sewa WHERE sender_phone = ?", phone); err != nil {
		return err
	}
	if len(ids) == 0 {
		return nil
	}
	_, err = tx.Exec("DELETE FROM chat_sewa WHERE booking_id IN ("+strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")+")", ids...)
	return err
}
