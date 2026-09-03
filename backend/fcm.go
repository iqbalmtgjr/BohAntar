package main

import (
	"bytes"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// ==================== NOTIFIKASI FIREBASE ====================
//
// Tanpa ini driver harus menatap layar terbuka supaya tidak kehilangan orderan,
// dan penumpang tidak tahu apa-apa sampai membuka aplikasi lagi.
//
// FCM jalur lama (kirim dengan "Authorization: key=SERVER_KEY") sudah dimatikan
// Google pertengahan 2024, jadi yang dipakai HTTP v1: JWT service account
// ditukar jadi access token, lalu token itu dipakai mengirim pesan. Ditulis
// dengan golang-jwt yang memang sudah dipakai untuk token sesi, bukan menambah
// paket baru.
//
// Semua pengiriman dilakukan di goroutine terpisah dan kegagalannya hanya
// dicatat: notifikasi yang tidak sampai tidak boleh menggagalkan pemesanan.

type serviceAccount struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	ProjectID   string `json:"project_id"`
}

var (
	fcmOnce    sync.Once
	fcmAkun    *serviceAccount
	fcmKunci   *rsa.PrivateKey
	fcmMu      sync.Mutex
	fcmToken   string
	fcmExpired time.Time
	fcmClient  = &http.Client{Timeout: 12 * time.Second}
)

// muatServiceAccount membaca berkas kredensial sekali saja. Jalur berkasnya
// dari environment variable FCM_SERVICE_ACCOUNT; kalau kosong, notifikasi
// dimatikan diam-diam dan sisa aplikasi tetap berjalan normal.
func muatServiceAccount() {
	fcmOnce.Do(func() {
		path := getEnv("FCM_SERVICE_ACCOUNT", "")
		if path == "" {
			log.Println("FCM_SERVICE_ACCOUNT belum disetel — notifikasi push dimatikan")
			return
		}
		isi, err := os.ReadFile(path)
		if err != nil {
			log.Printf("Gagal membaca kredensial FCM: %v", err)
			return
		}
		var sa serviceAccount
		if err := json.Unmarshal(isi, &sa); err != nil {
			log.Printf("Kredensial FCM bukan JSON yang sah: %v", err)
			return
		}
		kunci, err := jwt.ParseRSAPrivateKeyFromPEM([]byte(sa.PrivateKey))
		if err != nil {
			log.Printf("private_key di kredensial FCM tidak bisa dibaca: %v", err)
			return
		}
		fcmAkun = &sa
		fcmKunci = kunci
		log.Printf("Notifikasi push aktif untuk proyek %s", sa.ProjectID)
	})
}

func fcmAktif() bool {
	muatServiceAccount()
	return fcmAkun != nil && fcmKunci != nil
}

// accessTokenFCM menukar JWT service account jadi access token, dan menyimpannya
// sampai hampir kedaluwarsa. Tanpa cache, setiap notifikasi jadi dua permintaan
// jaringan, bukan satu.
func accessTokenFCM() (string, error) {
	fcmMu.Lock()
	defer fcmMu.Unlock()
	if fcmToken != "" && time.Now().Before(fcmExpired) {
		return fcmToken, nil
	}

	now := time.Now()
	klaim := jwt.MapClaims{
		"iss":   fcmAkun.ClientEmail,
		"scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud":   "https://oauth2.googleapis.com/token",
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, klaim).SignedString(fcmKunci)
	if err != nil {
		return "", fmt.Errorf("gagal menandatangani JWT FCM: %w", err)
	}

	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	resp, err := fcmClient.Post(
		"https://oauth2.googleapis.com/token",
		"application/x-www-form-urlencoded",
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return "", fmt.Errorf("gagal menukar token FCM: %w", err)
	}
	defer resp.Body.Close()

	var hasil struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&hasil); err != nil || hasil.AccessToken == "" {
		return "", fmt.Errorf("balasan token FCM tidak dikenali (kode %d)", resp.StatusCode)
	}

	fcmToken = hasil.AccessToken
	// Disisakan semenit supaya tidak terpakai tepat saat kedaluwarsa.
	fcmExpired = now.Add(time.Duration(hasil.ExpiresIn)*time.Second - time.Minute)
	return fcmToken, nil
}

