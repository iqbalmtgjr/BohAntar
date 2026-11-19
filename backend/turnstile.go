package main

import (
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"time"
)

// ==================== CLOUDFLARE TURNSTILE ====================
//
// Pemeriksaan "bukan robot" di form publik dashboard web: login, lupa password,
// dan daftar mitra. Mati selama TURNSTILE_SECRET kosong, supaya binary dan
// dashboard bisa naik lebih dulu, lalu dinyalakan cukup lewat run.sh.
//   TURNSTILE_SITEKEY  kunci situs (publik), dibagikan ke dashboard lewat GET /api/turnstile
//   TURNSTILE_SECRET   kunci rahasia, hanya dipakai di sini untuk siteverify
//
// Token dikirim dashboard di header X-Turnstile, sekali pakai.

var turnstileURL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

var turnstileClient = &http.Client{Timeout: 8 * time.Second}

// Keduanya wajib: secret tanpa sitekey = dashboard tak menampilkan widget tapi
// backend menuntut token, dan semua login web tertolak.
func turnstileAktif() bool {
	return getEnv("TURNSTILE_SECRET", "") != "" && getEnv("TURNSTILE_SITEKEY", "") != ""
}

// turnstileHandler: GET /api/turnstile → {sitekey}; kosong = dashboard tidak menampilkan widget.
func turnstileHandler(w http.ResponseWriter, r *http.Request) {
	sitekey := ""
	if turnstileAktif() {
		sitekey = getEnv("TURNSTILE_SITEKEY", "")
	}
	writeJSONResponse(w, 200, map[string]string{"sitekey": sitekey})
}

const pesanTurnstile = "Pemeriksaan keamanan belum selesai. Tunggu kotak centang Cloudflare hijau, lalu coba lagi."

// tolakTurnstile mengembalikan pesan galat bila permintaan wajib membawa token
// Turnstile yang sah tapi tidak; "" berarti lolos.
//
// selaluWajib untuk endpoint yang hanya dipakai dashboard web. Endpoint yang juga
// dipakai aplikasi Android hanya mewajibkan permintaan dari browser (ada header
// Origin; aplikasi tidak pernah mengirimnya).
// ponytail: bot yang meniru aplikasi (tanpa Origin) lolos dari sini dan hanya
// tertahan rem per IP. Penutupnya Play Integrity di aplikasi, bila serangan itu nyata.
func tolakTurnstile(r *http.Request, selaluWajib bool) string {
	if !turnstileAktif() || (!selaluWajib && r.Header.Get("Origin") == "") {
		return ""
	}
	secret := getEnv("TURNSTILE_SECRET", "")
	token := r.Header.Get("X-Turnstile")
	if token == "" || len(token) > 2048 {
		return pesanTurnstile
	}
	resp, err := turnstileClient.PostForm(turnstileURL, url.Values{
		"secret":   {secret},
		"response": {token},
		"remoteip": {alamatPemanggil(r)},
	})
	if err != nil {
		// Gagal tertutup: tanpa jawaban Cloudflare, permintaan diperlakukan seperti robot.
		log.Printf("turnstile: siteverify gagal: %v", err)
		return "Pemeriksaan keamanan sedang gangguan. Coba lagi sebentar."
	}
	defer resp.Body.Close()
	var hasil struct {
		Success bool     `json:"success"`
		Kode    []string `json:"error-codes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&hasil); err != nil || !hasil.Success {
		if len(hasil.Kode) > 0 {
			log.Printf("turnstile: ditolak %v", hasil.Kode)
		}
		return pesanTurnstile
	}
	return ""
}
