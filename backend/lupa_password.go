package main

import (
	"cmp"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strings"
	"time"
)

// ==================== LUPA PASSWORD LEWAT EMAIL (16 Nov 2026) ====================
//
// Untuk semua email, bukan hanya Gmail (jalur Google: resetPasswordGoogleHandler).
// App/dashboard mengirim email akun → server mengirim tautan sekali pakai →
// tautan membuka halaman web di sini untuk membuat password baru. Formulirnya
// di web, jadi app cukup punya satu tombol.
//
// ponytail: sesi lain (token JWT 7 hari) tidak dicabut saat password diganti;
// tambah kolom password_changed_at yang dicek sesiPemanggil kalau perlu.

const (
	resetBerlaku        = 30 * time.Minute
	resetPerEmailPerJam = 3  // menahan bom email ke satu orang
	resetPerIPPerJam    = 10 // dan kuota Brevo 300/hari yang dipakai bersama
)

// migrasiResetPassword: yang disimpan hash token, bukan tokennya — bocornya
// tabel tidak membuka akun siapa pun. phone_number kosong = email tak
// terdaftar; barisnya hanya untuk rem laju. Tanpa FK ke users (pola tabel baru).
func migrasiResetPassword() {
	migrasiSkema(`CREATE TABLE IF NOT EXISTS reset_password (
		token_hash CHAR(64) PRIMARY KEY,
		phone_number VARCHAR(20) NOT NULL,
		email VARCHAR(255) NOT NULL,
		ip VARCHAR(64) NOT NULL,
		created_at DATETIME NOT NULL,
		used_at DATETIME NULL,
		INDEX idx_reset_email (email, created_at),
		INDEX idx_reset_ip (ip, created_at)
	)`)
}

const pesanResetTerkirim = "Kalau email itu terdaftar, tautan untuk membuat password baru sudah dikirim. Cek Kotak Masuk dan folder Spam."

func hashTokenReset(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

// lupaPasswordHandler: POST /api/auth/lupa-password {email}
//
// Balasannya sama untuk email terdaftar maupun tidak, supaya endpoint ini tidak
// bisa dipakai menebak siapa saja yang punya akun.
func lupaPasswordHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input struct {
		Email string `json:"email"`
	}
	_ = json.NewDecoder(r.Body).Decode(&input)
	email := strings.ToLower(strings.TrimSpace(input.Email))
	if !strings.Contains(email, "@") || len(email) > 254 || strings.ContainsAny(email, "\r\n ") {
		writeJSONResponse(w, 400, map[string]string{"error": "Tulis email akunmu dengan benar"})
		return
	}
	if !emailAktif() {
		writeJSONResponse(w, 503, map[string]string{"error": "Atur ulang lewat email belum aktif. Pakai Google atau hubungi admin."})
		return
	}
	if pesan := tolakTurnstile(r, false); pesan != "" {
		writeJSONResponse(w, 403, map[string]string{"error": pesan})
		return
	}

	ip := alamatPemanggil(r)
	sejamLalu := waktuKeDB(time.Now().Add(-time.Hour).Format(time.RFC3339))
	var perEmail, perIP int
	errE := db.QueryRow("SELECT COUNT(*) FROM reset_password WHERE email = ? AND created_at > ?", email, sejamLalu).Scan(&perEmail)
	errI := db.QueryRow("SELECT COUNT(*) FROM reset_password WHERE ip = ? AND created_at > ?", ip, sejamLalu).Scan(&perIP)
	if errE != nil || errI != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses permintaan. Coba lagi sebentar."})
		return
	}
	if perEmail >= resetPerEmailPerJam || perIP >= resetPerIPPerJam {
		writeJSONResponse(w, 429, map[string]string{"error": "Terlalu banyak permintaan. Cek email yang sudah dikirim, atau coba lagi satu jam lagi."})
		return
	}

	u, _, terdaftar := dbFindUserByEmail(email)
	phone := ""
	switch {
	case terdaftar && u.Role == "admin":
		// Sama dengan jalur Google: akun admin tidak bisa diambil alih lewat email.
		log.Printf("lupa password untuk akun admin %s diabaikan", u.PhoneNumber)
	case terdaftar:
		phone = u.PhoneNumber
	}

	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat tautan"})
		return
	}
	token := hex.EncodeToString(b)
	if _, err := db.Exec(
		"INSERT INTO reset_password (token_hash, phone_number, email, ip, created_at) VALUES (?, ?, ?, ?, ?)",
		hashTokenReset(token), phone, email, ip, waktuKeDB(time.Now().Format(time.RFC3339)),
	); err != nil {
		log.Printf("lupa password: gagal menyimpan token: %v", err)
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memproses permintaan. Coba lagi sebentar."})
		return
	}

	if phone != "" {
		alamat := alamatPublik
		if !isProduction() {
			alamat = "http://" + r.Host
		}
		kirimEmail(u.Email, "Buat password baru BohAntar", fmt.Sprintf(
			"Halo %s,\n\nAda permintaan membuat password baru untuk akun BohAntar dengan email ini. "+
				"Buka tautan berikut (berlaku 30 menit, sekali pakai):\n\n%s/api/reset-password/%s\n\n"+
				"Tidak merasa meminta? Abaikan email ini, password lamamu tetap berlaku.\n\n— BohAntar\n",
			cmp.Or(strings.TrimSpace(u.Name), "pengguna BohAntar"), alamat, token))
	}
	writeJSONResponse(w, 200, map[string]string{"status": "success", "message": pesanResetTerkirim})
}

