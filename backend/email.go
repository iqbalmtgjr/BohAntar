package main

import (
	"encoding/json"
	"log"
	"mime"
	"net/http"
	"net/smtp"
	"strings"
	"sync"
	"time"
)

// ==================== EMAIL (Brevo SMTP) ====================
//
// Env di run.sh:
//
//	SMTP_HOST/PORT/USER/PASS  smtp-relay.brevo.com, 587, login SMTP Brevo, kunci SMTP
//	SMTP_FROM          noreply@indotechconsulting.com (domain terautentikasi di
//	                   Brevo; kosong = SMTP_USER)
//	BREVO_API_KEY      opsional, hanya untuk membaca sisa kuota di menu "Kuota
//	                   Layanan" (Brevo → SMTP & API → API Keys; beda dengan
//	                   kunci SMTP)
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
		penerima := strings.Split(ke, ",")
		if err := smtp.SendMail(host+":"+getEnv("SMTP_PORT", "587"), auth, dari, penerima, []byte(pesan)); err != nil {
			log.Printf("Email ke %s gagal dikirim: %v", ke, err)
			catatEmail(func(p *pemakaianEmail) { p.Gagal += len(penerima) })
			return
		}
		catatEmail(func(p *pemakaianEmail) { p.Terkirim += len(penerima) })
	}()
}

// ---------- KUOTA HARIAN BREVO ----------
//
// Paket gratis Brevo: 300 email per hari, sisa tidak terbawa ke besok
// (help.brevo.com/hc/en-us/articles/208580669). Lewat batas, SMTP menolak
// dan kirimEmail hanya mencatat gagal. Brevo menghitung per penerima.
//
// ponytail: hitungan di memori seperti hariPlaces, kembali nol saat restart
// dan hanya melihat kiriman backend ini. Angka asli (termasuk aplikasi lain
// di akun Brevo yang sama) datang dari BREVO_API_KEY bila diisi.

const batasHarianEmail = 300

type pemakaianEmail struct {
	Tanggal  string `json:"tanggal"`
	Terkirim int    `json:"terkirim"`
	Gagal    int    `json:"gagal"`
}

var (
	muEmail   sync.Mutex
	hariEmail pemakaianEmail
	// brevoAPI bisa ditimpa tes.
	brevoAPI    = "https://api.brevo.com/v3/account"
	brevoClient = &http.Client{Timeout: 8 * time.Second}
)

func catatEmail(ubah func(*pemakaianEmail)) pemakaianEmail {
	muEmail.Lock()
	defer muEmail.Unlock()
	if hari := time.Now().In(zonaWIB).Format("2006-01-02"); hariEmail.Tanggal != hari {
		hariEmail = pemakaianEmail{Tanggal: hari}
	}
	if ubah != nil {
		ubah(&hariEmail)
	}
	return hariEmail
}

// sisaKreditBrevo: kredit kirim email yang tersisa menurut Brevo (paket
// gratis = sisa jatah hari ini). -1 kalau BREVO_API_KEY kosong atau Brevo
// tak menjawab; galat hanya ke log supaya halaman kuota tetap tampil.
func sisaKreditBrevo() (sisa float64, paket string) {
	kunci := getEnv("BREVO_API_KEY", "")
	if kunci == "" {
		return -1, ""
	}
	req, _ := http.NewRequest(http.MethodGet, brevoAPI, nil)
	req.Header.Set("api-key", kunci)
	req.Header.Set("Accept", "application/json")
	res, err := brevoClient.Do(req)
	if err != nil {
		log.Printf("Brevo akun: %v", err)
		return -1, ""
	}
	defer res.Body.Close()
	var akun struct {
		Plan []struct {
			Type        string  `json:"type"`
			CreditsType string  `json:"creditsType"`
			Credits     float64 `json:"credits"`
		} `json:"plan"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(res.Body).Decode(&akun) != nil {
		log.Printf("Brevo akun: status %d", res.StatusCode)
		return -1, ""
	}
	for _, p := range akun.Plan {
		if p.Type != "sms" && p.CreditsType == "sendLimit" {
			return p.Credits, p.Type
		}
	}
	return -1, ""
}

// adminKuotaHandler: GET /api/admin/kuota — jatah harian layanan pihak
// ketiga yang gratis/terbatas, satu halaman di dashboard super admin.
func adminKuotaHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	sisa, paket := sisaKreditBrevo()
	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"peta": map[string]interface{}{
			"pemakaian":    catatPlaces(nil),
			"batas_harian": batasHarianPlaces(),
			"kunci_google": mapsAPIKey() != "",
		},
		"email": map[string]interface{}{
			"pemakaian":    catatEmail(nil),
			"batas_harian": batasHarianEmail,
			"aktif":        emailAktif(),
			"sisa_brevo":   sisa,
			"paket_brevo":  paket,
		},
	})
}
