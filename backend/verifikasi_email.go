package main

import (
	"crypto/hmac"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ==================== VERIFIKASI EMAIL SAAT DAFTAR ====================
//
// Cadangan verifikasi WhatsApp (verifikasi_wa.go) untuk pendaftaran akun
// email+password di aplikasi: kode 6 digit dikirim ke email, pendaftar
// mengetiknya. Akun lahir bila SALAH SATU terverifikasi — nomor WA atau email
// (permintaan user 19 Nov 2026, setelah ada akun testuser@gmail.com tengah malam).
// Daftar lewat Google tidak memakai ini: emailnya sudah diverifikasi Google.
//
// Mati selama VERIFIKASI_EMAIL kosong atau SMTP belum diatur, supaya binary bisa
// naik sebelum AAB yang punya lembar kode tayang. Sesudah dinyalakan, APK lama
// (tidak mengirim kode_email) diminta memperbarui aplikasi.
//   VERIFIKASI_EMAIL=1

func emailVerifAktif() bool { return getEnv("VERIFIKASI_EMAIL", "") != "" && emailAktif() }

type verifEmail struct {
	kode          string
	kedaluwarsa   time.Time
	salah         int
	terverifikasi bool
	kirim         []time.Time // pengiriman dalam satu jam terakhir
}

const (
	umurVerifEmail   = 15 * time.Minute
	jedaKirimEmail   = time.Minute
	kirimEmailPerJam = 5 // per alamat; menahan pengeboman kotak masuk orang lain
	salahKodeMaks    = 5 // 5 tebakan dari sejuta per kode
)

// ponytail: di memori seperti verifikasi WA; restart backend = minta kode lagi.
var (
	verifEmailMu sync.Mutex
	verifEmailKe = map[string]*verifEmail{} // email → kode terakhir
)

// emailDaftarValid: bentuk nama@domain.tld, tanpa karakter yang bisa menyisipkan header.
func emailDaftarValid(email string) bool {
	at := strings.LastIndex(email, "@")
	return at > 0 && len(email) <= 254 && strings.Contains(email[at+1:], ".") &&
		!strings.HasSuffix(email, ".") && !strings.ContainsAny(email, " \t\r\n,;<>\"")
}

// buatKodeVerifEmail menerbitkan kode baru untuk email itu, atau pesan tunggu
// bila terlalu sering diminta.
func buatKodeVerifEmail(email string) (kode, tunggu string) {
	verifEmailMu.Lock()
	defer verifEmailMu.Unlock()
	sekarang := time.Now()
	for k, v := range verifEmailKe {
		if sekarang.After(v.kedaluwarsa) && (len(v.kirim) == 0 || sekarang.Sub(v.kirim[len(v.kirim)-1]) > time.Hour) {
			delete(verifEmailKe, k)
		}
	}
	v := verifEmailKe[email]
	if v == nil {
		v = &verifEmail{}
		verifEmailKe[email] = v
	}
	hidup := v.kirim[:0]
	for _, t := range v.kirim {
		if sekarang.Sub(t) < time.Hour {
			hidup = append(hidup, t)
		}
	}
	v.kirim = hidup
	if n := len(v.kirim); n > 0 && sekarang.Sub(v.kirim[n-1]) < jedaKirimEmail {
		return "", "Tunggu sebentar, kode baru bisa diminta satu menit sekali."
	}
	if len(v.kirim) >= kirimEmailPerJam {
		return "", "Sudah terlalu sering minta kode ke email ini. Coba lagi satu jam lagi."
	}
	v.kode, v.kedaluwarsa, v.salah, v.terverifikasi = newOTP(), sekarang.Add(umurVerifEmail), 0, false
	v.kirim = append(v.kirim, sekarang)
	return v.kode, ""
}

// cekKodeEmail dipanggil saat pendaftar mengetik kode. Pesan kosong = cocok.
func cekKodeEmail(email, kode string) string {
	verifEmailMu.Lock()
	defer verifEmailMu.Unlock()
	v := verifEmailKe[email]
	switch {
	case v == nil || time.Now().After(v.kedaluwarsa):
		return "Kodenya sudah kedaluwarsa. Tekan Kirim ulang untuk kode baru."
	case v.salah >= salahKodeMaks:
		return "Terlalu banyak kode salah. Tekan Kirim ulang untuk kode baru."
	case !hmac.Equal([]byte(kode), []byte(v.kode)):
		v.salah++
		return "Kodenya belum cocok. Cek lagi email dari BohAntar."
	}
	v.terverifikasi = true
	return ""
}

// cekVerifEmail dipakai sebelum akun dibuat. Pesan kosong = email terverifikasi.
func cekVerifEmail(kode, email string) string {
	verifEmailMu.Lock()
	defer verifEmailMu.Unlock()
	v := verifEmailKe[email]
	if v == nil || time.Now().After(v.kedaluwarsa) {
		return "Kode verifikasi email kedaluwarsa. Ulangi pendaftaran."
	}
	if !v.terverifikasi || !hmac.Equal([]byte(kode), []byte(v.kode)) {
		return "Email belum terverifikasi. Ketik dulu kode dari emailmu."
	}
	return ""
}

// habiskanVerifEmail: satu kode satu akun.
func habiskanVerifEmail(email string) {
	verifEmailMu.Lock()
	delete(verifEmailKe, email)
	verifEmailMu.Unlock()
}

// cekVerifDaftar: syarat pendaftaran email+password — nomor WA ATAU email
// terverifikasi, mana pun yang sedang dinyalakan. Pesan kosong = boleh lanjut.
func cekVerifDaftar(kodeWA, phone, kodeEmail, email string) string {
	// kode_email hanya dihitung saat verifikasi email menyala; kalau tidak,
	// kode karangan bisa dipakai melewati verifikasi WA.
	if kodeEmail != "" && emailVerifAktif() {
		return cekVerifEmail(kodeEmail, email)
	}
	if waVerifikasiAktif() || !emailVerifAktif() {
		return cekVerifWA(kodeWA, phone) // kosong bila WA juga mati
	}
	return "Perbarui aplikasi BohAntar dari Play Store untuk mendaftar."
}

// verifikasiEmailHandler:
//
//	POST /api/auth/verifikasi-email {email}       → kirim kode: {wajib}
//	POST /api/auth/verifikasi-email {email, kode} → cek kode: {terverifikasi}
func verifikasiEmailHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var in struct {
		Email string `json:"email"`
		Kode  string `json:"kode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Data yang dikirim tidak terbaca. Coba lagi."})
		return
	}
	if !emailVerifAktif() {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "wajib": false})
		return
	}
	email := strings.ToLower(strings.TrimSpace(in.Email))

	if in.Kode != "" {
		if pesan := cekKodeEmail(email, strings.TrimSpace(in.Kode)); pesan != "" {
			writeJSONResponse(w, 400, map[string]string{"error": pesan})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "terverifikasi": true})
		return
	}

	// Setiap kiriman dihitung: tiap kode adalah satu email keluar atas nama BohAntar.
	rem := "verif-email:" + alamatPemanggil(r)
	if terlaluSeringGagal(rem) {
		writeJSONResponse(w, 429, map[string]string{"error": "Terlalu banyak percobaan dari jaringan ini. Coba lagi 15 menit lagi."})
		return
	}
	catatGagalLogin(rem)
	if !emailDaftarValid(email) {
		writeJSONResponse(w, 400, map[string]string{"error": "Tulis email dengan benar, contoh nama@gmail.com."})
		return
	}
	if _, _, ada := dbFindUserByEmail(email); ada {
		writeJSONResponse(w, 409, map[string]string{"error": "Email ini sudah terdaftar. Silakan masuk."})
		return
	}
	kode, tunggu := buatKodeVerifEmail(email)
	if tunggu != "" {
		writeJSONResponse(w, 429, map[string]string{"error": tunggu})
		return
	}
	kirimEmail(email, "Kode daftar BohAntar: "+kode, fmt.Sprintf(
		"Halo,\n\nIni kode untuk mendaftar di BohAntar:\n\n    %s\n\n"+
			"Ketik kode ini di aplikasi. Berlaku 15 menit.\n\n"+
			"Tidak merasa mendaftar? Abaikan saja email ini. Tanpa kode ini tidak ada akun yang dibuat.\n\n— BohAntar\n", kode))
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "wajib": true})
}