var halamanResetPassword = template.Must(template.New("reset").Parse(`<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Password baru BohAntar</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;max-width:420px;margin:0 auto;padding:32px 16px;color:#1a1a1a;background:#f3f6fb;line-height:1.5}
.kartu{background:#fff;border-radius:16px;padding:24px 20px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
h1{font-size:22px;margin:0 0 4px}small{color:#5f6b7a}
label{display:block;font-weight:600;margin:16px 0 6px}
input{width:100%;box-sizing:border-box;padding:12px;border:1px solid #c9d2de;border-radius:10px;font-size:16px}
input:focus{outline:2px solid #1565c0;border-color:#1565c0}
button{width:100%;margin-top:20px;padding:14px;border:0;border-radius:10px;background:#1565c0;color:#fff;font-size:16px;font-weight:700}
.galat{background:#f8d7da;color:#842029;padding:10px 12px;border-radius:10px;margin-top:16px}
.ok{color:#1e6b34}
</style></head><body><div class="kartu">
{{if eq .Keadaan "form"}}
<h1>Buat password baru</h1><small>Untuk akun {{.Email}}</small>
{{if .Galat}}<div class="galat" role="alert">{{.Galat}}</div>{{end}}
<form method="post">
<label for="p">Password baru</label>
<input id="p" name="password" type="password" minlength="8" maxlength="72" autocomplete="new-password" required>
<label for="u">Ulangi password baru</label>
<input id="u" name="ulang" type="password" minlength="8" maxlength="72" autocomplete="new-password" required>
<button type="submit">Simpan password</button>
</form>
{{else if eq .Keadaan "selesai"}}
<h1 class="ok">Password baru tersimpan</h1>
<p>Kembali ke aplikasi atau dashboard BohAntar, lalu masuk dengan email {{.Email}} dan password barumu.</p>
{{else}}
<h1>Tautan sudah tidak berlaku</h1>
<p>Tautan ini sudah dipakai atau lewat 30 menit. Minta tautan baru lewat "Lupa password?" di layar masuk.</p>
{{end}}
</div></body></html>`))

// samarkanEmail: "budi@gmail.com" → "b***@gmail.com".
func samarkanEmail(email string) string {
	at := strings.IndexByte(email, '@')
	if at < 1 {
		return email
	}
	return email[:1] + "***" + email[at:]
}

// resetPasswordHalamanHandler: GET/POST /api/reset-password/{token}
//
// GET hanya menampilkan formulir, tidak memakai token: pemindai tautan di
// kotak masuk (Gmail, antivirus) membuka tautan lebih dulu dari pemiliknya.
func resetPasswordHalamanHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer") // token ada di URL
	tampil := func(keadaan, email, galat string) {
		halamanResetPassword.Execute(w, map[string]string{"Keadaan": keadaan, "Email": samarkanEmail(email), "Galat": galat})
	}

	h := hashTokenReset(strings.TrimPrefix(r.URL.Path, "/api/reset-password/"))
	batas := waktuKeDB(time.Now().Add(-resetBerlaku).Format(time.RFC3339))
	var phone, email string
	// Kedaluwarsa dihitung di SQL, sama dengan rem laju: tidak bergantung
	// pada zona waktu yang dipakai driver MySQL saat memindai DATETIME.
	if err := db.QueryRow(`SELECT phone_number, email FROM reset_password
		WHERE token_hash = ? AND used_at IS NULL AND created_at > ? AND phone_number <> ''`, h, batas).
		Scan(&phone, &email); err != nil {
		tampil("basi", "", "")
		return
	}
	if r.Method != http.MethodPost {
		tampil("form", email, "")
		return
	}

	p, ulang := r.PostFormValue("password"), r.PostFormValue("ulang")
	switch {
	case len(p) < 8: // sama dengan syarat ganti password di profil
		tampil("form", email, "Password minimal 8 karakter.")
		return
	case len(p) > 72: // batas bcrypt
		tampil("form", email, "Password maksimal 72 karakter.")
		return
	case p != ulang:
		tampil("form", email, "Kedua password tidak sama.")
		return
	}

	sekarang := waktuKeDB(time.Now().Format(time.RFC3339))
	// Bersyarat used_at IS NULL: dua kiriman formulir bersamaan hanya satu yang lolos.
	res, err := db.Exec("UPDATE reset_password SET used_at = ? WHERE token_hash = ? AND used_at IS NULL", sekarang, h)
	if err != nil {
		tampil("form", email, "Gagal menyimpan. Coba lagi sebentar.")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		tampil("basi", "", "")
		return
	}
	if err := dbSetPassword(phone, p); err != nil {
		log.Printf("lupa password: gagal menyimpan password %s: %v", phone, err)
		tampil("form", email, "Gagal menyimpan. Minta tautan baru lalu coba lagi.")
		return
	}
	// Tautan lain yang masih hidup untuk akun ini ikut mati.
	db.Exec("UPDATE reset_password SET used_at = ? WHERE phone_number = ? AND used_at IS NULL", sekarang, phone)
	log.Printf("lupa password: %s membuat password baru lewat email", phone)
	tampil("selesai", email, "")
}
