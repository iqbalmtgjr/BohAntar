package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// ==================== WEB PUSH (dashboard mitra) ====================
//
// Mitra rental memakai dashboard web, bukan aplikasi, jadi tidak punya token
// FCM: chat penyewa hanya muncul di lonceng saat dashboard sedang dibuka.
// Web Push standar (VAPID + RFC 8291) membuat browser mitra menampilkan
// notifikasi sistem walau tab dashboard tertutup — di Android/desktop selama
// browsernya terpasang, di iPhone hanya bila dashboard ditambahkan ke Layar
// Utama. Semua notifikasiKe() ikut terkirim ke sini, jadi chat sewa otomatis.
//
// Kunci VAPID dibuat sendiri saat pertama jalan dan disimpan di vapid.pem di
// folder kerja binary. Hilang/terhapus = kunci baru; langganan lama ditolak
// layanan push dan dashboard berlangganan ulang saat dibuka berikutnya.

const berkasVAPID = "vapid.pem"

var (
	vapidKunci  *ecdsa.PrivateKey
	vapidPublik string // titik P-256 tak terkompresi, base64url: applicationServerKey browser
	klienPush   = &http.Client{Timeout: 10 * time.Second}
)

func initWebPush() {
	if b, err := os.ReadFile(berkasVAPID); err == nil {
		if blk, _ := pem.Decode(b); blk != nil {
			vapidKunci, _ = x509.ParseECPrivateKey(blk.Bytes)
		}
	}
	if vapidKunci == nil {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			log.Printf("web push mati: %v", err)
			return
		}
		der, _ := x509.MarshalECPrivateKey(k)
		if err := os.WriteFile(berkasVAPID, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0600); err != nil {
			log.Printf("web push mati: %s tidak bisa ditulis: %v", berkasVAPID, err)
			return
		}
		vapidKunci = k
	}
	pub, err := vapidKunci.PublicKey.ECDH()
	if err != nil {
		vapidKunci = nil
		return
	}
	vapidPublik = base64.RawURLEncoding.EncodeToString(pub.Bytes())
}

// Tabel baru tanpa JOIN ke tabel lama (collation MariaDB): selalu dicari
// dengan parameter nomor HP.
func migrasiWebPush() {
	migrasiSkema(`CREATE TABLE IF NOT EXISTS webpush (
		endpoint VARCHAR(700) CHARACTER SET ascii NOT NULL PRIMARY KEY,
		phone_number VARCHAR(20) NOT NULL,
		p256dh VARCHAR(120) CHARACTER SET ascii NOT NULL,
		auth VARCHAR(60) CHARACTER SET ascii NOT NULL,
		created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
		INDEX idx_webpush_phone (phone_number)
	)`)
}

// Server menembak endpoint pilihan browser. Hanya layanan push resmi yang
// diterima, supaya akun mitra tidak bisa menyuruh server memanggil alamat
// internal (SSRF).
var layananPush = []string{"fcm.googleapis.com", "push.services.mozilla.com", "push.apple.com", "notify.windows.com"}

func endpointPushSah(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || len(s) > 700 {
		return false
	}
	h := u.Hostname()
	for _, l := range layananPush {
		if h == l || strings.HasSuffix(h, "."+l) {
			return true
		}
	}
	return false
}

func b64Kunci(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}

// webPushKunciHandler: GET /api/webpush/kunci → {"kunci": applicationServerKey}
func webPushKunciHandler(w http.ResponseWriter, r *http.Request) {
	if vapidPublik == "" {
		writeJSONResponse(w, 503, map[string]string{"error": "Notifikasi browser belum aktif di server"})
		return
	}
	writeJSONResponse(w, 200, map[string]string{"kunci": vapidPublik})
}

