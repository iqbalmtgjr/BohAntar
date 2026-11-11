package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// ==================== VERIFIKASI NOMOR LEWAT WHATSAPP ====================
//
// Dulu siapa pun bisa daftar dengan nomor karangan (+6289539876543), dan nomor
// itulah yang ditelepon driver dan mitra rental. Verifikasinya "terbalik":
// pendaftar MENGIRIM kode ke nomor WhatsApp BohAntar, Meta meneruskan pesannya
// ke webhook di sini (WhatsApp Cloud API), dan nomor pengirimnya dicocokkan
// dengan nomor yang didaftarkan. Pesan masuk tidak ditagih Meta, jadi tidak
// ada biaya per pendaftaran, dan nomor pengirim tidak bisa dipalsukan.
//
// Mati selama WA_NOMOR atau WA_APP_SECRET kosong: pendaftaran berjalan seperti
// sebelum fitur ini ada, supaya binary bisa naik sebelum akun Meta siap.
//   WA_NOMOR        nomor WhatsApp BohAntar, format 628…
//   WA_APP_SECRET   App Secret aplikasi Meta (memeriksa tanda tangan webhook)
//   WA_VERIFY_TOKEN teks bebas, sama dengan isian "Verify token" di Meta

func waVerifikasiAktif() bool {
	return getEnv("WA_NOMOR", "") != "" && getEnv("WA_APP_SECRET", "") != ""
}

type verifWA struct {
	phone         string
	kedaluwarsa   time.Time
	terverifikasi bool
}

const umurVerifWA = 15 * time.Minute

// ponytail: di memori; restart backend di tengah pendaftaran = minta kode lagi.
var (
	verifWAMu sync.Mutex
	verifWA6  = map[string]*verifWA{} // kode 6 digit → pendaftaran
)

var polaNomorSeluler = regexp.MustCompile(`^\+628[0-9]{8,11}$`)

// nomorHPValid: nomor seluler Indonesia setelah normalizePhone, 08xx 10–13 digit.
func nomorHPValid(phone string) bool { return polaNomorSeluler.MatchString(phone) }

const pesanNomorTidakValid = "Nomor HP tidak valid. Tulis nomor seluler aktif, contoh 0812 3456 7890."

// buatKodeVerifWA mencatat satu pendaftaran yang menunggu pesan WhatsApp.
func buatKodeVerifWA(phone string) string {
	verifWAMu.Lock()
	defer verifWAMu.Unlock()
	sekarang := time.Now()
	for k, v := range verifWA6 {
		if sekarang.After(v.kedaluwarsa) {
			delete(verifWA6, k)
		}
	}
	kode := newOTP()
	for i := 0; i < 20 && verifWA6[kode] != nil; i++ {
		kode = newOTP()
	}
	verifWA6[kode] = &verifWA{phone: phone, kedaluwarsa: sekarang.Add(umurVerifWA)}
	return kode
}

// tandaiVerifWA dipanggil webhook: pesan berisi kode datang dari nomor pengirim.
func tandaiVerifWA(kode, pengirim string) bool {
	verifWAMu.Lock()
	defer verifWAMu.Unlock()
	v := verifWA6[kode]
	if v == nil || time.Now().After(v.kedaluwarsa) || v.phone != pengirim {
		return false
	}
	v.terverifikasi = true
	return true
}

// statusVerifWA: (ada, terverifikasi) untuk kode itu.
func statusVerifWA(kode string) (bool, bool) {
	verifWAMu.Lock()
	defer verifWAMu.Unlock()
	v := verifWA6[kode]
	if v == nil || time.Now().After(v.kedaluwarsa) {
		return false, false
	}
	return true, v.terverifikasi
}

// cekVerifWA dipakai sebelum akun dibuat. Pesan kosong = boleh lanjut.
func cekVerifWA(kode, phone string) string {
	if !waVerifikasiAktif() {
		return ""
	}
	if kode == "" {
		return "Perbarui aplikasi BohAntar dari Play Store untuk mendaftar."
	}
	verifWAMu.Lock()
	defer verifWAMu.Unlock()
	v := verifWA6[kode]
	if v == nil || time.Now().After(v.kedaluwarsa) {
		return "Kode verifikasi WhatsApp kedaluwarsa. Ulangi pendaftaran."
	}
	if !v.terverifikasi || v.phone != phone {
		return "Nomor WhatsApp belum terverifikasi. Kirim dulu pesan kodenya lewat WhatsApp."
	}
	return ""
}

// habiskanVerifWA: satu kode satu akun.
func habiskanVerifWA(kode string) {
	verifWAMu.Lock()
	delete(verifWA6, kode)
	verifWAMu.Unlock()
}

