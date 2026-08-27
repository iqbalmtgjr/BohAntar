package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

// ==================== CONFIG ====================

var (
	jwtKey      []byte
	tokenTTL    = 7 * 24 * time.Hour
	isProdOnce  sync.Once
	isProdCache bool
)

func isProduction() bool {
	isProdOnce.Do(func() { isProdCache = getEnv("APP_ENV", "dev") == "production" })
	return isProdCache
}

// initAuth menyiapkan kunci penandatanganan token. Di produksi JWT_SECRET wajib
// diisi; di mode dev kunci acak dibuat tiap start (token lama otomatis invalid).
func initAuth() {
	secret := getEnv("JWT_SECRET", "")
	if secret == "" {
		if isProduction() {
			log.Fatal("JWT_SECRET wajib diisi saat APP_ENV=production")
		}
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			log.Fatalf("Gagal membuat kunci sementara: %v", err)
		}
		secret = hex.EncodeToString(b)
		log.Println("PERINGATAN: JWT_SECRET kosong, memakai kunci acak sementara (mode dev)")
	}
	if len(secret) < 32 && isProduction() {
		log.Fatal("JWT_SECRET minimal 32 karakter")
	}
	jwtKey = []byte(secret)
}

// ==================== PASSWORD ====================

func hashPassword(plain string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	return string(h), err
}

func checkPassword(hash, plain string) bool {
	if hash == "" || plain == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}

// newID membuat ID dengan 12 byte acak. Menggantikan rand.Intn(1000000) yang
// mulai bertabrakan setelah ~1.200 baris dan menimpa data lewat ON DUPLICATE KEY.
func newID(prefix string) string {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
	}
	return prefix + "-" + hex.EncodeToString(b)
}

func randomPassword() string {
	b := make([]byte, 9)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("pw-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

// ==================== TOKEN ====================

type appClaims struct {
	Role string `json:"role"`
	jwt.RegisteredClaims
}

func issueToken(phone, role string) (string, error) {
	now := time.Now()
	t := jwt.NewWithClaims(jwt.SigningMethodHS256, appClaims{
		Role: role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   phone,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(tokenTTL)),
		},
	})
	return t.SignedString(jwtKey)
}

// parseBearer memvalidasi header Authorization dan mengembalikan nomor HP + role.
func parseBearer(r *http.Request) (phone, role string, ok bool) {
	raw := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(raw, "Bearer ") {
		return "", "", false
	}
	var c appClaims
	// jwt.ParseWithClaims memvalidasi exp dan menolak alg selain HS256.
	_, err := jwt.ParseWithClaims(strings.TrimPrefix(raw, "Bearer "), &c,
		func(t *jwt.Token) (interface{}, error) { return jwtKey, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
	)
	if err != nil || c.Subject == "" {
		return "", "", false
	}
	return c.Subject, c.Role, true
}

// extractPhone dipakai handler yang memeriksa token sendiri (bukan lewat middleware).
func extractPhone(r *http.Request) (string, bool) {
	phone, _, ok := parseBearer(r)
	return phone, ok
}

// ==================== MIDDLEWARE ====================

type ctxKey string

const (
	ctxPhone ctxKey = "phone"
	ctxRole  ctxKey = "role"
)

func callerPhone(r *http.Request) string {
	v, _ := r.Context().Value(ctxPhone).(string)
	return v
}

func callerRole(r *http.Request) string {
	v, _ := r.Context().Value(ctxRole).(string)
	return v
}

// requireRole membungkus handler agar hanya bisa diakses token yang valid dan,
// bila roles diisi, hanya oleh role yang terdaftar.
func requireRole(roles ...string) func(http.HandlerFunc) http.HandlerFunc {
	return func(next http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			phone, role, ok := parseBearer(r)
			if !ok {
				writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
				return
			}
			if len(roles) > 0 {
				allowed := false
				for _, want := range roles {
					if role == want {
						allowed = true
						break
					}
				}
				if !allowed {
					writeJSONResponse(w, 403, map[string]string{"error": "Akses ditolak untuk role ini"})
					return
				}
			}
			ctx := context.WithValue(r.Context(), ctxPhone, phone)
			ctx = context.WithValue(ctx, ctxRole, role)
			next(w, r.WithContext(ctx))
		}
	}
}

// requireAuth hanya menuntut token valid, tanpa membatasi role.
func requireAuth(next http.HandlerFunc) http.HandlerFunc { return requireRole()(next) }

// ==================== KEPEMILIKAN ====================

// Semua pemeriksaan di bawah menanyakan langsung ke database apakah baris yang
// diminta memang milik pemanggil. Admin dilewatkan agar tetap bisa menangani
// keluhan mitra. Nomor HP selalu diambil dari token, tidak pernah dari request.

func isAdmin(r *http.Request) bool { return callerRole(r) == "admin" }

func ownsMerchant(r *http.Request, merchantID string) bool {
	if isAdmin(r) {
		return true
	}
	var owner string
	if db.QueryRow("SELECT owner_phone FROM food_merchants WHERE id = ?", merchantID).Scan(&owner) != nil {
		return false
	}
	return owner == callerPhone(r)
}

func ownsMenu(r *http.Request, menuID string) bool {
	if isAdmin(r) {
		return true
	}
	var owner string
	err := db.QueryRow(`
		SELECT m.owner_phone FROM food_menus n
		JOIN food_merchants m ON n.merchant_id = m.id
		WHERE n.id = ?`, menuID).Scan(&owner)
	return err == nil && owner == callerPhone(r)
}

func ownsCar(r *http.Request, carID string) bool {
	if isAdmin(r) {
		return true
	}
	var owner string
	if db.QueryRow("SELECT owner_phone FROM rental_cars WHERE id = ?", carID).Scan(&owner) != nil {
		return false
	}
	return owner == callerPhone(r)
}