// webPushLanggananHandler: POST /api/webpush/langganan {endpoint, keys:{p256dh, auth}}
// Satu browser = satu baris; browser yang dipakai akun lain berpindah pemilik.
func webPushLanggananHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var in struct {
		Endpoint string `json:"endpoint"`
		Keys     struct {
			P256dh string `json:"p256dh"`
			Auth   string `json:"auth"`
		} `json:"keys"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || !endpointPushSah(in.Endpoint) {
		writeJSONResponse(w, 400, map[string]string{"error": "Langganan notifikasi tidak sah"})
		return
	}
	pub, err1 := b64Kunci(in.Keys.P256dh)
	auth, err2 := b64Kunci(in.Keys.Auth)
	if err1 != nil || err2 != nil || len(pub) != 65 || len(auth) != 16 {
		writeJSONResponse(w, 400, map[string]string{"error": "Langganan notifikasi tidak sah"})
		return
	}
	if _, err := db.Exec(`INSERT INTO webpush (endpoint, phone_number, p256dh, auth) VALUES (?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE phone_number = VALUES(phone_number), p256dh = VALUES(p256dh), auth = VALUES(auth)`,
		in.Endpoint, callerPhone(r), in.Keys.P256dh, in.Keys.Auth); err != nil {
		galatServer(w, r, err)
		return
	}
	writeJSONResponse(w, 200, map[string]string{"status": "success"})
}

// kirimWebPush dipanggil notifikasiKe untuk setiap penerima. Penumpang & driver
// tidak punya baris di tabel ini, jadi bagi mereka cuma satu SELECT kosong.
func kirimWebPush(phone, judul, isi string, data map[string]string) {
	if vapidKunci == nil {
		return
	}
	rows, err := db.Query("SELECT endpoint, p256dh, auth FROM webpush WHERE phone_number = ?", phone)
	if err != nil {
		return
	}
	var daftar [][3]string
	for rows.Next() {
		var l [3]string
		if rows.Scan(&l[0], &l[1], &l[2]) == nil {
			daftar = append(daftar, l)
		}
	}
	rows.Close()
	if len(daftar) == 0 {
		return
	}
	// Satu record aes128gcm muat ±4 KB; chat boleh 1000 karakter (sampai 4 KB
	// UTF-8), dan notifikasi sistem toh hanya menampilkan beberapa baris.
	if r := []rune(isi); len(r) > 300 {
		isi = string(r[:300]) + "…"
	}
	payload, _ := json.Marshal(map[string]interface{}{"title": judul, "body": isi, "data": data})
	for _, l := range daftar {
		kode, err := dorongWebPush(l[0], l[1], l[2], payload)
		switch {
		case kode == 404 || kode == 410: // browser sudah berhenti berlangganan
			db.Exec("DELETE FROM webpush WHERE endpoint = ?", l[0])
		case err != nil || kode >= 300:
			log.Printf("web push ke %s gagal: %d %v", phone, kode, err)
		}
	}
}

func dorongWebPush(endpoint, p256dh, auth string, payload []byte) (int, error) {
	body, err := enkripsiWebPush(p256dh, auth, payload)
	if err != nil {
		return 0, err
	}
	u, err := url.Parse(endpoint)
	if err != nil {
		return 0, err
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"aud": u.Scheme + "://" + u.Host,
		"exp": time.Now().Add(12 * time.Hour).Unix(),
		"sub": "https://bohantar.indotechconsulting.com",
	}).SignedString(vapidKunci)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("TTL", "86400")
	req.Header.Set("Urgency", "high")
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Authorization", "vapid t="+tok+", k="+vapidPublik)
	res, err := klienPush.Do(req)
	if err != nil {
		return 0, err
	}
	res.Body.Close()
	return res.StatusCode, nil
}

// enkripsiWebPush mengenkripsi isi untuk satu browser (RFC 8291, aes128gcm).
func enkripsiWebPush(p256dh, auth string, isi []byte) ([]byte, error) {
	eph, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, 16)
	rand.Read(salt)
	return enkripsiWebPushDengan(eph, salt, p256dh, auth, isi)
}

// Kunci sementara & salt dipisah supaya bisa diuji dengan vektor RFC 8291.
func enkripsiWebPushDengan(eph *ecdh.PrivateKey, salt []byte, p256dh, auth string, isi []byte) ([]byte, error) {
	uaPub, err1 := b64Kunci(p256dh)
	rahasia, err2 := b64Kunci(auth)
	if err1 != nil || err2 != nil {
		return nil, errors.New("kunci langganan rusak")
	}
	ua, err := ecdh.P256().NewPublicKey(uaPub)
	if err != nil {
		return nil, err
	}
	bersama, err := eph.ECDH(ua)
	if err != nil {
		return nil, err
	}
	asPub := eph.PublicKey().Bytes()
	info := append(append([]byte("WebPush: info\x00"), uaPub...), asPub...)
	ikm, err := hkdf.Key(sha256.New, bersama, rahasia, string(info), 32)
	if err != nil {
		return nil, err
	}
	cek, _ := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: aes128gcm\x00", 16)
	nonce, _ := hkdf.Key(sha256.New, ikm, salt, "Content-Encoding: nonce\x00", 12)
	blk, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(blk)
	if err != nil {
		return nil, err
	}
	// 0x02 = pembatas record terakhir, tanpa padding tambahan.
	sandi := gcm.Seal(nil, nonce, append(append([]byte{}, isi...), 2), nil)
	out := append([]byte{}, salt...)
	out = binary.BigEndian.AppendUint32(out, 4096)
	out = append(out, byte(len(asPub)))
	out = append(out, asPub...)
	return append(out, sandi...), nil
}