// kirimNotifikasi mengirim satu pesan ke satu perangkat.
//
// data ikut terkirim supaya aplikasi bisa membuka layar yang tepat saat
// notifikasinya ditekan — misalnya langsung ke pesanan yang bersangkutan.
func kirimNotifikasi(tokenPerangkat, judul, isi string, data map[string]string) {
	if tokenPerangkat == "" || !fcmAktif() {
		return
	}
	akses, err := accessTokenFCM()
	if err != nil {
		log.Printf("Notifikasi dilewati: %v", err)
		return
	}

	pesan := map[string]interface{}{
		"message": map[string]interface{}{
			"token": tokenPerangkat,
			"notification": map[string]string{
				"title": judul,
				"body":  isi,
			},
			"data": data,
			"android": map[string]interface{}{
				"priority": "high",
				"notification": map[string]string{
					"channel_id": "bohantar_orderan",
					"sound":      "default",
				},
			},
		},
	}
	buf, _ := json.Marshal(pesan)

	endpoint := "https://fcm.googleapis.com/v1/projects/" + fcmAkun.ProjectID + "/messages:send"
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(buf))
	if err != nil {
		log.Printf("Notifikasi gagal disiapkan: %v", err)
		return
	}
	req.Header.Set("Authorization", "Bearer "+akses)
	req.Header.Set("Content-Type", "application/json")

	resp, err := fcmClient.Do(req)
	if err != nil {
		log.Printf("Notifikasi gagal dikirim: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone {
		// Perangkat sudah tidak terdaftar: aplikasi dihapus, atau tokennya
		// diganti. Dibersihkan supaya tidak dicoba terus setiap ada pesanan.
		_, _ = db.Exec("UPDATE users SET fcm_token = '' WHERE fcm_token = ?", tokenPerangkat)
		return
	}
	if resp.StatusCode != http.StatusOK {
		badan, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<12))
		log.Printf("FCM menolak notifikasi (kode %d): %s", resp.StatusCode, string(badan))
	}
}

// notifikasiKe mengirim ke satu pengguna berdasarkan nomornya.
// Dijalankan di goroutine: pemesanan tidak boleh menunggu jaringan Google.
func notifikasiKe(phone, judul, isi string, data map[string]string) {
	if phone == "" || !fcmAktif() {
		return
	}
	go func() {
		var tok string
		if err := db.QueryRow("SELECT COALESCE(fcm_token, '') FROM users WHERE phone_number = ?", phone).Scan(&tok); err != nil {
			return
		}
		kirimNotifikasi(tok, judul, isi, data)
	}()
}

// notifikasiDriverSiaga menyiarkan pesanan baru ke driver yang sedang bekerja.
//
// "Sedang bekerja" ditentukan dari kesegaran posisi terakhirnya, bukan dari
// tombol online yang dilaporkan sendiri: driver yang aplikasinya mati berhenti
// mengirim posisi, jadi otomatis tidak ikut dikirimi. Tidak ada status baru yang
// harus dijaga tetap sinkron.
//
// ponytail: dikirim ke semua driver yang segar, bukan hanya yang terdekat.
// Untuk armada sebesar Sintang itu justru yang diinginkan — siapa pun yang
// sempat, ambil. Saring dengan jarak ke titik jemput kalau armadanya sudah
// cukup besar sampai driver merasa terganggu.
func notifikasiDriverSiaga(o Order) {
	if !fcmAktif() {
		return
	}
	go func() {
		batas := time.Now().Add(-10 * time.Minute).Format(time.RFC3339)
		// is_driver_active ikut jadi syarat: driver yang dinonaktifkan admin tidak
		// perlu lagi dibangunkan orderan yang tidak boleh ia terima.
		rows, err := db.Query(
			"SELECT COALESCE(fcm_token, '') FROM users WHERE role = 'driver' AND is_driver_active = 1 AND COALESCE(fcm_token, '') != '' AND COALESCE(driver_loc_at, '') > ?",
			batas,
		)
		if err != nil {
			return
		}
		defer rows.Close()

		var tokens []string
		for rows.Next() {
			var t string
			if rows.Scan(&t) == nil && t != "" {
				tokens = append(tokens, t)
			}
		}
		for _, t := range tokens {
			kirimNotifikasi(t, "Orderan baru!", fmt.Sprintf("%s → %s · Rp%.0f", o.PickupAddress, o.DropoffAddress, o.Fare-o.Komisi), map[string]string{
				"tipe":     "orderan_baru",
				"order_id": o.ID,
			})
		}
	}()
}

// fcmTokenHandler menyimpan token perangkat milik pemanggil.
func fcmTokenHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.Token == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Token perangkat diperlukan"})
		return
	}
	// Token FCM unik per pemasangan aplikasi. Kalau nomor lain sempat memakai
	// token yang sama di perangkat ini, kepemilikannya dipindahkan supaya
	// notifikasi tidak nyasar ke pemilik akun sebelumnya.
	_, _ = db.Exec("UPDATE users SET fcm_token = '' WHERE fcm_token = ?", input.Token)
	if _, err := db.Exec("UPDATE users SET fcm_token = ? WHERE phone_number = ?", input.Token, callerPhone(r)); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan token perangkat"})
		return
	}
	writeJSONResponse(w, 200, map[string]string{"status": "success"})
}