func ownsSchedule(r *http.Request, scheduleID string) bool {
	if isAdmin(r) {
		return true
	}
	var owner string
	err := db.QueryRow(`
		SELECT c.owner_phone FROM rental_car_schedules s
		JOIN rental_cars c ON s.car_id = c.id
		WHERE s.id = ?`, scheduleID).Scan(&owner)
	return err == nil && owner == callerPhone(r)
}

// requireActiveSubscription memblokir mitra rental yang masa langganannya habis.
// Pemeriksaan client-side di React saja bisa dilewati dengan memanggil API langsung.
func requireActiveSubscription(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if callerRole(r) != "rental_partner" {
			next(w, r)
			return
		}
		// Mitra tanpa baris langganan dulu lolos begitu saja; sekarang masa trial-nya
		// dibuat di sini supaya tidak ada jalur yang melewati pemeriksaan.
		sub, exists := dbGetPartnerSubscription(callerPhone(r))
		if !exists {
			sub = startTrialSubscription(callerPhone(r))
		}
		validUntil, err := time.Parse(time.RFC3339, sub.ValidUntil)
		if sub.Status == "EXPIRED" || (err == nil && time.Now().After(validUntil)) {
			writeJSONResponse(w, 402, map[string]string{
				"error": "Masa langganan Anda sudah habis. Perpanjang untuk melanjutkan.",
			})
			return
		}
		next(w, r)
	}
}

func denyOwnership(w http.ResponseWriter) {
	writeJSONResponse(w, 403, map[string]string{"error": "Data ini bukan milik akun Anda"})
}

// ==================== OTP STORE ====================

type otpEntry struct {
	code     string
	expires  time.Time
	attempts int
}

const (
	otpTTL         = 5 * time.Minute
	otpMaxAttempts = 5
)

var (
	otpMutex sync.Mutex
	otpStore = make(map[string]*otpEntry)
)

func saveOTP(phone, code string) {
	otpMutex.Lock()
	defer otpMutex.Unlock()
	otpStore[phone] = &otpEntry{code: code, expires: time.Now().Add(otpTTL)}
}

// consumeOTP mengembalikan true hanya sekali untuk kode yang benar dan belum
// kedaluwarsa. Kode dihapus setelah berhasil atau setelah batas percobaan.
func consumeOTP(phone, code string) bool {
	otpMutex.Lock()
	defer otpMutex.Unlock()
	e, exists := otpStore[phone]
	if !exists || time.Now().After(e.expires) {
		delete(otpStore, phone)
		return false
	}
	e.attempts++
	if e.attempts > otpMaxAttempts {
		delete(otpStore, phone)
		return false
	}
	if subtleEqual(e.code, code) {
		delete(otpStore, phone)
		return true
	}
	return false
}

func subtleEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := 0; i < len(a); i++ {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

// pruneOTPs membuang entri kedaluwarsa agar map tidak tumbuh tanpa batas.
func pruneOTPs() {
	for range time.Tick(time.Minute) {
		otpMutex.Lock()
		now := time.Now()
		for k, v := range otpStore {
			if now.After(v.expires) {
				delete(otpStore, k)
			}
		}
		otpMutex.Unlock()
	}
}

func newOTP() string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return "000000"
	}
	n := (uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])) % 1000000
	return fmt.Sprintf("%06d", n)
}

// ==================== GOOGLE ID TOKEN ====================

// verifyGoogleIDToken memverifikasi id_token lewat endpoint tokeninfo Google.
// ponytail: satu HTTP call per login, bukan verifikasi JWKS lokal. Pindah ke
// google.golang.org/api/idtoken kalau volume login sudah kena rate limit Google.
func verifyGoogleIDToken(ctx context.Context, idToken, wantNonce string) (email, name string, err error) {
	clientID := getEnv("GOOGLE_CLIENT_ID", "")
	if clientID == "" {
		return "", "", fmt.Errorf("GOOGLE_CLIENT_ID belum dikonfigurasi di server")
	}

	endpoint := "https://oauth2.googleapis.com/tokeninfo?id_token=" + url.QueryEscape(idToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", "", err
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("gagal menghubungi Google: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("token Google tidak valid atau sudah kedaluwarsa")
	}

	var info struct {
		Aud           string      `json:"aud"`
		Email         string      `json:"email"`
		EmailVerified interface{} `json:"email_verified"`
		Name          string      `json:"name"`
		Nonce         string      `json:"nonce"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return "", "", fmt.Errorf("gagal membaca respons Google: %w", err)
	}
	if info.Aud != clientID {
		return "", "", fmt.Errorf("token Google diterbitkan untuk aplikasi lain")
	}
	// Nonce mengikat token ke satu percobaan login, sehingga token yang dicuri dari
	// sesi lain tidak bisa dipakai ulang. Klien yang tidak mengirim nonce (aplikasi
	// mobile lewat google_sign_in) dilewatkan.
	if wantNonce != "" && !subtleEqual(info.Nonce, wantNonce) {
		return "", "", fmt.Errorf("nonce tidak cocok, ulangi login dari awal")
	}
	// tokeninfo mengembalikan email_verified sebagai bool atau string "true".
	verified := false
	switch v := info.EmailVerified.(type) {
	case bool:
		verified = v
	case string:
		verified = v == "true"
	}
	if !verified || info.Email == "" {
		return "", "", fmt.Errorf("email Google belum terverifikasi")
	}
	if info.Name == "" {
		info.Name = strings.Split(info.Email, "@")[0]
	}
	return info.Email, info.Name, nil
}
