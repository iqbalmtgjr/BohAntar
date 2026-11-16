package main

import (
	"log"
	"mime"
	"net/smtp"
	"strings"
	"time"
)

// ==================== EMAIL (Brevo SMTP) ====================
//
// Env di run.sh:
//
//	SMTP_HOST/PORT/USER/PASS  smtp-relay.brevo.com, 587, login SMTP Brevo, kunci SMTP
//	SMTP_FROM          noreply@indotechconsulting.com (domain terautentikasi di
//	                   Brevo; kosong = SMTP_USER)
//
// Brevo memblokir IP yang belum diizinkan (Security → Authorized IPs): IP VPS
// harus ada di sana. Jangan kirim lewat Gmail ke alamat yang diteruskan balik
// ke Gmail yang sama: Gmail menganggapnya duplikat dan tak menaruhnya di Kotak Masuk.

func emailAktif() bool { return getEnv("SMTP_HOST", "") != "" }

// kirimEmail mengirim teks biasa lewat SMTP STARTTLS di goroutine; ke boleh
// berisi beberapa alamat dipisah koma. Mati diam-diam kalau SMTP_HOST atau
// penerima kosong; galat hanya ke log.
func kirimEmail(ke, judul, isi string) {
	ke = strings.ReplaceAll(ke, " ", "")
	// CR/LF di alamat berarti header sisipan; alamat sah tidak pernah memuatnya.
	if !emailAktif() || ke == "" || strings.ContainsAny(ke, "\r\n") {
		return
	}
	host := getEnv("SMTP_HOST", "")
	login := getEnv("SMTP_USER", "")
	dari := getEnv("SMTP_FROM", login)
	// Subjek bisa memuat ketikan pengguna (nama): QEncoding menyandikan CR/LF,
	// jadi tidak bisa menyisipkan header.
	pesan := "From: BohAntar <" + dari + ">\r\nTo: " + ke +
		"\r\nSubject: " + mime.QEncoding.Encode("utf-8", judul) +
		"\r\nDate: " + time.Now().Format(time.RFC1123Z) +
		"\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" +
		strings.ReplaceAll(isi, "\n", "\r\n")
	go func() {
		auth := smtp.PlainAuth("", login, getEnv("SMTP_PASS", ""), host)
		if err := smtp.SendMail(host+":"+getEnv("SMTP_PORT", "587"), auth, dari, strings.Split(ke, ","), []byte(pesan)); err != nil {
			log.Printf("Email ke %s gagal dikirim: %v", ke, err)
		}
	}()
}