// verifikasiWAHandler:
//
//	POST /api/auth/verifikasi-wa {phone_number} → {wajib, kode, wa, teks}
//	GET  /api/auth/verifikasi-wa?kode=          → {terverifikasi}
func verifikasiWAHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		ada, ok := statusVerifWA(r.URL.Query().Get("kode"))
		if !ada {
			writeJSONResponse(w, 404, map[string]string{"error": "Kode verifikasi kedaluwarsa. Ulangi pendaftaran."})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "terverifikasi": ok})
		return
	}
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	// Setiap permintaan dihitung: tiap kode menempati memori sampai kedaluwarsa.
	rem := "verif-wa:" + alamatPemanggil(r)
	if terlaluSeringGagal(rem) {
		writeJSONResponse(w, 429, map[string]string{"error": "Terlalu banyak percobaan dari jaringan ini. Coba lagi 15 menit lagi."})
		return
	}
	catatGagalLogin(rem)
	var input struct {
		PhoneNumber string `json:"phone_number"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Data yang dikirim tidak terbaca. Coba lagi."})
		return
	}
	phone := normalizePhone(input.PhoneNumber)
	if !nomorHPValid(phone) {
		writeJSONResponse(w, 400, map[string]string{"error": pesanNomorTidakValid})
		return
	}
	if _, ada := dbGetUser(phone); ada {
		writeJSONResponse(w, 409, map[string]string{"error": "Nomor handphone ini sudah terdaftar. Silakan masuk."})
		return
	}
	if !waVerifikasiAktif() {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "wajib": false})
		return
	}
	kode := buatKodeVerifWA(phone)
	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"wajib":  true,
		"kode":   kode,
		"wa":     getEnv("WA_NOMOR", ""),
		"teks":   "Kode daftar BohAntar: " + kode,
	})
}

var polaKode6 = regexp.MustCompile(`\b[0-9]{6}\b`)

// waWebhookHandler: /api/webhook/whatsapp, didaftarkan di Meta (WhatsApp →
// Configuration → Webhook, langganan kolom "messages").
func waWebhookHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		// Jabat tangan saat URL webhook disimpan di Meta.
		q := r.URL.Query()
		token := getEnv("WA_VERIFY_TOKEN", "")
		if q.Get("hub.mode") != "subscribe" || token == "" || !hmac.Equal([]byte(q.Get("hub.verify_token")), []byte(token)) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		io.WriteString(w, q.Get("hub.challenge"))
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	// Tanpa tanda tangan ini siapa pun bisa mengaku "pesan dari 0812…" dan
	// memverifikasi nomor orang lain.
	if !tandaTanganMetaSah(body, r.Header.Get("X-Hub-Signature-256"), getEnv("WA_APP_SECRET", "")) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	for _, m := range pesanMasukWA(body) {
		for _, kode := range polaKode6.FindAllString(m.isi, 3) {
			if tandaiVerifWA(kode, m.dari) {
				log.Printf("verifikasi WA: %s terverifikasi", m.dari)
				break
			}
		}
	}
	// Selalu 200: selain itu Meta mengirim ulang pesan yang sama berjam-jam.
	w.WriteHeader(http.StatusOK)
}

func tandaTanganMetaSah(body []byte, header, rahasia string) bool {
	if rahasia == "" || !strings.HasPrefix(header, "sha256=") {
		return false
	}
	mac := hmac.New(sha256.New, []byte(rahasia))
	mac.Write(body)
	return hmac.Equal([]byte(strings.TrimPrefix(header, "sha256=")), []byte(hex.EncodeToString(mac.Sum(nil))))
}

type pesanWA struct{ dari, isi string }

// pesanMasukWA membongkar payload webhook WhatsApp Cloud API. Nomor pengirim
// ("from") berbentuk 628…, dikembalikan sebagai +628… seperti di tabel users.
func pesanMasukWA(body []byte) []pesanWA {
	var p struct {
		Entry []struct {
			Changes []struct {
				Value struct {
					Messages []struct {
						From string `json:"from"`
						Type string `json:"type"`
						Text struct {
							Body string `json:"body"`
						} `json:"text"`
					} `json:"messages"`
				} `json:"value"`
			} `json:"changes"`
		} `json:"entry"`
	}
	if json.Unmarshal(body, &p) != nil {
		return nil
	}
	var hasil []pesanWA
	for _, e := range p.Entry {
		for _, c := range e.Changes {
			for _, m := range c.Value.Messages {
				if m.Type == "text" && m.From != "" {
					hasil = append(hasil, pesanWA{dari: "+" + strings.TrimPrefix(m.From, "+"), isi: m.Text.Body})
				}
			}
		}
	}
	return hasil
}

// ==================== BATAS PENDAFTARAN PER JARINGAN ====================

// ponytail: di memori, kembali nol saat restart. Dihitung per akun yang JADI,
// bukan per percobaan: di Sintang banyak pelanggan seluler berbagi satu IP
// publik (CGNAT), jadi batasnya sengaja longgar.
const batasDaftarPerJam = 5

var (
	daftarIPMu sync.Mutex
	daftarIP   = map[string][]time.Time{}
)

func kuotaDaftarHabis(ip string) bool {
	daftarIPMu.Lock()
	defer daftarIPMu.Unlock()
	batas := time.Now().Add(-time.Hour)
	for k, riwayat := range daftarIP {
		hidup := riwayat[:0]
		for _, t := range riwayat {
			if t.After(batas) {
				hidup = append(hidup, t)
			}
		}
		if len(hidup) == 0 {
			delete(daftarIP, k)
		} else {
			daftarIP[k] = hidup
		}
	}
	return len(daftarIP[ip]) >= batasDaftarPerJam
}

func catatPendaftaran(ip string) {
	daftarIPMu.Lock()
	daftarIP[ip] = append(daftarIP[ip], time.Now())
	daftarIPMu.Unlock()
}

const pesanKuotaDaftar = "Terlalu banyak akun baru dari jaringan ini. Coba lagi satu jam lagi."
