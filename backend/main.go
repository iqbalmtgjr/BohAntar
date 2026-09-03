package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/gorilla/websocket"
)

// Berapa lama pesanan boleh menunggu driver sebelum dianggap batal sendiri.
//
// ponytail: 15 menit, angka tunggal tanpa pengaturan. Di Sintang penumpang yang
// tidak dapat driver dalam seperempat jam sudah mencari cara lain. Naikkan kalau
// ternyata driver sering baru sempat membuka aplikasi setelah lewat batas ini.
// Satu baris per pesanan, bukan per penilaian: order_id jadi kunci utama supaya
// satu perjalanan tetap satu suara meski penumpang mengubah pikirannya.
//
// Ditaruh sebagai konstanta, bukan langsung di dalam daftar tabel initDB, supaya
// tes bisa memakai definisi yang sama persis alih-alih menyalinnya.
const skemaOrderRatings = `CREATE TABLE IF NOT EXISTS order_ratings (
	order_id VARCHAR(50) PRIMARY KEY,
	driver_phone VARCHAR(20),
	rider_phone VARCHAR(20),
	stars INT,
	review TEXT,
	created_at VARCHAR(50),
	INDEX idx_driver (driver_phone)
)`

const batasPesananMenunggu = 15 * time.Minute

// Seberapa jauh dari driver sebuah orderan masih ditampilkan di papan.
//
// ponytail: 25 km, satu angka datar tanpa pengaturan. Sintang dan sekitarnya
// masuk seluruhnya, sementara orderan di kabupaten sebelah tidak lagi ikut
// terunduh tiap tiga detik. Naikkan kalau layanannya melebar keluar kota.
const radiusPapanOrderKM = 25.0

// ==================== STRUCTS ====================

type PartnerSubscription struct {
	PhoneNumber string `json:"phone_number"`
	Status      string `json:"status"` // TRIAL, ACTIVE, EXPIRED
	ValidUntil  string `json:"valid_until"`
	UpdatedAt   string `json:"updated_at"`
}

type SubscriptionInvoice struct {
	ID          string  `json:"id"`
	PhoneNumber string  `json:"phone_number"`
	PartnerName string  `json:"partner_name,omitempty"`
	Amount      float64 `json:"amount"`
	Status      string  `json:"status"` // PENDING, PAID, EXPIRED
	PaymentURL  string  `json:"payment_url"`
	CreatedAt   string  `json:"created_at"`
}

type User struct {
	PhoneNumber    string            `json:"phone_number"`
	Name           string            `json:"name"`
	Email          string            `json:"email"`
	Role           string            `json:"role"`
	CreatedAt      string            `json:"created_at"`
	Balance        float64           `json:"balance"`
	Badge          string            `json:"badge"`
	Addresses      map[string]string `json:"addresses"`
	IsDriverActive bool              `json:"is_driver_active"`
	TotalOrders    int               `json:"total_orders"`
	Rating         float64           `json:"rating"`
}

type Order struct {
	ID              string  `json:"id"`
	RiderPhone      string  `json:"rider_phone"`
	RiderName       string  `json:"rider_name"`
	PickupAddress   string  `json:"pickup"`
	DropoffAddress  string  `json:"dropoff"`
	PickupLat       float64 `json:"pickup_lat"`
	PickupLng       float64 `json:"pickup_lng"`
	DropoffLat      float64 `json:"dropoff_lat"`
	DropoffLng      float64 `json:"dropoff_lng"`
	Fare            float64 `json:"fare"`
	Komisi          float64 `json:"komisi"`         // bagian aplikator; driver terima Fare - Komisi
	PaymentMethod   string  `json:"payment_method"` // "cash" | "wallet"
	Service         string  `json:"service"`
	Status          string  `json:"status"`
	DriverPhone     string  `json:"driver_phone"`
	DriverName      string  `json:"driver_name"`
	CreatedAt       string  `json:"created_at"`
	UpdatedAt       string  `json:"updated_at"`
	PackageType     string  `json:"package_type"`
	PackageQuantity int     `json:"package_quantity"`
	PackageWeight   string  `json:"package_weight"`
	PackageNotes    string  `json:"package_notes"`
	Insurance       bool    `json:"insurance"`
	SpecialHandling bool    `json:"special_handling"`
}

type DriverApplication struct {
	ID           string `json:"id"`
	PhoneNumber  string `json:"phone_number"`
	Name         string `json:"name"`
	Email        string `json:"email"`
	KTPNumber    string `json:"ktp_number"`
	SIMNumber    string `json:"sim_number"`
	VehiclePlate string `json:"vehicle_plate"`
	VehicleType  string `json:"vehicle_type"`
	VehicleModel string `json:"vehicle_model"`
	KTPPhotoURL  string `json:"ktp_photo_url"`
	SIMPhotoURL  string `json:"sim_photo_url"`
	STNKPhotoURL string `json:"stnk_photo_url"`
	Status       string `json:"status"`
	CreatedAt    string `json:"created_at"`
	Notes        string `json:"notes"`
}

type PartnerApplication struct {
	ID           string `json:"id"`
	Type         string `json:"type"` // "food" or "rental"
	PhoneNumber  string `json:"phone_number"`
	Name         string `json:"name"`
	Email        string `json:"email"`
	KTPNumber    string `json:"ktp_number"`
	BusinessName string `json:"business_name"`
	Address      string `json:"address"`
	Status       string `json:"status"`
	CreatedAt    string `json:"created_at"`
	Notes        string `json:"notes"`
}

type ChatMessage struct {
	ID          string `json:"id"`
	OrderID     string `json:"order_id"`
	SenderPhone string `json:"sender_phone"`
	SenderName  string `json:"sender_name"`
	SenderRole  string `json:"sender_role"`
	Content     string `json:"content"`
	Timestamp   string `json:"timestamp"`
}

type FoodMerchant struct {
	ID             string `json:"id"`
	OwnerPhone     string `json:"owner_phone"`
	RestaurantName string `json:"restaurant_name"`
	Address        string `json:"address"`
	ImageURL       string `json:"image_url"`
	IsOpen         bool   `json:"is_open"`
	CreatedAt      string `json:"created_at"`
}

type FoodMenu struct {
	ID          string  `json:"id"`
	MerchantID  string  `json:"merchant_id"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Price       float64 `json:"price"`
	Category    string  `json:"category"`
	ImageURL    string  `json:"image_url"`
	IsAvailable bool    `json:"is_available"`
}

type RentalCar struct {
	ID           string  `json:"id"`
	OwnerPhone   string  `json:"owner_phone"`
	Brand        string  `json:"brand"`
	Model        string  `json:"model"`
	PlateNumber  string  `json:"plate_number"`
	Transmission string  `json:"transmission"`
	Seats        int     `json:"seats"`
	PricePerDay  float64 `json:"price_per_day"`
	ImageURL     string  `json:"image_url"`
	Status       string  `json:"status"`
	VehicleType  string  `json:"vehicle_type"`
	Color        string  `json:"color"` // kosong = warna otomatis dari urutan armada
	CreatedAt    string  `json:"created_at"`
}

type RentalBooking struct {
	ID            string  `json:"id"`
	CarID         string  `json:"car_id"`
	CustomerPhone string  `json:"customer_phone"`
	CustomerName  string  `json:"customer_name"` // dari tabel users, read-only
	StartTime     string  `json:"start_time"`    // Format: YYYY-MM-DD HH:mm:ss
	EndTime       string  `json:"end_time"`      // Format: YYYY-MM-DD HH:mm:ss
	TotalPrice    float64 `json:"total_price"`
	LateFee       float64 `json:"late_fee"` // dikunci saat pesanan ditutup
	Status        string  `json:"status"`
	CreatedAt     string  `json:"created_at"`
	UpdatedAt     string  `json:"updated_at"`
	Notes         string  `json:"notes"` // catatan mitra, wajib saat pesanan ditolak
}

type RentalCarSchedule struct {
	ID        string  `json:"id"`
	CarID     string  `json:"car_id"`
	StartTime string  `json:"start_time"` // Format: YYYY-MM-DD HH:mm:ss
	EndTime   string  `json:"end_time"`   // Format: YYYY-MM-DD HH:mm:ss
	Reason    string  `json:"reason"`
	Status    string  `json:"status"`   // "active" | "completed"
	LateFee   float64 `json:"late_fee"` // dikunci saat jadwal ditutup
	CreatedAt string  `json:"created_at"`
}

// RentalSettings menyimpan aturan denda milik tiap pemilik armada.
// Mode "percent" berarti persen dari tarif harian mobil, "amount" nominal tetap;
// keduanya dihitung per hari keterlambatan setelah masa toleransi habis.
type RentalSettings struct {
	OwnerPhone   string  `json:"owner_phone"`
	LateFeeMode  string  `json:"late_fee_mode"` // "off" | "percent" | "amount"
	LateFeeVal   float64 `json:"late_fee_value"`
	GraceMinutes int     `json:"late_fee_grace_minutes"` // menit gratis sebelum denda mulai
	UpdatedAt    string  `json:"updated_at"`
}

type RequestOTPInput struct {
	PhoneNumber string `json:"phone_number"`
}
type VerifyOTPInput struct {
	PhoneNumber string `json:"phone_number"`
	OTP         string `json:"otp"`
}
type RegisterInput struct {
	PhoneNumber string `json:"phone_number"`
	Name        string `json:"name"`
	Email       string `json:"email"`
	Role        string `json:"role"`
	Password    string `json:"password"`
}
type TopUpInput struct {
	Amount float64 `json:"amount"`
}
type CreateOrderInput struct {
	Pickup     string  `json:"pickup"`
	Dropoff    string  `json:"dropoff"`
	PickupLat  float64 `json:"pickup_lat"`
	PickupLng  float64 `json:"pickup_lng"`
	DropoffLat float64 `json:"dropoff_lat"`
	DropoffLng float64 `json:"dropoff_lng"`
	// Tidak ada field Fare di sini dengan sengaja — ongkos ditentukan server
	// lewat hitungTarif(), dan `fare` yang dikirim aplikasi diabaikan.
	PaymentMethod   string `json:"payment_method"` // "cash" | "wallet"; kosong dianggap "cash"
	ServiceType     string `json:"service"`
	PackageType     string `json:"package_type"`
	PackageQuantity int    `json:"package_quantity"`
	PackageWeight   string `json:"package_weight"`
	PackageNotes    string `json:"package_notes"`
	Insurance       bool   `json:"insurance"`
	SpecialHandling bool   `json:"special_handling"`
}
type SaveAddressInput struct {
	Type    string `json:"type"`
	Address string `json:"address"`
}

// ==================== DATABASE & SOCKET STORE ====================

var (
	db            *sql.DB
	wsUpgrader    = websocket.Upgrader{CheckOrigin: checkWSOrigin}
	wsMutex       sync.RWMutex
	wsConnections = make(map[string][]*wsClient)
)

// wsClient membungkus satu koneksi dengan mutex tulisnya sendiri. gorilla/websocket
// panic bila dua goroutine menulis ke koneksi yang sama, dan itu bisa terjadi antara
// pengiriman riwayat chat dan broadcast pesan baru.
type wsClient struct {
	conn *websocket.Conn
	mu   sync.Mutex
	// Siapa yang sedang membuka layar chat ini. Dipakai notifikasiChat untuk
	// tidak mendengungkan HP orang yang sedang membaca pesannya.
	phone string
}

func (c *wsClient) send(msg []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.WriteMessage(websocket.TextMessage, msg)
}

// checkWSOrigin membatasi koneksi browser ke origin yang diizinkan. Klien non-browser
// (aplikasi Flutter) tidak mengirim header Origin dan tetap diterima.
func checkWSOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	for _, allowed := range allowedOrigins() {
		if origin == allowed {
			return true
		}
	}
	return !isProduction()
}

func allowedOrigins() []string {
	raw := getEnv("ALLOWED_ORIGINS", "")
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return strings.TrimSpace(value)
	}
	return fallback
}

// noDirListing menolak permintaan yang mengarah ke folder, sehingga http.FileServer
// tidak pernah menampilkan daftar isi direktori uploads.
func noDirListing(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "" || strings.HasSuffix(r.URL.Path, "/") {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	rand.Seed(time.Now().UnixNano())
	initAuth()
	initDB()
	go pruneOTPs()
	go kedaluwarsakanPesanan()

	mux := http.NewServeMux()
	mux.HandleFunc("/", homeHandler)
	mux.HandleFunc("/api/health", healthHandler)
	// ponytail: rute OTP dimatikan selama belum ada gateway SMS/WA — kodenya cuma
	// masuk backend.log, jadi endpoint ini hanya berjanji tanpa pernah mengirim.
	// Handler dan storenya sengaja dibiarkan utuh: hidupkan lagi dua baris ini
	// begitu log.Printf di requestOTPHandler diganti panggilan ke gateway.
	// mux.HandleFunc("/api/auth/request-otp", requestOTPHandler)
	// mux.HandleFunc("/api/auth/verify-otp", verifyOTPHandler)
	mux.HandleFunc("/api/auth/register", registerHandler)
	mux.HandleFunc("/api/auth/google", googleLoginHandler)
	mux.HandleFunc("/api/users/profile", profileHandler)
	mux.HandleFunc("/api/users/topup", topUpHandler)
	mux.HandleFunc("/api/users/addresses", addressesHandler)
	mux.HandleFunc("/api/orders", createOrderHandler)
	// Papan orderan berisi nama, alamat, dan koordinat GPS penumpang yang sedang
	// menunggu. Tanpa pembungkus ini siapa pun di internet bisa membacanya, jadi
	// hanya driver bertoken yang boleh melihat.
	mux.HandleFunc("/api/orders/active", requireRole("driver")(getActiveOrdersHandler))
	mux.HandleFunc("/api/orders/", orderRouterHandler)
	mux.HandleFunc("/api/driver/location", requireRole("driver")(driverLocationHandler))
	mux.HandleFunc("/api/driver/offline", requireRole("driver")(driverOfflineHandler))
	mux.HandleFunc("/api/users/delete", requireAuth(hapusAkunSendiri))
	mux.HandleFunc("/api/users/fcm-token", requireAuth(fcmTokenHandler))
	// Seluruh rute peta wajib bertoken: tiap panggilan membelanjakan kuota
	// berbayar, jadi hanya pengguna terdaftar yang boleh memicunya.
	mux.HandleFunc("/api/maps/autocomplete", requireAuth(mapsAutocompleteHandler))
	mux.HandleFunc("/api/maps/place", requireAuth(mapsPlaceHandler))
	mux.HandleFunc("/api/maps/reverse", requireAuth(mapsReverseHandler))
	mux.HandleFunc("/api/maps/route", requireAuth(mapsRouteHandler))
	// Halaman publik: Google Play menuntut URL kebijakan privasi dan URL
	// permintaan hapus akun yang bisa dibuka tanpa memasang aplikasi.
	// Didaftarkan di dua jalur dengan sengaja. Reverse proxy di depan hanya
	// meneruskan /api/*, sedangkan sisanya dilayani situs statis dashboard —
	// jadi /privasi saja akan berakhir di halaman 404 dashboard, bukan di sini.
	// /api/privasi bekerja tanpa mengubah konfigurasi server sama sekali;
	// /privasi ikut hidup begitu aturan proxy-nya ditambahkan.
	mux.HandleFunc("/privasi", kebijakanPrivasiHandler)
	mux.HandleFunc("/api/privasi", kebijakanPrivasiHandler)
	// Seluruh rute admin wajib token dengan role admin.
	admin := requireRole("admin")
	mux.HandleFunc("/api/admin/users", admin(adminUsersHandler))
	mux.HandleFunc("/api/admin/users/", admin(adminUserDetailHandler))
	mux.HandleFunc("/api/admin/orders", admin(adminOrdersHandler))
	mux.HandleFunc("/api/admin/analytics", admin(adminAnalyticsHandler))
	mux.HandleFunc("/api/admin/tarif", admin(adminTarifHandler))
	mux.HandleFunc("/api/admin/drivers/", admin(adminDriverApproveHandler))
	mux.HandleFunc("/api/admin/applications", admin(adminDriverApplicationsHandler))
	mux.HandleFunc("/api/admin/partner-applications", admin(adminPartnerApplicationsHandler))
	mux.HandleFunc("/api/admin/partner-applications/", admin(adminPartnerApplicationActionHandler))
	// Pendaftaran diajukan calon mitra/driver sendiri, jadi tetap publik.
	mux.HandleFunc("/api/admin/drivers/register", adminDriverRegisterHandler)
	mux.HandleFunc("/api/partner/register", partnerRegisterHandler)
	mux.HandleFunc("/ws/chat/", chatWebSocketHandler)
	mux.HandleFunc("/api/chat/", chatHistoryHandler)

	// bohFood & bohRental Endpoints
	// Modul mitra: wajib token, dan tiap handler memeriksa kepemilikan barisnya.
	mux.HandleFunc("/api/food/merchant", requireAuth(foodMerchantHandler))
	mux.HandleFunc("/api/food/menus", requireAuth(foodMenusHandler))
	mux.HandleFunc("/api/food/menus/", requireAuth(foodMenuDetailHandler))
	// Modul rental juga menuntut langganan aktif; halaman langganan sendiri tetap terbuka.
	rental := func(h http.HandlerFunc) http.HandlerFunc { return requireAuth(requireActiveSubscription(h)) }
	mux.HandleFunc("/api/rental/cars", rental(rentalCarsHandler))
	mux.HandleFunc("/api/rental/cars/", rental(rentalCarDetailHandler))
	mux.HandleFunc("/api/rental/bookings", rental(rentalBookingsHandler))
	mux.HandleFunc("/api/rental/bookings/", rental(rentalBookingDetailHandler))
	mux.HandleFunc("/api/rental/schedules", rental(rentalSchedulesHandler))
	mux.HandleFunc("/api/rental/schedules/", rental(rentalScheduleDetailHandler))
	mux.HandleFunc("/api/rental/settings", rental(rentalSettingsHandler))
	mux.HandleFunc("/api/rental/services", rental(rentalServicesHandler))
	mux.HandleFunc("/api/rental/services/", rental(rentalServiceDetailHandler))
	mux.HandleFunc("/api/auth/login", loginHandler)
	mux.HandleFunc("/api/upload", requireAuth(uploadHandler))

	// Subscription & Xendit Endpoints
	mux.HandleFunc("/api/subscription/status", requireAuth(subscriptionStatusHandler))
	mux.HandleFunc("/api/subscription/create", requireAuth(subscriptionCreateHandler))
	mux.HandleFunc("/api/subscription/invoices", requireAuth(subscriptionInvoicesHandler))
	mux.HandleFunc("/api/xendit/webhook", xenditWebhookHandler)
	mux.HandleFunc("/api/admin/reports/subscriptions", admin(adminReportsSubscriptionsHandler))

	// Simulator pembayaran hanya untuk pengembangan lokal, tidak pernah aktif di produksi.
	if !isProduction() {
		mux.HandleFunc("/api/xendit/mock-checkout", xenditMockCheckoutHandler)
		mux.HandleFunc("/api/xendit/mock-pay", xenditMockPayHandler)
	}

	// Serve static files for uploads, tanpa menampilkan daftar isi folder.
	mux.Handle("/uploads/", http.StripPrefix("/uploads/", noDirListing(http.FileServer(http.Dir("uploads")))))

	handler := enableCORS(mux)
	port := getEnv("PORT", "8080")
	if !strings.HasPrefix(port, ":") {
		port = ":" + port
	}
	fmt.Printf("Server bohAntar-backend berjalan di http://localhost%s\n", port)
	// Timeout mencegah koneksi menggantung menahan sumber daya (Slowloris).
	// ReadTimeout dibuat longgar supaya upload 5 MB dari jaringan seluler tetap muat;
	// ReadHeaderTimeout yang ketatlah yang menutup serangan header lambat. Koneksi
	// WebSocket tidak terpengaruh karena gorilla/websocket menghapus deadline setelah
	// hijack saat upgrade.
	srv := &http.Server{
		Addr:              port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("Gagal menjalankan server: %v", err)
	}
}

// ==================== DB LAYER ====================

func initDB() {
	var err error
	dbUser := getEnv("DB_USER", "root")
	dbPass := getEnv("DB_PASSWORD", "")
	dbHost := getEnv("DB_HOST", "localhost")
	dbPort := getEnv("DB_PORT", "3306")
	dbName := getEnv("DB_NAME", "bohantar")

	dsnRoot := fmt.Sprintf("%s:%s@tcp(%s:%s)/", dbUser, dbPass, dbHost, dbPort)
	dbRoot, err := sql.Open("mysql", dsnRoot)
	if err != nil {
		log.Fatalf("Gagal koneksi ke MySQL: %v", err)
	}
	defer dbRoot.Close()

	// Charset ditentukan sekali di tingkat database, bukan diulang di tiap
	// CREATE TABLE: tabel mewarisi charset database tempat ia dibuat. utf8mb3
	// tidak muat karakter 4 byte, jadi satu emoji di pesan chat atau nama
	// merchant membuat INSERT-nya ditolak dan pesan penggunanya hilang.
	_, err = dbRoot.Exec(fmt.Sprintf(
		"CREATE DATABASE IF NOT EXISTS %s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci", dbName))
	if err != nil {
		log.Fatalf("Gagal membuat database %s: %v", dbName, err)
	}
	// Database yang sudah telanjur lahir sebagai utf8mb3 diperbaiki di sini.
	// Ini hanya mengubah bawaan untuk tabel BARU; tabel lama dikonversi lewat
	// migrasi/001-utf8mb4-uang-indeks.sql.
	_, _ = dbRoot.Exec(fmt.Sprintf(
		"ALTER DATABASE %s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci", dbName))

	// loc=Local wajib menyertai parseTime: tanpa itu kolom DATETIME dibaca sebagai
	// UTC padahal isinya jam lokal, sehingga tiap perbandingan dengan time.Now()
	// meleset sebesar offset zona waktu (denda keterlambatan ikut salah hitung).
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&loc=Local", dbUser, dbPass, dbHost, dbPort, dbName)
	db, err = sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("Gagal membuka database %s: %v", dbName, err)
	}
	// sql.Open tidak benar-benar menyambung; Ping memastikan kesalahan konfigurasi
	// muncul saat start, bukan saat request pertama masuk.
	if err := db.Ping(); err != nil {
		log.Fatalf("Database %s tidak dapat dihubungi: %v", dbName, err)
	}
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	// Alter users table to support longer role name (e.g. rental_partner, food_merchant)
	_, _ = db.Exec("ALTER TABLE users MODIFY COLUMN role VARCHAR(30)")
	// Alter users table to support password column
	_, _ = db.Exec("ALTER TABLE users ADD COLUMN password VARCHAR(100) DEFAULT ''")
	// Alter rental_cars table to support vehicle_type column
	_, _ = db.Exec("ALTER TABLE rental_cars ADD COLUMN vehicle_type VARCHAR(20) DEFAULT 'car'")
	// Warna pembeda armada di kalender; kosong berarti dipilih otomatis oleh UI.
	_, _ = db.Exec("ALTER TABLE rental_cars ADD COLUMN color VARCHAR(20) DEFAULT ''")
	// reason menampung rangkaian "Booking - Customer: ... | Pembayaran: ... | Jasa: ... | KTP: ...";
	// VARCHAR(100) sudah kepenuhan sejak field pembayaran ditambah.
	_, _ = db.Exec("ALTER TABLE rental_car_schedules MODIFY COLUMN reason VARCHAR(500)")
	// Jadwal yang sudah ditutup tidak lagi dihapus supaya tetap terbaca di Laporan;
	// status 'completed' yang membebaskan armada, bukan penghapusan baris.
	_, _ = db.Exec("ALTER TABLE rental_car_schedules ADD COLUMN status VARCHAR(20) DEFAULT 'active'")
	// Denda keterlambatan dikunci saat sewa ditutup, bukan dihitung ulang tiap dibaca,
	// supaya nilai di laporan tidak berubah sendiri seiring waktu.
	_, _ = db.Exec("ALTER TABLE rental_car_schedules ADD COLUMN late_fee DECIMAL(12,2) NOT NULL DEFAULT 0")
	_, _ = db.Exec("ALTER TABLE rental_bookings ADD COLUMN late_fee DECIMAL(12,2) NOT NULL DEFAULT 0")
	// Toleransi keterlambatan: menit gratis sebelum denda mulai dihitung.
	_, _ = db.Exec("ALTER TABLE rental_settings ADD COLUMN late_fee_grace_minutes INT DEFAULT 0")
	// Catatan mitra saat menerima/menolak pesanan dari aplikasi.
	_, _ = db.Exec("ALTER TABLE rental_bookings ADD COLUMN notes VARCHAR(500) DEFAULT ''")
	// Nama usaha yang dipakai sebagai kop invoice. Nilai awalnya diambil dari
	// pengajuan kemitraan, tapi mitra boleh menggantinya sendiri lewat Akun Saya.
	_, _ = db.Exec("ALTER TABLE users ADD COLUMN business_name VARCHAR(100) DEFAULT ''")
	// Scan dokumen calon driver; pengajuan lama tetap ada dengan kolom kosong.
	_, _ = db.Exec("ALTER TABLE driver_applications ADD COLUMN ktp_photo_url VARCHAR(255) DEFAULT ''")
	_, _ = db.Exec("ALTER TABLE driver_applications ADD COLUMN sim_photo_url VARCHAR(255) DEFAULT ''")
	_, _ = db.Exec("ALTER TABLE driver_applications ADD COLUMN stnk_photo_url VARCHAR(255) DEFAULT ''")

	tables := []string{
		`CREATE TABLE IF NOT EXISTS users (
			phone_number VARCHAR(20) PRIMARY KEY,
			name VARCHAR(100),
			email VARCHAR(100),
			role VARCHAR(30),
			created_at VARCHAR(50),
			balance DECIMAL(14,2) NOT NULL DEFAULT 0,
			badge VARCHAR(20),
			is_driver_active BOOLEAN,
			total_orders INT,
			rating DECIMAL(3,2) NOT NULL DEFAULT 0,
			password VARCHAR(100) DEFAULT ''
		)`,
		skemaOrderRatings,
		`CREATE TABLE IF NOT EXISTS user_addresses (
			phone_number VARCHAR(20),
			address_type VARCHAR(50),
			address TEXT,
			PRIMARY KEY (phone_number, address_type)
		)`,
		`CREATE TABLE IF NOT EXISTS orders (
			id VARCHAR(50) PRIMARY KEY,
			rider_phone VARCHAR(20),
			rider_name VARCHAR(100),
			pickup TEXT,
			dropoff TEXT,
			pickup_lat DOUBLE,
			pickup_lng DOUBLE,
			dropoff_lat DOUBLE,
			dropoff_lng DOUBLE,
			fare DECIMAL(12,2) NOT NULL DEFAULT 0,
			service VARCHAR(20),
			status VARCHAR(20),
			driver_phone VARCHAR(20),
			driver_name VARCHAR(100),
			created_at VARCHAR(50),
			updated_at VARCHAR(50),
			package_type VARCHAR(50),
			package_quantity INT,
			package_weight VARCHAR(20),
			package_notes TEXT,
			insurance BOOLEAN,
			special_handling BOOLEAN
		)`,
		`CREATE TABLE IF NOT EXISTS driver_applications (
			id VARCHAR(50) PRIMARY KEY,
			phone_number VARCHAR(20),
			name VARCHAR(100),
			email VARCHAR(100),
			ktp_number VARCHAR(30),
			sim_number VARCHAR(30),
			vehicle_plate VARCHAR(20),
			vehicle_type VARCHAR(20),
			vehicle_model VARCHAR(100),
			ktp_photo_url VARCHAR(255) DEFAULT '',
			sim_photo_url VARCHAR(255) DEFAULT '',
			stnk_photo_url VARCHAR(255) DEFAULT '',
			status VARCHAR(20),
			created_at VARCHAR(50),
			notes TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS chat_messages (
			id VARCHAR(50) PRIMARY KEY,
			order_id VARCHAR(50),
			sender_phone VARCHAR(20),
			sender_name VARCHAR(100),
			sender_role VARCHAR(20),
			content TEXT,
			timestamp VARCHAR(50)
		)`,
		`CREATE TABLE IF NOT EXISTS food_merchants (
			id VARCHAR(50) PRIMARY KEY,
			owner_phone VARCHAR(20) NOT NULL,
			restaurant_name VARCHAR(100) NOT NULL,
			address TEXT NOT NULL,
			image_url TEXT,
			is_open BOOLEAN DEFAULT TRUE,
			created_at VARCHAR(50),
			FOREIGN KEY (owner_phone) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS food_menus (
			id VARCHAR(50) PRIMARY KEY,
			merchant_id VARCHAR(50) NOT NULL,
			name VARCHAR(100) NOT NULL,
			description TEXT,
			price DECIMAL(12,2) NOT NULL,
			category VARCHAR(50),
			image_url TEXT,
			is_available BOOLEAN DEFAULT TRUE,
			FOREIGN KEY (merchant_id) REFERENCES food_merchants(id) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS rental_cars (
			id VARCHAR(50) PRIMARY KEY,
			owner_phone VARCHAR(20) NOT NULL,
			brand VARCHAR(50) NOT NULL,
			model VARCHAR(50) NOT NULL,
			plate_number VARCHAR(20) NOT NULL UNIQUE,
			transmission VARCHAR(20) NOT NULL,
			seats INT DEFAULT 5,
			price_per_day DECIMAL(12,2) NOT NULL,
			image_url TEXT,
			status VARCHAR(20) DEFAULT 'active',
			vehicle_type VARCHAR(20) DEFAULT 'car',
			color VARCHAR(20) DEFAULT '',
			created_at VARCHAR(50),
			FOREIGN KEY (owner_phone) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS rental_bookings (
			id VARCHAR(50) PRIMARY KEY,
			car_id VARCHAR(50) NOT NULL,
			customer_phone VARCHAR(20) NOT NULL,
			start_time DATETIME NOT NULL,
			end_time DATETIME NOT NULL,
			total_price DECIMAL(12,2) NOT NULL,
			status VARCHAR(20) DEFAULT 'pending',
			notes VARCHAR(500) DEFAULT '',
			created_at VARCHAR(50),
			updated_at VARCHAR(50),
			FOREIGN KEY (car_id) REFERENCES rental_cars(id) ON DELETE CASCADE,
			FOREIGN KEY (customer_phone) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS rental_car_schedules (
			id VARCHAR(50) PRIMARY KEY,
			car_id VARCHAR(50) NOT NULL,
			start_time DATETIME NOT NULL,
			end_time DATETIME NOT NULL,
			reason VARCHAR(500) DEFAULT 'Maintenance',
			status VARCHAR(20) DEFAULT 'active',
			created_at VARCHAR(50),
			FOREIGN KEY (car_id) REFERENCES rental_cars(id) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS rental_settings (
			owner_phone VARCHAR(20) PRIMARY KEY,
			late_fee_mode VARCHAR(10) DEFAULT 'off',
			late_fee_value DECIMAL(12,2) NOT NULL DEFAULT 0,
			late_fee_grace_minutes INT DEFAULT 0,
			updated_at VARCHAR(50),
			FOREIGN KEY (owner_phone) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS rental_services (
			id VARCHAR(50) PRIMARY KEY,
			owner_phone VARCHAR(20) NOT NULL,
			name VARCHAR(100) NOT NULL,
			price DECIMAL(12,2) NOT NULL DEFAULT 0,
			created_at VARCHAR(50),
			FOREIGN KEY (owner_phone) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS partner_applications (
			id VARCHAR(50) PRIMARY KEY,
			type VARCHAR(20),
			phone_number VARCHAR(20),
			name VARCHAR(100),
			email VARCHAR(100),
			ktp_number VARCHAR(30),
			business_name VARCHAR(100),
			address TEXT,
			status VARCHAR(20) DEFAULT 'pending',
			created_at VARCHAR(50),
			notes TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS partner_subscriptions (
			phone_number VARCHAR(20) PRIMARY KEY,
			status VARCHAR(20) DEFAULT 'TRIAL',
			valid_until DATETIME,
			updated_at VARCHAR(50),
			FOREIGN KEY (phone_number) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		`CREATE TABLE IF NOT EXISTS subscription_invoices (
			id VARCHAR(100) PRIMARY KEY,
			phone_number VARCHAR(20),
			amount DECIMAL(12,2) NOT NULL DEFAULT 0,
			status VARCHAR(20),
			payment_url TEXT,
			created_at VARCHAR(50),
			FOREIGN KEY (phone_number) REFERENCES users(phone_number) ON DELETE CASCADE
		)`,
		// Ongkos dan bagi hasil per layanan, diatur super admin lewat dashboard.
		`CREATE TABLE IF NOT EXISTS tarif (
			layanan VARCHAR(32) PRIMARY KEY,
			base DECIMAL(12,2) NOT NULL,
			per_km DECIMAL(12,2) NOT NULL,
			komisi_persen DECIMAL(5,2) NOT NULL DEFAULT 20,
			updated_at VARCHAR(50)
		)`,
	}

	for _, t := range tables {
		if _, err := db.Exec(t); err != nil {
			log.Fatalf("Gagal inisialisasi tabel: %v", err)
		}
	}
	// Kolom password kini menyimpan hash bcrypt (60 karakter), bukan teks biasa.
	_, _ = db.Exec("ALTER TABLE users MODIFY COLUMN password VARCHAR(255) DEFAULT ''")
	// Email adalah identitas login — loginHandler dan login Google sama-sama
	// mencari akun lewat kolom ini — tapi kolomnya tidak pernah dijamin unik.
	// Dua akun beremail sama membuat salah satunya tidak bisa masuk sama sekali,
	// dan yang mana tidak bisa ditebak: dbFindUserByEmail memakai QueryRow tanpa
	// ORDER BY, jadi MySQL bebas memilih.
	//
	// Email kosong dijadikan NULL lebih dulu: indeks unik MySQL mengizinkan
	// banyak NULL, tapi menolak banyak string kosong — dan driver lama bisa
	// terlanjur punya email kosong.
	_, _ = db.Exec("UPDATE users SET email = NULL WHERE email = ''")
	if _, err := db.Exec("CREATE UNIQUE INDEX uniq_users_email ON users (email)"); err != nil {
		// "Duplicate key name" cuma berarti indeksnya sudah ada dari boot lalu.
		if !strings.Contains(err.Error(), "Duplicate key name") {
			log.Printf("PERINGATAN: indeks unik email gagal dipasang (%v). Cari kembarannya dengan: SELECT email, COUNT(*) c FROM users WHERE email IS NOT NULL GROUP BY email HAVING c > 1;", err)
		}
	}
	// Komisi aplikator dikunci saat pesanan dibuat, bukan dihitung ulang saat
	// laporan dibaca: mengubah persentase besok tidak boleh menulis ulang
	// pendapatan bulan lalu, dan driver berhak tahu angka bersihnya saat menerima.
	_, _ = db.Exec("ALTER TABLE orders ADD COLUMN komisi DECIMAL(12,2) NOT NULL DEFAULT 0")
	// Pesanan lama semuanya dibayar dari dompet, jadi baris yang sudah ada
	// memang 'wallet'. Pesanan baru selalu menyebutkan metodenya sendiri.
	_, _ = db.Exec("ALTER TABLE orders ADD COLUMN payment_method VARCHAR(10) DEFAULT 'wallet'")
	// Posisi driver terakhir. Satu baris per driver, ditimpa terus — riwayat
	// perjalanan tidak disimpan karena tidak ada yang membacanya, dan menyimpan
	// jejak lokasi orang tanpa alasan justru menambah yang harus dijaga.
	_, _ = db.Exec("ALTER TABLE users ADD COLUMN driver_lat DOUBLE DEFAULT 0")
	_, _ = db.Exec("ALTER TABLE users ADD COLUMN driver_lng DOUBLE DEFAULT 0")
	_, _ = db.Exec("ALTER TABLE users ADD COLUMN driver_loc_at VARCHAR(50) DEFAULT ''")
	// Token perangkat untuk notifikasi push. Satu per pemasangan aplikasi.
	_, _ = db.Exec("ALTER TABLE users ADD COLUMN fcm_token VARCHAR(255) DEFAULT ''")

	// Indeks dan batasan nilai dipisahkan dari CREATE TABLE karena tabelnya
	// sudah telanjur ada di produksi: `CREATE TABLE IF NOT EXISTS` tidak
	// menyentuh tabel yang sudah lahir, jadi keduanya tidak akan pernah
	// terpasang di sana kalau ditulis di dalam definisi tabel.
	//
	// Errornya sengaja dibuang: pada mesin yang sudah dijalankan sekali,
	// "Duplicate key name" dan "Duplicate check constraint name" adalah
	// jawaban yang normal, bukan kegagalan.
	//
	// Isi daftar ini sama persis dengan migrasi/001-utf8mb4-uang-indeks.sql —
	// berkas itu untuk database yang sudah hidup, daftar ini untuk mesin baru.
	penguat := []string{
		// orders tabel terpanas: driver menariknya tiap tiga detik, penumpang
		// membuka riwayatnya, goroutine kedaluwarsa menyapu yang pending.
		"CREATE INDEX idx_orders_status ON orders (status, created_at)",
		"CREATE INDEX idx_orders_driver ON orders (driver_phone)",
		"CREATE INDEX idx_orders_rider ON orders (rider_phone)",
		"CREATE INDEX idx_chat_order ON chat_messages (order_id)",
		"CREATE INDEX idx_users_role ON users (role, is_driver_active)",
		"CREATE INDEX idx_driver_apps_status ON driver_applications (status, created_at)",
		"CREATE INDEX idx_partner_apps_status ON partner_applications (status, created_at)",
		"CREATE INDEX idx_bookings_mobil ON rental_bookings (car_id, start_time, end_time)",
		"CREATE INDEX idx_schedules_mobil ON rental_car_schedules (car_id, start_time, end_time)",
		"CREATE INDEX idx_invoices_mitra ON subscription_invoices (phone_number, created_at)",

		// Tanpa batasan ini, 'cancelled' yang salah ketik jadi 'canceled'
		// diterima tanpa keluhan, lalu pesanannya lenyap dari setiap filter.
		// Daftarnya persis yang ditulis kode; tidak ada nilai lain yang pernah
		// masuk. Butuh MySQL 8.0.16+; versi lama mengabaikannya diam-diam.
		"ALTER TABLE orders ADD CONSTRAINT chk_orders_status CHECK (status IN ('pending','accepted','picked_up','completed','cancelled','expired'))",
		"ALTER TABLE orders ADD CONSTRAINT chk_orders_payment CHECK (payment_method IN ('wallet','cash'))",
		"ALTER TABLE users ADD CONSTRAINT chk_users_role CHECK (role IN ('rider','driver','admin','food_merchant','rental_partner'))",
		"ALTER TABLE order_ratings ADD CONSTRAINT chk_rating_bintang CHECK (stars BETWEEN 1 AND 5)",
		"ALTER TABLE tarif ADD CONSTRAINT chk_tarif_masuk_akal CHECK (base >= 0 AND per_km >= 0 AND komisi_persen BETWEEN 0 AND 100)",
	}
	for _, p := range penguat {
		_, _ = db.Exec(p)
	}

	seedTarif()

	var count int
	db.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
	if count == 0 {
		seedUsersToDB()
	}
	migratePlaintextPasswords()
	ensureAdminUser()
	seedDemoOjek()
}

// migratePlaintextPasswords mengubah password lama yang masih berupa teks biasa
// menjadi hash bcrypt. Idempoten: hash bcrypt selalu diawali "$2", jadi baris yang
// sudah ter-hash dilewati dan menjalankan ulang tidak mengubah apa pun.
func migratePlaintextPasswords() {
	rows, err := db.Query("SELECT phone_number, password FROM users WHERE password != '' AND password NOT LIKE '$2%'")
	if err != nil {
		log.Printf("Migrasi password dilewati: %v", err)
		return
	}
	type pending struct{ phone, plain string }
	var todo []pending
	for rows.Next() {
		var p pending
		if rows.Scan(&p.phone, &p.plain) == nil {
			todo = append(todo, p)
		}
	}
	rows.Close()

	migrated := 0
	for _, p := range todo {
		if err := dbSetPassword(p.phone, p.plain); err != nil {
			log.Printf("Gagal migrasi password %s: %v", p.phone, err)
			continue
		}
		migrated++
	}
	if migrated > 0 {
		log.Printf("Migrasi password: %d akun diubah dari teks biasa ke hash bcrypt", migrated)
	}
}

// ensureAdminUser membuat akun Super Admin bila belum ada. Password diambil dari
// ADMIN_PASSWORD; kalau kosong, dibuat acak dan dicetak sekali ke log. Password
// akun yang sudah ada tidak pernah ditimpa.
func ensureAdminUser() {
	const adminPhone = "+628000000000"
	var existing string
	if err := db.QueryRow("SELECT phone_number FROM users WHERE phone_number = ?", adminPhone).Scan(&existing); err == nil {
		return
	}

	pass := getEnv("ADMIN_PASSWORD", "")
	generated := false
	if pass == "" {
		if isProduction() {
			log.Fatal("ADMIN_PASSWORD wajib diisi saat membuat akun admin pertama di produksi")
		}
		pass, generated = randomPassword(), true
	}

	if err := dbSaveUser(User{
		PhoneNumber: adminPhone, Name: "Super Admin", Email: "admin@bohantar.com",
		Role: "admin", CreatedAt: time.Now().Format(time.RFC3339),
		Badge: "Platinum", Rating: 5.0,
	}); err != nil {
		log.Fatalf("Gagal membuat akun admin: %v", err)
	}
	if err := dbSetPassword(adminPhone, pass); err != nil {
		log.Fatalf("Gagal menyimpan password admin: %v", err)
	}
	if generated {
		log.Printf("Akun admin dibuat — email: admin@bohantar.com  password: %s  (simpan sekarang, tidak ditampilkan lagi)", pass)
	} else {
		log.Println("Akun admin dibuat dengan password dari ADMIN_PASSWORD")
	}
}

// seedDemoOjek mengisi driver dan penumpang contoh untuk pengembangan lokal.
//
// Dipisah dari seedUsersToDB karena pemicunya berbeda: seedUsersToDB hanya jalan
// saat tabel users benar-benar kosong, sedangkan ini jalan begitu tidak ada
// driver/penumpang sama sekali — jadi database yang baru dibersihkan langsung
// terisi lagi tanpa perlu menghapus akun admin dan mitra.
//
// Tidak pernah jalan di produksi: akun yang passwordnya tercetak di log tidak
// punya urusan di server sungguhan.
func seedDemoOjek() {
	if isProduction() {
		return
	}
	var ada int
	if err := db.QueryRow("SELECT COUNT(*) FROM users WHERE role IN ('rider','driver')").Scan(&ada); err != nil || ada > 0 {
		return
	}

	// Saldo nol untuk semuanya: bonus pendaftaran sudah dihapus, dan data contoh
	// tidak boleh jadi pintu belakang yang menghidupkannya lagi.
	demo := []User{
		{PhoneNumber: "+6285245111001", Name: "Ahmad Fauzi", Email: "ahmad.driver@bohantar.test", Role: "driver", CreatedAt: time.Now().Add(-96 * time.Hour).Format(time.RFC3339), Balance: 0, Badge: "Silver", IsDriverActive: true, TotalOrders: 0, Rating: 5.0},
		{PhoneNumber: "+6285245111002", Name: "Yanto Suryana", Email: "yanto.driver@bohantar.test", Role: "driver", CreatedAt: time.Now().Add(-72 * time.Hour).Format(time.RFC3339), Balance: 0, Badge: "Silver", IsDriverActive: true, TotalOrders: 0, Rating: 5.0},
		{PhoneNumber: "+6285245222001", Name: "Nur Aisyah", Email: "aisyah@bohantar.test", Role: "rider", CreatedAt: time.Now().Add(-48 * time.Hour).Format(time.RFC3339), Balance: 0, Badge: "Silver", TotalOrders: 0, Rating: 5.0},
		{PhoneNumber: "+6285245222002", Name: "Dedi Kurniawan", Email: "dedi@bohantar.test", Role: "rider", CreatedAt: time.Now().Add(-24 * time.Hour).Format(time.RFC3339), Balance: 0, Badge: "Silver", TotalOrders: 0, Rating: 5.0},
	}
	for _, u := range demo {
		dbSaveUser(u)
		pass := randomPassword()
		if err := dbSetPassword(u.PhoneNumber, pass); err == nil {
			log.Printf("Akun demo %s (%s) — password: %s", u.PhoneNumber, u.Role, pass)
		}
	}

	dbSaveAddress("+6285245222001", "Rumah", "Jl. MT Haryono, Sintang")
	dbSaveAddress("+6285245222001", "Kantor", "Jl. Pangeran Kuning, Sintang")
	dbSaveAddress("+6285245222002", "Rumah", "Jl. Lintas Melawi, Sintang")
}

func seedUsersToDB() {
	usersList := []User{
		// Driver dan penumpang demo tidak lagi di sini; lihat seedDemoOjek().
		{PhoneNumber: "+628111111111", Name: "Warung Soto Pontianak", Email: "merchant@bohfood.com", Role: "food_merchant", CreatedAt: time.Now().Add(-120 * time.Hour).Format(time.RFC3339), Balance: 500000, Badge: "Gold", TotalOrders: 0, Rating: 5.0},
		{PhoneNumber: "+628222222222", Name: "BohRental Partner", Email: "partner@bohrental.com", Role: "rental_partner", CreatedAt: time.Now().Add(-150 * time.Hour).Format(time.RFC3339), Balance: 1000000, Badge: "Platinum", TotalOrders: 0, Rating: 5.0},
	}
	for _, u := range usersList {
		dbSaveUser(u)
	}

	// Password akun demo dibuat acak dan hanya dicetak sekali ke log server.
	for _, phone := range []string{"+628111111111", "+628222222222"} {
		pass := randomPassword()
		if err := dbSetPassword(phone, pass); err == nil {
			log.Printf("Akun demo %s — password: %s", phone, pass)
		}
	}

	// Seed Food Merchant & Menu
	_, _ = db.Exec(`INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, image_url, is_open, created_at)
		VALUES ('merchant-1', '+628111111111', 'Warung Soto Pontianak', 'Jl. Gajah Mada No. 12, Pontianak', 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400', 1, ?)`, time.Now().Format(time.RFC3339))
	_, _ = db.Exec(`INSERT INTO food_menus (id, merchant_id, name, description, price, category, image_url, is_available) VALUES 
		('menu-1', 'merchant-1', 'Soto Ayam Spesial', 'Soto ayam dengan kuah kuning gurih', 18000, 'Makanan', 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=100', 1),
		('menu-2', 'merchant-1', 'Soto Daging Sapi', 'Soto daging sapi empuk melimpah', 25000, 'Makanan', 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=100', 1),
		('menu-3', 'merchant-1', 'Es Teh Manis', 'Es teh segar manis pas', 5000, 'Minuman', 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=100', 1)`)

	// Seed Rental Cars. Dua placeholder butuh dua argumen; sebelumnya hanya satu
	// yang dikirim sehingga INSERT selalu gagal diam-diam dan tabel tetap kosong.
	now := time.Now().Format(time.RFC3339)
	if _, err := db.Exec(`INSERT INTO rental_cars (id, owner_phone, brand, model, plate_number, transmission, seats, price_per_day, image_url, status, created_at) VALUES 
		('car-1', '+628222222222', 'Toyota', 'Avanza Veloz', 'KB 1234 XX', 'Automatic', 7, 350000, 'https://images.unsplash.com/photo-1549399542-7e3f8b79c341?w=400', 'active', ?),
		('car-2', '+628222222222', 'Honda', 'Brio Satya', 'KB 5678 YY', 'Manual', 5, 250000, 'https://images.unsplash.com/photo-1619767886558-efdc259cde1a?w=400', 'active', ?)`, now, now); err != nil {
		log.Printf("Seed rental_cars gagal: %v", err)
	}

	services := []string{"BohRide", "BohCar", "BohAntar", "BohSend"}
	statuses := []string{"completed", "completed", "completed", "cancelled", "pending"}
	riderPhones := []string{"+628123456789", "+628777777777"}
	driverPhones := []string{"+628888888888", "+628666666666"}
	riderNames := map[string]string{"+628123456789": "Budi Santoso", "+628777777777": "Sari Dewi"}
	driverNames := map[string]string{"+628888888888": "Heri Setiawan", "+628666666666": "Rudi Hartono"}

	for i := 0; i < 25; i++ {
		oid := fmt.Sprintf("order-seed-%d", i)
		status := statuses[i%len(statuses)]
		dp, dn := "", ""
		if status == "completed" {
			dp = driverPhones[i%len(driverPhones)]
			dn = driverNames[dp]
		}
		rp := riderPhones[i%len(riderPhones)]
		fare := float64(8000 + rand.Intn(40000))
		o := Order{
			ID: oid, RiderPhone: rp, RiderName: riderNames[rp],
			PickupAddress: "Jl. Merdeka, Pontianak", DropoffAddress: "Jl. Ahmad Yani, Pontianak",
			PickupLat: -0.02012, PickupLng: 109.33878, DropoffLat: -0.03500, DropoffLng: 109.34500,
			Fare: fare, Service: services[i%len(services)], Status: status,
			DriverPhone: dp, DriverName: dn,
			CreatedAt: time.Now().Add(-time.Duration(i) * 2 * time.Hour).Format(time.RFC3339),
			UpdatedAt: time.Now().Add(-time.Duration(i) * time.Hour).Format(time.RFC3339),
		}
		dbSaveOrder(o)
	}
}

func dbGetUser(phone string) (User, bool) {
	var u User
	var isDriverActive bool
	row := db.QueryRow("SELECT phone_number, name, COALESCE(email, ''), role, created_at, balance, badge, is_driver_active, total_orders, rating FROM users WHERE phone_number = ?", phone)
	err := row.Scan(&u.PhoneNumber, &u.Name, &u.Email, &u.Role, &u.CreatedAt, &u.Balance, &u.Badge, &isDriverActive, &u.TotalOrders, &u.Rating)
	if err != nil {
		return u, false
	}
	u.IsDriverActive = isDriverActive
	u.Addresses, _ = dbGetAddresses(phone)
	return u, true
}

// dbSaveUser sengaja tidak menyentuh kolom password. Password hanya diubah lewat
// dbSetPassword, supaya tidak ikut terhapus setiap kali profil user disimpan.
func dbSaveUser(u User) error {
	_, err := db.Exec(`
		INSERT INTO users (phone_number, name, email, role, created_at, balance, badge, is_driver_active, total_orders, rating)
		VALUES (?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE
			name = VALUES(name),
			email = VALUES(email),
			role = VALUES(role),
			balance = VALUES(balance),
			badge = VALUES(badge),
			is_driver_active = VALUES(is_driver_active),
			total_orders = VALUES(total_orders),
			rating = VALUES(rating)
	`, u.PhoneNumber, u.Name, u.Email, u.Role, u.CreatedAt, u.Balance, u.Badge, u.IsDriverActive, u.TotalOrders, u.Rating)
	return err
}

func dbSetPassword(phone, plain string) error {
	hash, err := hashPassword(plain)
	if err != nil {
		return err
	}
	_, err = db.Exec("UPDATE users SET password = ? WHERE phone_number = ?", hash, phone)
	return err
}

// dbFindUserByEmail mengembalikan user beserta hash password-nya untuk keperluan login.
func dbFindUserByEmail(email string) (User, string, bool) {
	var u User
	var hash string
	var isDriverActive bool
	err := db.QueryRow(`
		SELECT phone_number, name, COALESCE(email, ''), role, created_at, balance, badge, is_driver_active, total_orders, rating, COALESCE(password, '')
		FROM users WHERE email = ?`, email).
		Scan(&u.PhoneNumber, &u.Name, &u.Email, &u.Role, &u.CreatedAt, &u.Balance, &u.Badge, &isDriverActive, &u.TotalOrders, &u.Rating, &hash)
	if err != nil {
		return u, "", false
	}
	u.IsDriverActive = isDriverActive
	return u, hash, true
}

func dbDeleteUser(phone string) error {
	db.Exec("DELETE FROM user_addresses WHERE phone_number = ?", phone)
	_, err := db.Exec("DELETE FROM users WHERE phone_number = ?", phone)
	return err
}

func dbGetUsers(roleFilter string, page, limit int) ([]User, int, error) {
	var total int
	var err error
	if roleFilter != "" {
		err = db.QueryRow("SELECT COUNT(*) FROM users WHERE role = ?", roleFilter).Scan(&total)
	} else {
		err = db.QueryRow("SELECT COUNT(*) FROM users").Scan(&total)
	}
	if err != nil {
		return nil, 0, err
	}

	var rows *sql.Rows
	offset := (page - 1) * limit
	if roleFilter != "" {
		rows, err = db.Query("SELECT phone_number, name, COALESCE(email, ''), role, created_at, balance, badge, is_driver_active, total_orders, rating FROM users WHERE role = ? LIMIT ? OFFSET ?", roleFilter, limit, offset)
	} else {
		rows, err = db.Query("SELECT phone_number, name, COALESCE(email, ''), role, created_at, balance, badge, is_driver_active, total_orders, rating FROM users LIMIT ? OFFSET ?", limit, offset)
	}
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var result []User
	for rows.Next() {
		var u User
		var isDriverActive bool
		if err := rows.Scan(&u.PhoneNumber, &u.Name, &u.Email, &u.Role, &u.CreatedAt, &u.Balance, &u.Badge, &isDriverActive, &u.TotalOrders, &u.Rating); err == nil {
			u.IsDriverActive = isDriverActive
			u.Addresses, _ = dbGetAddresses(u.PhoneNumber)
			result = append(result, u)
		}
	}
	return result, total, nil
}

func dbGetAddresses(phone string) (map[string]string, error) {
	rows, err := db.Query("SELECT address_type, address FROM user_addresses WHERE phone_number = ?", phone)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	addrs := make(map[string]string)
	for rows.Next() {
		var t, a string
		if err := rows.Scan(&t, &a); err == nil {
			addrs[t] = a
		}
	}
	return addrs, nil
}

func dbSaveAddress(phone, addrType, address string) error {
	_, err := db.Exec(`
		INSERT INTO user_addresses (phone_number, address_type, address)
		VALUES (?, ?, ?)
		ON DUPLICATE KEY UPDATE address = VALUES(address)
	`, phone, addrType, address)
	return err
}

func dbGetOrder(id string) (Order, bool) {
	var o Order
	row := db.QueryRow(`
		SELECT id, rider_phone, rider_name, pickup, dropoff, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
		fare, COALESCE(komisi, 0), COALESCE(payment_method, 'wallet'), service, status, driver_phone, driver_name, created_at, updated_at,
		package_type, package_quantity, package_weight, package_notes, insurance, special_handling
		FROM orders WHERE id = ?
	`, id)
	var pkgType, pkgWeight, pkgNotes sql.NullString
	var pkgQty sql.NullInt64
	var ins, spec sql.NullBool
	err := row.Scan(
		&o.ID, &o.RiderPhone, &o.RiderName, &o.PickupAddress, &o.DropoffAddress, &o.PickupLat, &o.PickupLng, &o.DropoffLat, &o.DropoffLng,
		&o.Fare, &o.Komisi, &o.PaymentMethod, &o.Service, &o.Status, &o.DriverPhone, &o.DriverName, &o.CreatedAt, &o.UpdatedAt,
		&pkgType, &pkgQty, &pkgWeight, &pkgNotes, &ins, &spec,
	)
	if err != nil {
		return o, false
	}
	o.PackageType = pkgType.String
	o.PackageQuantity = int(pkgQty.Int64)
	o.PackageWeight = pkgWeight.String
	o.PackageNotes = pkgNotes.String
	o.Insurance = ins.Bool
	o.SpecialHandling = spec.Bool
	return o, true
}

func dbSaveOrder(o Order) error {
	_, err := db.Exec(`
		INSERT INTO orders (id, rider_phone, rider_name, pickup, dropoff, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
		fare, komisi, payment_method, service, status, driver_phone, driver_name, created_at, updated_at,
		package_type, package_quantity, package_weight, package_notes, insurance, special_handling)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE
			status = VALUES(status),
			driver_phone = VALUES(driver_phone),
			driver_name = VALUES(driver_name),
			updated_at = VALUES(updated_at)
	`, o.ID, o.RiderPhone, o.RiderName, o.PickupAddress, o.DropoffAddress, o.PickupLat, o.PickupLng, o.DropoffLat, o.DropoffLng,
		o.Fare, o.Komisi, o.PaymentMethod, o.Service, o.Status, o.DriverPhone, o.DriverName, o.CreatedAt, o.UpdatedAt,
		o.PackageType, o.PackageQuantity, o.PackageWeight, o.PackageNotes, o.Insurance, o.SpecialHandling)
	return err
}

// dbClaimOrder menandai pesanan diterima HANYA kalau saat itu masih pending,
// dan mengembalikan false kalau sudah keburu diambil orang lain.
//
// Syaratnya sengaja dititipkan ke MySQL, bukan diperiksa lebih dulu di Go:
// semua driver dibangunkan notifikasi di detik yang sama dan polling tiap tiga
// detik, jadi dua orang menekan Terima dalam milidetik yang sama itu wajar.
// Dengan baca-periksa-tulis biasa keduanya lolos — yang menulis belakangan
// menang, sementara yang pertama tetap diberi tahu "berhasil" lalu berangkat
// menjemput penumpang yang bukan miliknya.
func dbClaimOrder(orderID, driverPhone, driverName, updatedAt string) (bool, error) {
	res, err := db.Exec(`
		UPDATE orders SET status = 'accepted', driver_phone = ?, driver_name = ?, updated_at = ?
		WHERE id = ? AND status = 'pending'`,
		driverPhone, driverName, updatedAt, orderID)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// dbSaldoTertahan menjumlahkan tarif pesanan dompet penumpang yang belum
// selesai — uang yang sudah dijanjikan tapi belum berpindah.
//
// ponytail: dihitung ulang tiap pemesanan, bukan disimpan di kolom sendiri.
// Satu penumpang tidak pernah punya banyak pesanan berjalan, jadi jumlahnya
// selalu sedikit. Pasang kolom saldo tertahan kalau suatu hari ada penumpang
// dengan puluhan pesanan sekaligus.
func dbSaldoTertahan(riderPhone string) (float64, error) {
	var total sql.NullFloat64
	err := db.QueryRow(`
		SELECT SUM(fare) FROM orders
		WHERE rider_phone = ? AND payment_method = 'wallet'
		  AND status IN ('pending', 'accepted', 'picked_up')`, riderPhone).Scan(&total)
	if err != nil {
		return 0, err
	}
	return total.Float64, nil
}

// dbCancelOrder membatalkan pesanan hanya kalau statusnya masih salah satu dari
// yang diizinkan, dan mengembalikan false kalau sudah terlanjur berpindah.
func dbCancelOrder(orderID string, statusBoleh []string, updatedAt string) (bool, error) {
	args := []interface{}{updatedAt, orderID}
	tanda := make([]string, len(statusBoleh))
	for i, s := range statusBoleh {
		tanda[i] = "?"
		args = append(args, s)
	}
	res, err := db.Exec(
		"UPDATE orders SET status = 'cancelled', updated_at = ? WHERE id = ? AND status IN ("+strings.Join(tanda, ",")+")",
		args...)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

func dbGetOrders(driver, rider, status string, page, limit int) ([]Order, int, error) {
	countQ := "SELECT COUNT(*) FROM orders WHERE 1=1"
	var countArgs []interface{}
	if driver != "" {
		countQ += " AND driver_phone = ?"
		countArgs = append(countArgs, driver)
	}
	if rider != "" {
		countQ += " AND rider_phone = ?"
		countArgs = append(countArgs, rider)
	}
	if status != "" {
		countQ += " AND status = ?"
		countArgs = append(countArgs, status)
	}
	var total int
	err := db.QueryRow(countQ, countArgs...).Scan(&total)
	if err != nil {
		return nil, 0, err
	}

	q := "SELECT id, rider_phone, rider_name, pickup, dropoff, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, fare, COALESCE(komisi, 0), COALESCE(payment_method, 'wallet'), service, status, driver_phone, driver_name, created_at, updated_at, package_type, package_quantity, package_weight, package_notes, insurance, special_handling FROM orders WHERE 1=1"
	var args []interface{}
	if driver != "" {
		q += " AND driver_phone = ?"
		args = append(args, driver)
	}
	if rider != "" {
		q += " AND rider_phone = ?"
		args = append(args, rider)
	}
	if status != "" {
		q += " AND status = ?"
		args = append(args, status)
	}
	q += " ORDER BY created_at DESC"

	if limit > 0 {
		offset := (page - 1) * limit
		q += " LIMIT ? OFFSET ?"
		args = append(args, limit, offset)
	}

	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var result []Order
	for rows.Next() {
		var o Order
		var pkgType, pkgWeight, pkgNotes sql.NullString
		var pkgQty sql.NullInt64
		var ins, spec sql.NullBool
		err := rows.Scan(
			&o.ID, &o.RiderPhone, &o.RiderName, &o.PickupAddress, &o.DropoffAddress, &o.PickupLat, &o.PickupLng, &o.DropoffLat, &o.DropoffLng,
			&o.Fare, &o.Komisi, &o.PaymentMethod, &o.Service, &o.Status, &o.DriverPhone, &o.DriverName, &o.CreatedAt, &o.UpdatedAt,
			&pkgType, &pkgQty, &pkgWeight, &pkgNotes, &ins, &spec,
		)
		if err == nil {
			o.PackageType = pkgType.String
			o.PackageQuantity = int(pkgQty.Int64)
			o.PackageWeight = pkgWeight.String
			o.PackageNotes = pkgNotes.String
			o.Insurance = ins.Bool
			o.SpecialHandling = spec.Bool
			result = append(result, o)
		}
	}
	return result, total, nil
}

func dbGetPendingOrders() ([]Order, error) {
	res, _, err := dbGetOrders("", "", "pending", 0, 0)
	return res, err
}

func dbSaveApplication(a DriverApplication) error {
	_, err := db.Exec(`
		INSERT INTO driver_applications (id, phone_number, name, email, ktp_number, sim_number, vehicle_plate, vehicle_type, vehicle_model, ktp_photo_url, sim_photo_url, stnk_photo_url, status, created_at, notes)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE status = VALUES(status)
	`, a.ID, a.PhoneNumber, a.Name, a.Email, a.KTPNumber, a.SIMNumber, a.VehiclePlate, a.VehicleType, a.VehicleModel, a.KTPPhotoURL, a.SIMPhotoURL, a.STNKPhotoURL, a.Status, a.CreatedAt, a.Notes)
	return err
}

func dbGetApplication(id string) (DriverApplication, bool) {
	var a DriverApplication
	row := db.QueryRow("SELECT id, phone_number, name, email, ktp_number, sim_number, vehicle_plate, vehicle_type, vehicle_model, ktp_photo_url, sim_photo_url, stnk_photo_url, status, created_at, notes FROM driver_applications WHERE id = ?", id)
	var notes sql.NullString
	err := row.Scan(&a.ID, &a.PhoneNumber, &a.Name, &a.Email, &a.KTPNumber, &a.SIMNumber, &a.VehiclePlate, &a.VehicleType, &a.VehicleModel, &a.KTPPhotoURL, &a.SIMPhotoURL, &a.STNKPhotoURL, &a.Status, &a.CreatedAt, &notes)
	if err != nil {
		return a, false
	}
	a.Notes = notes.String
	return a, true
}

func dbGetApplications(statusFilter string) ([]DriverApplication, error) {
	var rows *sql.Rows
	var err error
	if statusFilter != "" {
		rows, err = db.Query("SELECT id, phone_number, name, email, ktp_number, sim_number, vehicle_plate, vehicle_type, vehicle_model, ktp_photo_url, sim_photo_url, stnk_photo_url, status, created_at, notes FROM driver_applications WHERE status = ?", statusFilter)
	} else {
		rows, err = db.Query("SELECT id, phone_number, name, email, ktp_number, sim_number, vehicle_plate, vehicle_type, vehicle_model, ktp_photo_url, sim_photo_url, stnk_photo_url, status, created_at, notes FROM driver_applications")
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []DriverApplication
	for rows.Next() {
		var a DriverApplication
		var notes sql.NullString
		if err := rows.Scan(&a.ID, &a.PhoneNumber, &a.Name, &a.Email, &a.KTPNumber, &a.SIMNumber, &a.VehiclePlate, &a.VehicleType, &a.VehicleModel, &a.KTPPhotoURL, &a.SIMPhotoURL, &a.STNKPhotoURL, &a.Status, &a.CreatedAt, &notes); err == nil {
			a.Notes = notes.String
			result = append(result, a)
		}
	}
	return result, nil
}

func dbSavePartnerApplication(a PartnerApplication) error {
	_, err := db.Exec(`
		INSERT INTO partner_applications (id, type, phone_number, name, email, ktp_number, business_name, address, status, created_at, notes)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE status = VALUES(status)
	`, a.ID, a.Type, a.PhoneNumber, a.Name, a.Email, a.KTPNumber, a.BusinessName, a.Address, a.Status, a.CreatedAt, a.Notes)
	return err
}

func dbGetPartnerApplication(id string) (PartnerApplication, bool) {
	var a PartnerApplication
	row := db.QueryRow("SELECT id, type, phone_number, name, email, ktp_number, business_name, address, status, created_at, notes FROM partner_applications WHERE id = ?", id)
	var notes sql.NullString
	err := row.Scan(&a.ID, &a.Type, &a.PhoneNumber, &a.Name, &a.Email, &a.KTPNumber, &a.BusinessName, &a.Address, &a.Status, &a.CreatedAt, &notes)
	if err != nil {
		return a, false
	}
	a.Notes = notes.String
	return a, true
}

func dbGetPartnerApplications(typeFilter, statusFilter string) ([]PartnerApplication, error) {
	var rows *sql.Rows
	var err error
	q := "SELECT id, type, phone_number, name, email, ktp_number, business_name, address, status, created_at, notes FROM partner_applications WHERE 1=1"
	var args []interface{}
	if typeFilter != "" {
		q += " AND type = ?"
		args = append(args, typeFilter)
	}
	if statusFilter != "" {
		q += " AND status = ?"
		args = append(args, statusFilter)
	}
	q += " ORDER BY created_at DESC"

	rows, err = db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []PartnerApplication
	for rows.Next() {
		var a PartnerApplication
		var notes sql.NullString
		if err := rows.Scan(&a.ID, &a.Type, &a.PhoneNumber, &a.Name, &a.Email, &a.KTPNumber, &a.BusinessName, &a.Address, &a.Status, &a.CreatedAt, &notes); err == nil {
			a.Notes = notes.String
			result = append(result, a)
		}
	}
	return result, nil
}

func dbGetPartnerSubscription(phone string) (PartnerSubscription, bool) {
	var s PartnerSubscription
	row := db.QueryRow("SELECT phone_number, status, valid_until, updated_at FROM partner_subscriptions WHERE phone_number = ?", phone)
	var validUntil time.Time
	err := row.Scan(&s.PhoneNumber, &s.Status, &validUntil, &s.UpdatedAt)
	if err != nil {
		return s, false
	}
	s.ValidUntil = validUntil.Format(time.RFC3339)
	return s, true
}

func dbSavePartnerSubscription(s PartnerSubscription) error {
	validUntil, err := time.Parse(time.RFC3339, s.ValidUntil)
	if err != nil {
		validUntil = time.Now()
	}
	_, err = db.Exec("INSERT INTO partner_subscriptions (phone_number, status, valid_until, updated_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE status = ?, valid_until = ?, updated_at = ?",
		s.PhoneNumber, s.Status, validUntil, s.UpdatedAt, s.Status, validUntil, s.UpdatedAt)
	return err
}

func dbSaveSubscriptionInvoice(inv SubscriptionInvoice) error {
	createdAt, err := time.Parse(time.RFC3339, inv.CreatedAt)
	if err != nil {
		createdAt = time.Now()
	}
	_, err = db.Exec("INSERT INTO subscription_invoices (id, phone_number, amount, status, payment_url, created_at) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE status = ?",
		inv.ID, inv.PhoneNumber, inv.Amount, inv.Status, inv.PaymentURL, createdAt, inv.Status)
	return err
}

// subscription_invoices.created_at bertipe VARCHAR(50), bukan DATETIME. parseTime=true
// hanya menyentuh kolom waktu sungguhan, jadi memindainya ke time.Time SELALU gagal —
// dan karena kegagalan itu cuma jadi "tidak ketemu", webhook Xendit tidak pernah bisa
// mengaktifkan langganan siapa pun. Dibaca sebagai teks, lalu dinormalkan.
func waktuInvoice(mentah string) string {
	for _, pola := range []string{time.RFC3339, "2006-01-02 15:04:05"} {
		if t, err := time.Parse(pola, mentah); err == nil {
			return t.Format(time.RFC3339)
		}
	}
	return mentah
}

func dbGetSubscriptionInvoice(id string) (SubscriptionInvoice, bool) {
	var inv SubscriptionInvoice
	row := db.QueryRow("SELECT id, phone_number, amount, status, payment_url, created_at FROM subscription_invoices WHERE id = ?", id)
	var createdAt string
	err := row.Scan(&inv.ID, &inv.PhoneNumber, &inv.Amount, &inv.Status, &inv.PaymentURL, &createdAt)
	if err != nil {
		if err != sql.ErrNoRows {
			log.Printf("Invoice %s gagal dibaca: %v", id, err)
		}
		return inv, false
	}
	inv.CreatedAt = waktuInvoice(createdAt)
	return inv, true
}

func dbGetSubscriptionInvoices(phone string) ([]SubscriptionInvoice, error) {
	var rows *sql.Rows
	var err error
	if phone != "" {
		rows, err = db.Query(`
			SELECT i.id, i.phone_number, COALESCE(u.name, '') as partner_name, i.amount, i.status, i.payment_url, i.created_at 
			FROM subscription_invoices i 
			LEFT JOIN users u ON i.phone_number = u.phone_number 
			WHERE i.phone_number = ? 
			ORDER BY i.created_at DESC`, phone)
	} else {
		rows, err = db.Query(`
			SELECT i.id, i.phone_number, COALESCE(u.name, '') as partner_name, i.amount, i.status, i.payment_url, i.created_at 
			FROM subscription_invoices i 
			LEFT JOIN users u ON i.phone_number = u.phone_number 
			ORDER BY i.created_at DESC`)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []SubscriptionInvoice
	for rows.Next() {
		var inv SubscriptionInvoice
		var createdAt string
		if err := rows.Scan(&inv.ID, &inv.PhoneNumber, &inv.PartnerName, &inv.Amount, &inv.Status, &inv.PaymentURL, &createdAt); err != nil {
			// Dulu baris gagal dilewati diam-diam, jadi daftar tagihan admin selalu
			// kosong tanpa ada yang tahu sebabnya.
			log.Printf("Baris subscription_invoices dilewati: %v", err)
			continue
		}
		inv.CreatedAt = waktuInvoice(createdAt)
		result = append(result, inv)
	}
	return result, nil
}

func dbGetChatMessages(orderID string) ([]ChatMessage, error) {
	rows, err := db.Query("SELECT id, order_id, sender_phone, sender_name, sender_role, content, timestamp FROM chat_messages WHERE order_id = ? ORDER BY timestamp ASC", orderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []ChatMessage
	for rows.Next() {
		var m ChatMessage
		if err := rows.Scan(&m.ID, &m.OrderID, &m.SenderPhone, &m.SenderName, &m.SenderRole, &m.Content, &m.Timestamp); err == nil {
			result = append(result, m)
		}
	}
	return result, nil
}

func dbSaveChatMessage(m ChatMessage) error {
	_, err := db.Exec("INSERT INTO chat_messages (id, order_id, sender_phone, sender_name, sender_role, content, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)",
		m.ID, m.OrderID, m.SenderPhone, m.SenderName, m.SenderRole, m.Content, m.Timestamp)
	return err
}

func dbGetAnalyticsData() (map[string]interface{}, error) {
	// Dihitung per status, bukan lewat pengurangan — sebelumnya accepted dan picked_up
	// ikut terhitung sebagai pending sehingga angka dashboard terlalu besar.
	byStatus := map[string]int{}
	totalOrders := 0
	if rows, err := db.Query("SELECT status, COUNT(*) FROM orders GROUP BY status"); err == nil {
		for rows.Next() {
			var st string
			var n int
			if rows.Scan(&st, &n) == nil {
				byStatus[st] = n
				totalOrders += n
			}
		}
		rows.Close()
	}
	completedOrders := byStatus["completed"]
	cancelledOrders := byStatus["cancelled"]
	pendingOrders := byStatus["pending"]
	ongoingOrders := byStatus["accepted"] + byStatus["picked_up"]

	var totalRevenue float64
	db.QueryRow("SELECT COALESCE(SUM(fare), 0) FROM orders WHERE status = 'completed'").Scan(&totalRevenue)

	var totalUsers, totalRiders, totalDrivers int
	db.QueryRow("SELECT COUNT(*) FROM users").Scan(&totalUsers)
	db.QueryRow("SELECT COUNT(*) FROM users WHERE role = 'rider'").Scan(&totalRiders)
	db.QueryRow("SELECT COUNT(*) FROM users WHERE role = 'driver'").Scan(&totalDrivers)

	rows, err := db.Query("SELECT driver_phone, driver_name, COUNT(*), SUM(fare) FROM orders WHERE status = 'completed' AND driver_phone != '' GROUP BY driver_phone, driver_name")
	var driverList []map[string]interface{}
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var phone, name string
			var count int
			var income float64
			if rows.Scan(&phone, &name, &count, &income) == nil {
				driverList = append(driverList, map[string]interface{}{
					"driver_phone": phone,
					"driver_name":  name,
					"order_count":  count,
					"total_income": income,
				})
			}
		}
	}

	return map[string]interface{}{
		"total_orders":     totalOrders,
		"completed_orders": completedOrders,
		"cancelled_orders": cancelledOrders,
		"pending_orders":   pendingOrders,
		"ongoing_orders":   ongoingOrders,
		"total_revenue":    totalRevenue,
		"total_users":      totalUsers,
		"total_riders":     totalRiders,
		"total_drivers":    totalDrivers,
		"driver_stats":     driverList,
	}, nil
}

// ==================== HELPERS ====================

func enableCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSONResponse(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// ==================== AUTH HANDLERS ====================

func homeHandler(w http.ResponseWriter, r *http.Request) {
	// Pola "/" menangkap semua path yang tidak cocok, jadi hanya root yang dibalas 200.
	if r.URL.Path != "/" {
		writeJSONResponse(w, http.StatusNotFound, map[string]string{"error": "Endpoint tidak ditemukan"})
		return
	}
	writeJSONResponse(w, http.StatusOK, map[string]string{"status": "success", "message": "Selamat datang di API bohAntar!"})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSONResponse(w, http.StatusOK, map[string]string{"status": "healthy"})
}

func requestOTPHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input RequestOTPInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.PhoneNumber == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Nomor handphone tidak valid"})
		return
	}
	otp := newOTP()
	saveOTP(input.PhoneNumber, otp)

	// OTP hanya keluar lewat log server, tidak pernah lewat response.
	log.Printf("[SMS] To: %s OTP: %s", input.PhoneNumber, otp)
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "OTP berhasil dikirim"})
}

func verifyOTPHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input VerifyOTPInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.PhoneNumber == "" || input.OTP == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Input tidak valid"})
		return
	}
	if !consumeOTP(input.PhoneNumber, input.OTP) {
		writeJSONResponse(w, 400, map[string]string{"error": "Kode OTP salah atau kedaluwarsa"})
		return
	}

	user, userExists := dbGetUser(input.PhoneNumber)
	role := "rider"
	if userExists {
		role = user.Role
	}
	token, err := issueToken(input.PhoneNumber, role)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat token sesi"})
		return
	}
	if userExists {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "is_new_user": false, "token": token, "user": user})
	} else {
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "is_new_user": true, "token": token})
	}
}

// normalizePhone menyeragamkan nomor HP ke bentuk +62 supaya satu orang tidak
// berakhir punya dua akun hanya karena mengetik 0812 dan +62812.
func normalizePhone(raw string) string {
	phone := strings.TrimSpace(raw)
	if strings.HasPrefix(phone, "0") {
		phone = "+62" + phone[1:]
	}
	if !strings.HasPrefix(phone, "+62") {
		phone = "+62" + phone
	}
	return phone
}

func registerHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input RegisterInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.PhoneNumber == "" || input.Name == "" || input.Email == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Harap isi semua data dengan benar"})
		return
	}
	// Endpoint ini publik dan tidak memverifikasi apa pun, jadi hanya boleh
	// membuat penumpang. Driver wajib lewat pengajuan berdokumen di
	// POST /api/admin/drivers/register yang disetujui super admin — tanpa
	// batas ini siapa pun bisa mendaftar sebagai driver dalam setengah menit
	// lalu menerima pesanan berisi alamat rumah penumpang sungguhan.
	if input.Role == "driver" {
		writeJSONResponse(w, 403, map[string]string{"error": "Pendaftaran driver harus melalui pengajuan dengan dokumen dan persetujuan admin."})
		return
	}
	if len(input.Password) < 8 {
		writeJSONResponse(w, 400, map[string]string{"error": "Password minimal 8 karakter"})
		return
	}
	input.PhoneNumber = normalizePhone(input.PhoneNumber)
	input.Email = strings.ToLower(strings.TrimSpace(input.Email))

	// Endpoint ini publik, jadi wajib menolak nomor dan email yang sudah dipakai.
	// Tanpa ini siapa pun bisa mendaftar ulang memakai nomor orang lain, menimpa
	// profilnya lewat ON DUPLICATE KEY, dan menerima token sesi atas nama dia.
	if _, exists := dbGetUser(input.PhoneNumber); exists {
		writeJSONResponse(w, 409, map[string]string{"error": "Nomor handphone ini sudah terdaftar. Silakan masuk."})
		return
	}
	if _, _, found := dbFindUserByEmail(input.Email); found {
		writeJSONResponse(w, 409, map[string]string{"error": "Email ini sudah terdaftar. Silakan masuk."})
		return
	}

	// Saldo awal nol. Bonus Rp75.000 per pendaftaran dulu bisa dicetak tanpa batas:
	// daftar dua akun, pesan seharga bonusnya, selesaikan, saldonya menumpuk di
	// satu akun, ulangi. Saldo hanya boleh bertambah lewat pembayaran sungguhan.
	u := User{PhoneNumber: input.PhoneNumber, Name: input.Name, Email: input.Email, Role: "rider", CreatedAt: time.Now().Format(time.RFC3339), Balance: 0, Badge: "Silver", TotalOrders: 0, Rating: 5.0}
	dbSaveUser(u)
	if err := dbSetPassword(u.PhoneNumber, input.Password); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan password"})
		return
	}
	dbSaveAddress(input.PhoneNumber, "Rumah", "Jl. Merdeka No. 10, Pontianak")

	token, err := issueToken(u.PhoneNumber, u.Role)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat token sesi"})
		return
	}
	writeJSONResponse(w, 201, map[string]interface{}{"status": "success", "message": "Registrasi berhasil", "token": token, "user": u})
}

func googleLoginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input struct {
		IDToken     string `json:"id_token"`
		Nonce       string `json:"nonce"`
		PhoneNumber string `json:"phone_number"`
		Role        string `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.IDToken == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "id_token Google diperlukan"})
		return
	}

	// Identitas hanya boleh berasal dari token Google yang sudah diverifikasi.
	email, name, err := verifyGoogleIDToken(r.Context(), input.IDToken, input.Nonce)
	if err != nil {
		writeJSONResponse(w, 401, map[string]string{"error": err.Error()})
		return
	}

	// 1. Cek apakah email sudah terdaftar
	u, _, found := dbFindUserByEmail(email)
	if found {
		token, err := issueToken(u.PhoneNumber, u.Role)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat token sesi"})
			return
		}
		u.Addresses, _ = dbGetAddresses(u.PhoneNumber)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "token": token, "user": u})
		return
	}

	// 2. Email belum terdaftar, butuh pendaftaran baru. Cek apakah nomor HP sudah disediakan.
	if input.PhoneNumber == "" {
		// Minta input nomor HP ke frontend
		writeJSONResponse(w, 200, map[string]interface{}{"status": "need_phone", "email": email, "name": name})
		return
	}

	// Bersihkan dan validasi nomor HP
	phone := normalizePhone(input.PhoneNumber)

	// Cek apakah nomor HP sudah dipakai akun lain
	var existingEmail string
	if err := db.QueryRow("SELECT COALESCE(email, '') FROM users WHERE phone_number = ?", phone).Scan(&existingEmail); err == nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Nomor handphone ini sudah terdaftar dengan akun lain."})
		return
	}

	// Tentukan role target (default: rider)
	targetRole := "rider"
	if input.Role == "rental_partner" || input.Role == "food_merchant" {
		targetRole = input.Role
	}

	// Buat pengguna baru
	u = User{
		PhoneNumber:    phone,
		Name:           name,
		Email:          email,
		Role:           targetRole,
		CreatedAt:      time.Now().Format(time.RFC3339),
		Balance:        0, // lihat catatan saldo awal di registerHandler
		Badge:          "Silver",
		IsDriverActive: false,
	}
	dbSaveUser(u)
	dbSaveAddress(phone, "Rumah", "Jl. Merdeka No. 10, Pontianak")

	// Inisialisasi data pendukung spesifik role
	if targetRole == "rental_partner" {
		trialUntil := time.Now().AddDate(0, 0, 14).Format(time.RFC3339)
		_ = dbSavePartnerSubscription(PartnerSubscription{
			PhoneNumber: phone,
			Status:      "TRIAL",
			ValidUntil:  trialUntil,
			UpdatedAt:   time.Now().Format(time.RFC3339),
		})
	} else if targetRole == "food_merchant" {
		merchantID := newID("merchant")
		_, _ = db.Exec(`
			INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, image_url, is_open, created_at)
			VALUES (?, ?, ?, ?, ?, 1, ?)
		`, merchantID, phone, name+" Restaurant", "Jl. Merdeka No. 10, Pontianak", "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400", time.Now().Format(time.RFC3339))
	}

	token, err := issueToken(u.PhoneNumber, u.Role)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat token sesi"})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "token": token, "user": u})
}

// ==================== USER HANDLERS ====================

// Nama usaha untuk kop invoice. Yang dipakai adalah nilai yang disetel mitra
// sendiri; kalau belum pernah diisi, diambil dari pengajuan kemitraannya sebagai
// nilai awal. Bisa tetap kosong: akun yang dibuat di luar alur pendaftaran mitra
// (data awal, atau nomor login yang berbeda dengan nomor di pengajuan) memang
// tidak punya pengajuan yang cocok — itulah gunanya bisa diisi manual.
func businessNameOf(phone string) string {
	var name string
	_ = db.QueryRow("SELECT COALESCE(business_name, '') FROM users WHERE phone_number = ?", phone).Scan(&name)
	if strings.TrimSpace(name) != "" {
		return name
	}
	_ = db.QueryRow(`SELECT COALESCE(business_name, '') FROM partner_applications
		WHERE phone_number = ? AND status = 'approved'
		ORDER BY created_at DESC LIMIT 1`, phone).Scan(&name)
	return name
}

func profileHandler(w http.ResponseWriter, r *http.Request) {
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	u, exists := dbGetUser(phone)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
		return
	}

	// PUT: pemilik akun mengubah profilnya sendiri. Ganti password wajib menyertakan
	// password lama, supaya sesi yang dibajak tidak bisa mengunci pemilik akun.
	if r.Method == http.MethodPut {
		var input struct {
			Name            string  `json:"name"`
			Email           string  `json:"email"`
			BusinessName    *string `json:"business_name"`
			CurrentPassword string  `json:"current_password"`
			NewPassword     string  `json:"new_password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data tidak valid"})
			return
		}

		// Semua validasi dijalankan sebelum ada yang ditulis, supaya permintaan
		// yang setengah benar tidak menyimpan profil tapi gagal ganti password.
		if input.NewPassword != "" {
			if len(input.NewPassword) < 8 {
				writeJSONResponse(w, 400, map[string]string{"error": "Password baru minimal 8 karakter"})
				return
			}
			var hash string
			_ = db.QueryRow("SELECT COALESCE(password, '') FROM users WHERE phone_number = ?", phone).Scan(&hash)
			if !checkPassword(hash, input.CurrentPassword) {
				writeJSONResponse(w, 401, map[string]string{"error": "Password lama salah"})
				return
			}
		}
		if input.Email != "" && input.Email != u.Email {
			var other string
			if err := db.QueryRow("SELECT phone_number FROM users WHERE email = ? AND phone_number != ?", input.Email, phone).Scan(&other); err == nil {
				writeJSONResponse(w, 400, map[string]string{"error": "Email sudah dipakai akun lain"})
				return
			}
			u.Email = input.Email
		}
		if input.Name != "" {
			u.Name = input.Name
		}

		if err := dbSaveUser(u); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan profil"})
			return
		}
		// Pointer, bukan string: hanya ditulis kalau kliennya memang mengirim field
		// ini, supaya permintaan ganti password tidak ikut mengosongkan nama usaha.
		if input.BusinessName != nil {
			nama := strings.TrimSpace(*input.BusinessName)
			if len([]rune(nama)) > 100 {
				writeJSONResponse(w, 400, map[string]string{"error": "Nama usaha maksimal 100 karakter"})
				return
			}
			if _, err := db.Exec("UPDATE users SET business_name = ? WHERE phone_number = ?", nama, phone); err != nil {
				writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan nama usaha"})
				return
			}
		}
		if input.NewPassword != "" {
			if err := dbSetPassword(phone, input.NewPassword); err != nil {
				writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan password baru"})
				return
			}
		}
		u, _ = dbGetUser(phone)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Profil berhasil diperbarui", "user": u, "business_name": businessNameOf(phone)})
		return
	}

	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "user": u, "business_name": businessNameOf(phone)})
}

func topUpHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	var input TopUpInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.Amount <= 0 {
		writeJSONResponse(w, 400, map[string]string{"error": "Nominal top up tidak valid"})
		return
	}
	if _, exists := dbGetUser(phone); !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
		return
	}

	// Saldo tidak boleh bertambah tanpa pembayaran. Di luar mode dev, endpoint ini
	// menolak sampai integrasi payment gateway untuk dompet tersedia.
	// ponytail: sementara ditutup, bukan disambungkan ke Xendit — alur invoice dompet
	// belum ada di frontend. Sambungkan seperti subscriptionCreateHandler bila dibutuhkan.
	if isProduction() {
		writeJSONResponse(w, 501, map[string]string{"error": "Top up saldo belum tersedia. Fitur ini menunggu integrasi pembayaran."})
		return
	}

	if _, err := db.Exec("UPDATE users SET balance = balance + ? WHERE phone_number = ?", input.Amount, phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui saldo"})
		return
	}
	u, _ := dbGetUser(phone)
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Top up berhasil (mode dev)", "balance": u.Balance})
}

func addressesHandler(w http.ResponseWriter, r *http.Request) {
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	_, exists := dbGetUser(phone)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
		return
	}
	if r.Method == http.MethodGet {
		addrs, _ := dbGetAddresses(phone)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "addresses": addrs})
		return
	} else if r.Method == http.MethodPost {
		var input SaveAddressInput
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.Type == "" || input.Address == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "Payload tidak valid"})
			return
		}
		dbSaveAddress(phone, input.Type, input.Address)
		addrs, _ := dbGetAddresses(phone)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Alamat disimpan", "addresses": addrs})
		return
	}
	writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
}

// ==================== ORDER HANDLERS ====================

func createOrderHandler(w http.ResponseWriter, r *http.Request) {
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	u, exists := dbGetUser(phone)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
		return
	}
	if r.Method == http.MethodGet {
		result, _, _ := dbGetOrders("", phone, "", 0, 0)
		driverOrders, _, _ := dbGetOrders(phone, "", "", 0, 0)
		result = append(result, driverOrders...)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "orders": result})
		return
	}
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input CreateOrderInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.Pickup == "" || input.Dropoff == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Data pemesanan tidak valid"})
		return
	}
	// Ongkos dihitung dari koordinat, jadi koordinatnya wajib sungguhan.
	if !koordinatValid(input.PickupLat, input.PickupLng) || !koordinatValid(input.DropoffLat, input.DropoffLng) {
		writeJSONResponse(w, 400, map[string]string{"error": "Titik jemput dan tujuan harus dipilih dari peta"})
		return
	}
	// Angka fare kiriman aplikasi sengaja diabaikan: lihat tarif.go.
	t := ambilTarif(input.ServiceType)
	fare := hitungTarif(t, input.PickupLat, input.PickupLng, input.DropoffLat, input.DropoffLng)
	komisi := hitungKomisi(t, fare)

	// Metode apa pun selain "wallet" diperlakukan sebagai tunai, termasuk yang
	// kosong dari aplikasi versi lama. Tunai adalah default yang aman: tidak ada
	// saldo yang berpindah, jadi salah tebak tidak pernah mengurangi uang orang.
	metode := "cash"
	if input.PaymentMethod == "wallet" {
		metode = "wallet"
	}
	// Saldo hanya relevan untuk pembayaran dompet, dan diperiksa di muka supaya
	// driver tidak menempuh perjalanan yang ternyata tak terbayar di ujung.
	//
	// Yang dibandingkan adalah saldo dikurangi tarif pesanan dompet lain yang
	// belum selesai. Tanpa itu, saldo Rp20.000 lolos untuk tiga pesanan
	// Rp20.000 sekaligus, dan kegagalannya baru muncul saat driver sudah
	// mengantar — pesanannya lalu tersangkut karena Selesai ditolak 402.
	if metode == "wallet" {
		tertahan, err := dbSaldoTertahan(u.PhoneNumber)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal memeriksa saldo"})
			return
		}
		if u.Balance-tertahan < fare {
			pesan := "Saldo PayAntar tidak cukup. Pilih pembayaran tunai atau isi saldo dulu."
			if tertahan > 0 {
				pesan = fmt.Sprintf("Saldo PayAntar tidak cukup: Rp%.0f sudah dipakai pesanan lain yang belum selesai. Pilih pembayaran tunai atau isi saldo dulu.", tertahan)
			}
			writeJSONResponse(w, 402, map[string]string{"error": pesan})
			return
		}
	}
	oid := newID("order")
	now := time.Now().Format(time.RFC3339)
	o := Order{
		ID: oid, RiderPhone: u.PhoneNumber, RiderName: u.Name,
		PickupAddress: input.Pickup, DropoffAddress: input.Dropoff,
		PickupLat: input.PickupLat, PickupLng: input.PickupLng,
		DropoffLat: input.DropoffLat, DropoffLng: input.DropoffLng,
		Fare: fare, Komisi: komisi, PaymentMethod: metode, Service: input.ServiceType, Status: "pending",
		CreatedAt: now, UpdatedAt: now,
		PackageType: input.PackageType, PackageQuantity: input.PackageQuantity,
		PackageWeight: input.PackageWeight, PackageNotes: input.PackageNotes,
		Insurance: input.Insurance, SpecialHandling: input.SpecialHandling,
	}
	dbSaveOrder(o)
	// Inti dari notifikasi: tanpa ini driver harus menatap layar terbuka supaya
	// tidak kehilangan orderan.
	notifikasiDriverSiaga(o)
	writeJSONResponse(w, 201, map[string]interface{}{"status": "success", "message": "Pesanan berhasil dibuat", "order": o})
}

func getActiveOrdersHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	semua, _ := dbGetPendingOrders()
	lat, lng, _, adaLokasi := dbGetDriverLocation(callerPhone(r))

	hasil := make([]map[string]interface{}, 0, len(semua))
	for _, o := range semua {
		// Papan orderan disaring sejauh driver, bukan disiarkan ke seluruh
		// provinsi. Driver yang belum pernah mengirim posisinya tetap melihat
		// semuanya — menyembunyikan orderan dari driver yang siap kerja lebih
		// merugikan daripada memperlihatkan beberapa yang jauh.
		if adaLokasi && jarakKM(lat, lng, o.PickupLat, o.PickupLng) > radiusPapanOrderKM {
			continue
		}

		var m map[string]interface{}
		b, _ := json.Marshal(o)
		_ = json.Unmarshal(b, &m)
		// Nama, nomor, dan catatan penumpang belum jadi urusan siapa pun sebelum
		// pesanannya diterima. Alamat dan koordinat tetap dikirim: tanpa itu
		// driver tidak bisa menilai apakah orderannya masuk akal untuk diambil.
		delete(m, "rider_name")
		delete(m, "rider_phone")
		delete(m, "package_notes")
		hasil = append(hasil, m)
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "orders": hasil})
}

func orderRouterHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 3 {
		writeJSONResponse(w, 404, map[string]string{"error": "Not found"})
		return
	}
	action := parts[len(parts)-1]
	orderID := parts[2]
	switch action {
	case "accept":
		acceptOrder(w, r, orderID)
	case "pickup":
		pickupOrder(w, r, orderID)
	case "complete":
		completeOrder(w, r, orderID)
	case "status":
		getOrderStatus(w, r, orderID)
	case "cancel":
		cancelOrder(w, r, orderID)
	case "rate":
		rateOrder(w, r, orderID)
	default:
		writeJSONResponse(w, 404, map[string]string{"error": "Action not found"})
	}
}

// requireAssignedDriver memastikan pemanggil adalah driver yang ditugaskan pada
// pesanan ini. Menulis respons error sendiri bila gagal.
func requireAssignedDriver(w http.ResponseWriter, r *http.Request, orderID string) (Order, bool) {
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return Order{}, false
	}
	o, exists := dbGetOrder(orderID)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return Order{}, false
	}
	if o.DriverPhone != phone {
		writeJSONResponse(w, 403, map[string]string{"error": "Pesanan ini bukan tugas Anda"})
		return Order{}, false
	}
	return o, true
}

func acceptOrder(w http.ResponseWriter, r *http.Request, orderID string) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	dp, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	driver, ex := dbGetUser(dp)
	if !ex || driver.Role != "driver" {
		writeJSONResponse(w, 403, map[string]string{"error": "Hanya Driver yang bisa menerima orderan"})
		return
	}
	// Sebelumnya is_driver_active hanya disimpan, tidak pernah jadi syarat —
	// menonaktifkan driver bermasalah lewat dashboard tidak berefek apa pun.
	if !driver.IsDriverActive {
		writeJSONResponse(w, 403, map[string]string{"error": "Akun driver Anda sedang dinonaktifkan. Hubungi admin bohAntar."})
		return
	}
	o, oe := dbGetOrder(orderID)
	if !oe {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}
	now := time.Now().Format(time.RFC3339)
	menang, err := dbClaimOrder(orderID, driver.PhoneNumber, driver.Name, now)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan pesanan"})
		return
	}
	if !menang {
		writeJSONResponse(w, 409, map[string]string{"error": "Pesanan sudah diambil oleh driver lain"})
		return
	}
	o.Status = "accepted"
	o.DriverPhone = driver.PhoneNumber
	o.DriverName = driver.Name
	o.UpdatedAt = now
	notifikasiKe(o.RiderPhone, "Driver ditemukan", driver.Name+" sedang menuju titik jemput Anda.", map[string]string{
		"tipe":     "pesanan_diterima",
		"order_id": o.ID,
	})
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Pesanan berhasil diterima", "order": o})
}

// rateOrder menyimpan penilaian penumpang untuk driver pada satu pesanan.
//
// Sebelumnya layar penilaian di aplikasi hanya menutup dirinya sendiri: bintang
// dan ulasannya tidak dikirim ke mana pun, dan rating semua driver tetap 5,0
// selamanya. Tombol yang berpura-pura bekerja lebih buruk daripada tidak ada.
func rateOrder(w http.ResponseWriter, r *http.Request, orderID string) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	var input struct {
		Stars  int    `json:"stars"`
		Review string `json:"review"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil || input.Stars < 1 || input.Stars > 5 {
		writeJSONResponse(w, 400, map[string]string{"error": "Bintang harus antara 1 sampai 5"})
		return
	}

	o, exists := dbGetOrder(orderID)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}
	if o.RiderPhone != phone {
		denyOwnership(w)
		return
	}
	if o.Status != "completed" {
		writeJSONResponse(w, 400, map[string]string{"error": "Penilaian hanya bisa diberikan setelah perjalanan selesai"})
		return
	}
	if o.DriverPhone == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Pesanan ini tidak punya driver untuk dinilai"})
		return
	}

	// Kunci utamanya order_id, jadi menilai dua kali memperbarui nilai yang sama
	// alih-alih menumpuk suara — satu perjalanan tetap satu suara.
	if _, err := db.Exec(`
		INSERT INTO order_ratings (order_id, driver_phone, rider_phone, stars, review, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE stars = VALUES(stars), review = VALUES(review), created_at = VALUES(created_at)`,
		o.ID, o.DriverPhone, o.RiderPhone, input.Stars, strings.TrimSpace(input.Review), time.Now().Format(time.RFC3339)); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan penilaian"})
		return
	}

	// Rata-ratanya dihitung ulang dari seluruh penilaian, bukan digeser sedikit
	// demi sedikit: penilaian yang diperbaiki penumpang ikut terhitung benar,
	// dan tidak ada galat pembulatan yang menumpuk.
	rata := 5.0
	if err := db.QueryRow("SELECT AVG(stars) FROM order_ratings WHERE driver_phone = ?", o.DriverPhone).Scan(&rata); err == nil {
		_, _ = db.Exec("UPDATE users SET rating = ? WHERE phone_number = ?", rata, o.DriverPhone)
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Terima kasih atas penilaiannya", "rating_driver": rata})
}

// cancelOrder membatalkan pesanan atas permintaan penumpangnya sendiri.
//
// Batasnya di "picked_up": setelah penumpang naik, membatalkan berarti driver
// sudah bekerja tanpa dibayar. Sesudah titik itu yang berlaku adalah tombol
// Selesai, bukan pembatalan.
//
// Admin boleh membatalkan kapan pun sebelum selesai — itu satu-satunya cara
// menutup pesanan yang tersangkut karena HP driver mati.
func cancelOrder(w http.ResponseWriter, r *http.Request, orderID string) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	o, exists := dbGetOrder(orderID)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}

	admin := isAdmin(r)
	if o.RiderPhone != phone && !admin {
		denyOwnership(w)
		return
	}

	// Penumpang berhenti di picked_up; admin boleh sampai sebelum selesai.
	boleh := []string{"pending", "accepted"}
	if admin {
		boleh = append(boleh, "picked_up")
	}
	// Syaratnya dititipkan ke MySQL supaya pembatalan tidak menang atas driver
	// yang menekan Terima di saat yang sama, atau sebaliknya.
	batal, err := dbCancelOrder(orderID, boleh, time.Now().Format(time.RFC3339))
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membatalkan pesanan"})
		return
	}
	if !batal {
		writeJSONResponse(w, 409, map[string]string{"error": "Pesanan sudah tidak bisa dibatalkan karena statusnya " + o.Status})
		return
	}

	// Driver yang sudah berangkat harus tahu, kalau tidak ia menunggu di titik
	// jemput untuk penumpang yang tidak akan datang.
	if o.DriverPhone != "" {
		notifikasiKe(o.DriverPhone, "Pesanan dibatalkan", "Penumpang membatalkan perjalanan ini.", map[string]string{
			"tipe":     "dibatalkan",
			"order_id": o.ID,
		})
	}
	o.Status = "cancelled"
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Pesanan dibatalkan", "order": o})
}

// kedaluwarsakanPesanan menandai pesanan yang tidak pernah diambil siapa pun.
//
// Tanpa ini daftar pending tumbuh selamanya: setiap driver mengunduh seluruh
// isinya tiap tiga detik, dan pesanan basi terus ditawarkan berbulan-bulan
// setelah penumpangnya menyerah dan pulang.
func kedaluwarsakanPesanan() {
	for range time.Tick(time.Minute) {
		batas := time.Now().Add(-batasPesananMenunggu).Format(time.RFC3339)
		res, err := db.Exec(
			"UPDATE orders SET status = 'expired', updated_at = ? WHERE status = 'pending' AND created_at < ?",
			time.Now().Format(time.RFC3339), batas)
		if err != nil {
			log.Printf("Gagal menandai pesanan kedaluwarsa: %v", err)
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			log.Printf("%d pesanan kedaluwarsa karena tidak diambil dalam %s", n, batasPesananMenunggu)
		}
	}
}

func pickupOrder(w http.ResponseWriter, r *http.Request, orderID string) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	o, ok := requireAssignedDriver(w, r, orderID)
	if !ok {
		return
	}
	if o.Status != "accepted" {
		writeJSONResponse(w, 400, map[string]string{"error": "Pesanan tidak dapat diambil karena statusnya " + o.Status})
		return
	}
	o.Status = "picked_up"
	o.UpdatedAt = time.Now().Format(time.RFC3339)
	dbSaveOrder(o)
	notifikasiKe(o.RiderPhone, "Perjalanan dimulai", "Driver sudah menjemput. Selamat jalan!", map[string]string{
		"tipe":     "dijemput",
		"order_id": o.ID,
	})
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Barang/penumpang berhasil diambil", "order": o})
}

func completeOrder(w http.ResponseWriter, r *http.Request, orderID string) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	o, ok := requireAssignedDriver(w, r, orderID)
	if !ok {
		return
	}
	if o.Status != "accepted" && o.Status != "picked_up" {
		writeJSONResponse(w, 400, map[string]string{"error": "Pesanan tidak dapat diselesaikan karena statusnya " + o.Status})
		return
	}
	// Perpindahan saldo dan perubahan status dilakukan dalam satu transaksi supaya
	// jumlah yang didebit rider selalu sama dengan yang dikredit ke driver.
	tx, err := db.Begin()
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memulai transaksi"})
		return
	}
	defer tx.Rollback()

	// Pembayaran dompet: uangnya berpindah di dalam sistem, jadi saldo penumpang
	// harus dikunci dan diperiksa dulu. Pembayaran tunai tidak menyentuh saldo
	// penumpang sama sekali — uangnya sudah berpindah tangan di jalan.
	if o.PaymentMethod == "wallet" {
		var riderBalance float64
		if err := tx.QueryRow("SELECT balance FROM users WHERE phone_number = ? FOR UPDATE", o.RiderPhone).Scan(&riderBalance); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca saldo penumpang"})
			return
		}
		if riderBalance < o.Fare {
			writeJSONResponse(w, 402, map[string]string{"error": "Saldo penumpang tidak mencukupi untuk menyelesaikan pesanan"})
			return
		}
	}

	o.Status = "completed"
	o.UpdatedAt = time.Now().Format(time.RFC3339)
	if _, err := tx.Exec("UPDATE orders SET status = ?, updated_at = ? WHERE id = ?", o.Status, o.UpdatedAt, o.ID); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui pesanan"})
		return
	}

	// Selisih kedua angka ini tidak dikreditkan ke mana pun; itulah pendapatan
	// bohAntar, dan jumlahnya bisa dijumlahkan dari kolom komisi kapan saja.
	debitPenumpang, kreditDriver := bagiPembayaran(o.PaymentMethod, o.Fare, o.Komisi)

	if _, err := tx.Exec("UPDATE users SET balance = balance - ?, total_orders = total_orders + 1 WHERE phone_number = ?", debitPenumpang, o.RiderPhone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal mendebit saldo penumpang"})
		return
	}
	// ponytail: saldo driver boleh minus di jalur tunai — komisi menumpuk jadi
	// utang sampai ia menyetor. Menolak penyelesaian saat saldo kurang justru
	// menelantarkan penumpang di tengah jalan. Pasang syarat deposit minimum
	// saat utangnya mulai jadi masalah nyata.
	if _, err := tx.Exec("UPDATE users SET balance = balance + ?, total_orders = total_orders + 1 WHERE phone_number = ?", kreditDriver, o.DriverPhone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memperbarui saldo driver"})
		return
	}
	if err := tx.Commit(); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan transaksi"})
		return
	}
	pesanBayar := "Terima kasih sudah memakai bohAntar."
	if o.PaymentMethod != "wallet" {
		pesanBayar = fmt.Sprintf("Bayar tunai Rp%.0f ke driver.", o.Fare)
	}
	notifikasiKe(o.RiderPhone, "Perjalanan selesai", pesanBayar, map[string]string{
		"tipe":     "selesai",
		"order_id": o.ID,
	})
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Pesanan berhasil diselesaikan", "order": o})
}

func getOrderStatus(w http.ResponseWriter, r *http.Request, orderID string) {
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	o, oe := dbGetOrder(orderID)
	if !oe {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}
	// Hanya penumpang dan driver pada pesanan ini yang boleh memantau statusnya.
	if o.RiderPhone != phone && o.DriverPhone != phone {
		denyOwnership(w)
		return
	}
	resp := map[string]interface{}{"status": "success", "order": o}
	// Posisi driver hanya ikut selama perjalanan berlangsung. Setelah pesanan
	// selesai atau batal, penumpang tidak punya alasan lagi mengetahui driver
	// itu sedang di mana.
	if o.DriverPhone != "" && (o.Status == "accepted" || o.Status == "picked_up") {
		if lat, lng, at, ok := dbGetDriverLocation(o.DriverPhone); ok {
			resp["driver_location"] = map[string]interface{}{"lat": lat, "lng": lng, "updated_at": at}
		}
	}
	writeJSONResponse(w, 200, resp)
}

// ==================== ADMIN HANDLERS ====================

func adminUsersHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	roleFilter := r.URL.Query().Get("role")
	pageStr := r.URL.Query().Get("page")
	limitStr := r.URL.Query().Get("limit")

	page := 1
	limit := 10

	if pageStr != "" {
		if p, err := strconv.Atoi(pageStr); err == nil && p > 0 {
			page = p
		}
	}
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	result, total, err := dbGetUsers(roleFilter, page, limit)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
		return
	}

	totalPages := (total + limit - 1) / limit
	if totalPages == 0 {
		totalPages = 1
	}

	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"total":  total,
		"users":  result,
		"pagination": map[string]interface{}{
			"page":        page,
			"limit":       limit,
			"total":       total,
			"total_pages": totalPages,
		},
	})
}

var validRoles = map[string]bool{
	"rider": true, "driver": true, "admin": true,
	"food_merchant": true, "rental_partner": true,
}

func adminUserDetailHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSONResponse(w, 400, map[string]string{"error": "Phone required"})
		return
	}
	phone := "+" + parts[3]

	if r.Method == http.MethodGet {
		u, ex := dbGetUser(phone)
		if !ex {
			writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
			return
		}
		result, _, _ := dbGetOrders("", phone, "", 0, 0)
		driverOrders, _, _ := dbGetOrders(phone, "", "", 0, 0)
		result = append(result, driverOrders...)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "user": u, "orders": result})
		return
	} else if r.Method == http.MethodDelete {
		_, ex := dbGetUser(phone)
		if !ex {
			writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
			return
		}
		err := dbDeleteUser(phone)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menghapus dari database: " + err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "User berhasil dihapus"})
		return
	} else if r.Method == http.MethodPut {
		u, ex := dbGetUser(phone)
		if !ex {
			writeJSONResponse(w, 404, map[string]string{"error": "User tidak ditemukan"})
			return
		}
		// Pointer supaya field yang tidak dikirim tidak menimpa data lama jadi kosong.
		var input struct {
			Name     *string  `json:"name"`
			Email    *string  `json:"email"`
			Role     *string  `json:"role"`
			Balance  *float64 `json:"balance"`
			Rating   *float64 `json:"rating"`
			Password *string  `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Request body tidak valid"})
			return
		}
		if input.Name != nil {
			u.Name = *input.Name
		}
		if input.Email != nil {
			u.Email = *input.Email
		}
		if input.Role != nil {
			if !validRoles[*input.Role] {
				writeJSONResponse(w, 400, map[string]string{"error": "Role tidak dikenal"})
				return
			}
			u.Role = *input.Role
		}
		if input.Balance != nil {
			u.Balance = *input.Balance
		}
		if input.Rating != nil {
			u.Rating = *input.Rating
		}

		if err := dbSaveUser(u); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		// Password hanya diganti bila field-nya benar-benar dikirim dan tidak kosong.
		if input.Password != nil && *input.Password != "" {
			if err := dbSetPassword(phone, *input.Password); err != nil {
				writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan password baru"})
				return
			}
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "User berhasil diperbarui", "user": u})
		return
	}
	writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
}

func adminOrdersHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	df := r.URL.Query().Get("driver")
	rf := r.URL.Query().Get("rider")
	sf := r.URL.Query().Get("status")
	pageStr := r.URL.Query().Get("page")
	limitStr := r.URL.Query().Get("limit")

	page := 1
	limit := 10

	if pageStr != "" {
		if p, err := strconv.Atoi(pageStr); err == nil && p > 0 {
			page = p
		}
	}
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	result, total, err := dbGetOrders(df, rf, sf, page, limit)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
		return
	}

	totalPages := (total + limit - 1) / limit
	if totalPages == 0 {
		totalPages = 1
	}

	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"total":  total,
		"orders": result,
		"pagination": map[string]interface{}{
			"page":        page,
			"limit":       limit,
			"total":       total,
			"total_pages": totalPages,
		},
	})
}

func adminAnalyticsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	data, err := dbGetAnalyticsData()
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "analytics": data})
}

// ==================== HAPUS AKUN ====================

// hapusAkunSendiri menghapus akun pemanggil beserta datanya.
//
// Google Play mewajibkan aplikasi yang punya pendaftaran menyediakan cara
// menghapus akun dari dalam aplikasi, bukan hanya lewat menghubungi admin.
//
// Pesanan tidak ikut dihapus, hanya dianonimkan: nominal, komisi, dan tanggalnya
// tetap dibutuhkan untuk pembukuan, sedangkan nama dan nomor pemiliknya tidak.
// Menghapus barisnya akan membuat laporan pendapatan bulan-bulan lalu berubah
// sendiri setiap ada pengguna yang pergi.
func hapusAkunSendiri(w http.ResponseWriter, r *http.Request) {
	phone := callerPhone(r)
	u, exists := dbGetUser(phone)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "Akun tidak ditemukan"})
		return
	}

	// Pesanan yang sedang berjalan menyangkut orang lain yang sedang menunggu.
	var berjalan int
	_ = db.QueryRow(
		"SELECT COUNT(*) FROM orders WHERE (rider_phone = ? OR driver_phone = ?) AND status IN ('pending','accepted','picked_up')",
		phone, phone,
	).Scan(&berjalan)
	if berjalan > 0 {
		writeJSONResponse(w, 409, map[string]string{"error": "Masih ada pesanan berjalan. Selesaikan dulu sebelum menghapus akun."})
		return
	}

	// Saldo minus berarti komisi tunai yang belum disetor. Menghapus akun tidak
	// boleh jadi cara membatalkan utang.
	if u.Balance < 0 {
		writeJSONResponse(w, 409, map[string]string{"error": "Masih ada komisi yang belum disetor. Lunasi dulu sebelum menghapus akun."})
		return
	}

	tx, err := db.Begin()
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal memulai penghapusan"})
		return
	}
	defer tx.Rollback()

	if _, err := tx.Exec("UPDATE orders SET rider_name = 'Pengguna dihapus', rider_phone = '' WHERE rider_phone = ?", phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menganonimkan pesanan"})
		return
	}
	if _, err := tx.Exec("UPDATE orders SET driver_name = 'Pengguna dihapus', driver_phone = '' WHERE driver_phone = ?", phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menganonimkan pesanan"})
		return
	}
	if _, err := tx.Exec("DELETE FROM chat_messages WHERE sender_phone = ?", phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menghapus percakapan"})
		return
	}
	if _, err := tx.Exec("DELETE FROM user_addresses WHERE phone_number = ?", phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menghapus alamat"})
		return
	}
	// Baris users dihapus terakhir: tabel langganan mitra menunjuk ke sini dengan
	// ON DELETE CASCADE, jadi ikut terhapus sendiri.
	if _, err := tx.Exec("DELETE FROM users WHERE phone_number = ?", phone); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menghapus akun"})
		return
	}
	if err := tx.Commit(); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan penghapusan"})
		return
	}
	log.Printf("Akun dihapus atas permintaan pemiliknya: %s (%s)", phone, u.Role)
	writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Akun Anda telah dihapus."})
}

// ==================== POSISI DRIVER ====================

// dbSetDriverLocation menyimpan posisi terakhir seorang driver.
func dbSetDriverLocation(phone string, lat, lng float64) error {
	_, err := db.Exec(
		"UPDATE users SET driver_lat = ?, driver_lng = ?, driver_loc_at = ? WHERE phone_number = ? AND role = 'driver'",
		lat, lng, time.Now().Format(time.RFC3339), phone,
	)
	return err
}

// dbGetDriverLocation mengembalikan posisi terakhir driver beserta waktunya.
// ok bernilai false kalau driver itu belum pernah mengirim posisi.
func dbGetDriverLocation(phone string) (lat, lng float64, at string, ok bool) {
	err := db.QueryRow(
		"SELECT COALESCE(driver_lat, 0), COALESCE(driver_lng, 0), COALESCE(driver_loc_at, '') FROM users WHERE phone_number = ?",
		phone,
	).Scan(&lat, &lng, &at)
	if err != nil || at == "" || !koordinatValid(lat, lng) {
		return 0, 0, "", false
	}
	return lat, lng, at, true
}

// driverLocationHandler menerima posisi driver dari aplikasi.
//
// Hanya driver yang boleh mengirim, dan hanya untuk dirinya sendiri: nomornya
// diambil dari token, tidak pernah dari badan permintaan. Kalau tidak, driver
// mana pun bisa memalsukan posisi driver lain.
// driverOfflineHandler menyatakan driver berhenti bekerja, seketika.
//
// Siapa yang siaga ditebak dari driver_loc_at dalam sepuluh menit terakhir, jadi
// tombol offline di aplikasi dulu tidak berarti apa-apa: driver yang sudah
// pulang tetap dibangunkan orderan sampai sepuluh menit sesudahnya. Mengosongkan
// penanda waktunya membuat tebakan itu langsung berhenti — tanpa kolom baru.
//
// Konsekuensinya penanda driver hilang dari peta penumpang, bukan membeku di
// posisi lama. Itu memang lebih jujur: driver yang offline berhenti melaporkan
// posisi, jadi titik terakhirnya cuma menyesatkan.
func driverOfflineHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	if _, err := db.Exec("UPDATE users SET driver_loc_at = '' WHERE phone_number = ?", callerPhone(r)); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan status"})
		return
	}
	writeJSONResponse(w, 200, map[string]string{"status": "success"})
}

func driverLocationHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input struct {
		Lat float64 `json:"lat"`
		Lng float64 `json:"lng"`
	}
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Posisi tidak valid"})
		return
	}
	if !koordinatValid(input.Lat, input.Lng) {
		writeJSONResponse(w, 400, map[string]string{"error": "Koordinat di luar jangkauan"})
		return
	}
	if err := dbSetDriverLocation(callerPhone(r), input.Lat, input.Lng); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan posisi"})
		return
	}
	writeJSONResponse(w, 200, map[string]string{"status": "success"})
}

// adminTarifHandler: GET membaca seluruh tarif, PUT menyimpan satu layanan.
func adminTarifHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		daftar, err := ambilSemuaTarif()
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca tarif"})
			return
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "tarif": daftar})
	case http.MethodPut:
		var input tarifLayanan
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Data tarif tidak valid"})
			return
		}
		if pesan, ok := tarifMasukAkal(input); !ok {
			writeJSONResponse(w, 400, map[string]string{"error": pesan})
			return
		}
		if err := simpanTarif(input); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyimpan tarif"})
			return
		}
		// Perubahan hanya berlaku untuk pesanan berikutnya: yang sudah dibuat
		// memakai komisi yang terkunci di barisnya masing-masing.
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "tarif": ambilTarif(input.Layanan)})
	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// isUploadedFileURL memastikan URL dokumen benar-benar hasil /api/upload dan bukan
// alamat luar atau path traversal: klien mengirim string ini apa adanya, lalu
// panel admin menampilkannya sebagai gambar/tautan.
func isUploadedFileURL(u string) bool {
	name, ok := strings.CutPrefix(u, "/uploads/")
	if !ok || name == "" || name != filepath.Base(name) {
		return false
	}
	ext := strings.ToLower(filepath.Ext(name))
	_, known := uploadTypeByExt[ext]
	return known || ext == ".heic" || ext == ".heif"
}

func adminDriverRegisterHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var app DriverApplication
	if err := json.NewDecoder(r.Body).Decode(&app); err != nil || app.PhoneNumber == "" || app.Name == "" || app.KTPNumber == "" || app.SIMNumber == "" || app.VehiclePlate == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Data pendaftaran tidak lengkap"})
		return
	}
	for _, doc := range []string{app.KTPPhotoURL, app.SIMPhotoURL, app.STNKPhotoURL} {
		if !isUploadedFileURL(doc) {
			writeJSONResponse(w, 400, map[string]string{"error": "Scan KTP, SIM, dan STNK wajib diunggah"})
			return
		}
	}
	// Disamakan bentuknya seperti jalur pendaftaran lain. Tanpa ini, pengaju yang
	// mengetik 08xx dapat akun kedua yang terpisah dari akun +628xx miliknya
	// sendiri — token, pesanan, dan lokasinya berpisah di dua baris.
	app.PhoneNumber = normalizePhone(app.PhoneNumber)
	app.Email = strings.ToLower(strings.TrimSpace(app.Email))
	app.ID = newID("app")
	app.Status = "pending"
	app.CreatedAt = time.Now().Format(time.RFC3339)
	dbSaveApplication(app)
	writeJSONResponse(w, 201, map[string]interface{}{"status": "success", "message": "Pendaftaran driver berhasil dikirim", "application": app})
}

func adminDriverApplicationsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	sf := r.URL.Query().Get("status")
	result, _ := dbGetApplications(sf)

	// Menyetujui pengaju yang nomornya sudah punya akun akan MENIMPA peran
	// lamanya — penumpang yang jadi driver berhenti bisa memesan. Admin harus
	// tahu itu sebelum menekan setujui, bukan sesudahnya, jadi peran yang ada
	// sekarang ikut dikirim.
	//
	// ponytail: satu query per pengajuan. Daftarnya puluhan baris, bukan ribuan,
	// jadi JOIN-nya belum sepadan dengan kerumitannya.
	daftar := make([]map[string]interface{}, 0, len(result))
	for _, app := range result {
		var baris map[string]interface{}
		b, _ := json.Marshal(app)
		_ = json.Unmarshal(b, &baris)

		var peran string
		if err := db.QueryRow("SELECT role FROM users WHERE phone_number = ?", app.PhoneNumber).Scan(&peran); err == nil {
			baris["existing_role"] = peran
		}
		daftar = append(daftar, baris)
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "total": len(daftar), "applications": daftar})
}

func adminDriverApproveHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 5 {
		writeJSONResponse(w, 400, map[string]string{"error": "Invalid path"})
		return
	}
	appID := parts[3]
	action := parts[4]

	app, ex := dbGetApplication(appID)
	if !ex {
		writeJSONResponse(w, 404, map[string]string{"error": "Aplikasi tidak ditemukan"})
		return
	}
	if action == "approve" {
		// Email adalah identitas login. Kalau sudah dipakai nomor lain, akun yang
		// dibuat di bawah akan menabrak indeks unik — dan pada database yang
		// indeksnya belum sempat terpasang, salah satu dari kedua akun itu
		// diam-diam jadi tidak bisa masuk sama sekali.
		if app.Email != "" {
			var pemilik string
			if err := db.QueryRow("SELECT phone_number FROM users WHERE email = ?", app.Email).Scan(&pemilik); err == nil && pemilik != app.PhoneNumber {
				writeJSONResponse(w, 409, map[string]string{"error": "Email " + app.Email + " sudah dipakai akun " + pemilik + ". Perbaiki email pengajuannya lebih dulu."})
				return
			}
		}
		app.Status = "approved"
		dbSaveApplication(app)

		// Password awal hanya dibuat untuk akun yang benar-benar baru. Penumpang
		// yang naik jadi driver sudah punya password sendiri, dan menimpanya
		// berarti mengunci dia keluar dari akunnya sendiri.
		initialPass := ""
		if eu, ok := dbGetUser(app.PhoneNumber); ok {
			eu.Role = "driver"
			eu.IsDriverActive = true
			dbSaveUser(eu)
		} else {
			dbSaveUser(User{PhoneNumber: app.PhoneNumber, Name: app.Name, Email: app.Email, Role: "driver", CreatedAt: time.Now().Format(time.RFC3339), Balance: 0, Badge: "Silver", IsDriverActive: true})
			// Tanpa ini driver yang sudah disetujui tidak bisa masuk sama sekali:
			// login memeriksa password terhadap hash kosong, dan itu selalu gagal.
			// Google Sign-In pun hanya menolong kalau email di formulir kebetulan
			// sama persis dengan akun Google-nya.
			initialPass = randomPassword()
			if err := dbSetPassword(app.PhoneNumber, initialPass); err != nil {
				writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan password driver"})
				return
			}
		}
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Driver berhasil diapprove", "application": app, "initial_password": initialPass})
	} else if action == "reject" {
		app.Status = "rejected"
		dbSaveApplication(app)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Driver ditolak", "application": app})
	} else {
		writeJSONResponse(w, 400, map[string]string{"error": "Action harus approve atau reject"})
	}
}

func partnerRegisterHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var app PartnerApplication
	if err := json.NewDecoder(r.Body).Decode(&app); err != nil || app.Type == "" || app.PhoneNumber == "" || app.Name == "" || app.KTPNumber == "" || app.BusinessName == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Data pendaftaran tidak lengkap"})
		return
	}

	// 1. Check for duplicate email in users table
	var existingRole string
	err := db.QueryRow("SELECT role FROM users WHERE email = ?", app.Email).Scan(&existingRole)
	if err == nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Email sudah terdaftar di sistem dengan role: " + existingRole})
		return
	}

	// 2. Check for duplicate email in active partner applications
	var existingAppType, existingAppStatus string
	err = db.QueryRow("SELECT type, status FROM partner_applications WHERE email = ? AND status != 'rejected'", app.Email).Scan(&existingAppType, &existingAppStatus)
	if err == nil {
		writeJSONResponse(w, 400, map[string]string{"error": fmt.Sprintf("Email sudah terdaftar pada pengajuan kemitraan (%s) dengan status: %s", existingAppType, existingAppStatus)})
		return
	}

	// 3. Check for duplicate phone number in users table
	var phoneRole string
	err = db.QueryRow("SELECT role FROM users WHERE phone_number = ?", app.PhoneNumber).Scan(&phoneRole)
	if err == nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Nomor HP sudah terdaftar di sistem dengan role: " + phoneRole})
		return
	}

	app.ID = fmt.Sprintf("partner-app-%d", rand.Intn(1000000))
	app.Status = "pending"
	app.CreatedAt = time.Now().Format(time.RFC3339)
	dbSavePartnerApplication(app)
	writeJSONResponse(w, 201, map[string]interface{}{"status": "success", "message": "Pendaftaran kemitraan berhasil dikirim", "application": app})
}

func adminPartnerApplicationsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	tf := r.URL.Query().Get("type")
	sf := r.URL.Query().Get("status")
	result, err := dbGetPartnerApplications(tf, sf)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "total": len(result), "applications": result})
}

func adminPartnerApplicationActionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 5 {
		writeJSONResponse(w, 400, map[string]string{"error": "Invalid path"})
		return
	}
	appID := parts[3]
	action := parts[4]

	app, ex := dbGetPartnerApplication(appID)
	if !ex {
		writeJSONResponse(w, 404, map[string]string{"error": "Aplikasi tidak ditemukan"})
		return
	}

	if action == "approve" {
		app.Status = "approved"
		dbSavePartnerApplication(app)

		targetRole := "rental_partner"
		if app.Type == "food" {
			targetRole = "food_merchant"
		}

		// Password awal dibuat acak dan hanya dikembalikan sekali di response ini,
		// supaya admin bisa menyampaikannya ke mitra.
		initialPass := ""
		if eu, ok := dbGetUser(app.PhoneNumber); ok {
			eu.Role = targetRole
			dbSaveUser(eu)
		} else {
			dbSaveUser(User{
				PhoneNumber: app.PhoneNumber,
				Name:        app.Name,
				Email:       app.Email,
				Role:        targetRole,
				CreatedAt:   time.Now().Format(time.RFC3339),
				Balance:     0,
				Badge:       "Silver",
			})
			initialPass = randomPassword()
			if err := dbSetPassword(app.PhoneNumber, initialPass); err != nil {
				writeJSONResponse(w, 500, map[string]string{"error": "Gagal menyiapkan password mitra"})
				return
			}
		}

		// Additional mapping: if it's a food merchant, automatically create an entry in food_merchants table
		if app.Type == "food" {
			var existID string
			err := db.QueryRow("SELECT id FROM food_merchants WHERE owner_phone = ?", app.PhoneNumber).Scan(&existID)
			if err != nil { // Not exists
				merchantID := newID("merchant")
				_, _ = db.Exec(`
					INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, image_url, is_open, created_at)
					VALUES (?, ?, ?, ?, ?, 1, ?)
				`, merchantID, app.PhoneNumber, app.BusinessName, app.Address, "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400", time.Now().Format(time.RFC3339))
			}
		}

		// Jika tipe rental, otomatis daftarkan ke tabel partner_subscriptions dengan status TRIAL selama 14 hari
		if app.Type == "rental" {
			trialUntil := time.Now().AddDate(0, 0, 14).Format(time.RFC3339)
			_ = dbSavePartnerSubscription(PartnerSubscription{
				PhoneNumber: app.PhoneNumber,
				Status:      "TRIAL",
				ValidUntil:  trialUntil,
				UpdatedAt:   time.Now().Format(time.RFC3339),
			})
		}

		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Mitra berhasil disetujui", "application": app, "initial_password": initialPass})
	} else if action == "reject" {
		app.Status = "rejected"
		dbSavePartnerApplication(app)
		writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "message": "Mitra ditolak", "application": app})
	} else {
		writeJSONResponse(w, 400, map[string]string{"error": "Action harus approve atau reject"})
	}
}

// ==================== CHAT ====================

func chatHistoryHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 3 {
		writeJSONResponse(w, 400, map[string]string{"error": "Order ID required"})
		return
	}
	orderID := parts[2]
	phone, ok := extractPhone(r)
	if !ok {
		writeJSONResponse(w, 401, map[string]string{"error": "Token otorisasi diperlukan"})
		return
	}
	o, exists := dbGetOrder(orderID)
	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "Pesanan tidak ditemukan"})
		return
	}
	if o.RiderPhone != phone && o.DriverPhone != phone {
		denyOwnership(w)
		return
	}
	msgs, _ := dbGetChatMessages(orderID)
	writeJSONResponse(w, 200, map[string]interface{}{"status": "success", "order_id": orderID, "messages": msgs})
}

func chatWebSocketHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 3 {
		http.Error(w, "Order ID required", 400)
		return
	}
	orderID := parts[2]

	// Identitas diambil dari token, bukan query string. Token boleh lewat header
	// atau parameter "token" karena WebSocket browser tidak bisa mengirim header.
	if tok := r.URL.Query().Get("token"); tok != "" && r.Header.Get("Authorization") == "" {
		r.Header.Set("Authorization", "Bearer "+tok)
	}
	sPhone, sRole, ok := parseBearer(r)
	if !ok {
		http.Error(w, "Token otorisasi diperlukan", http.StatusUnauthorized)
		return
	}
	o, exists := dbGetOrder(orderID)
	if !exists {
		http.Error(w, "Pesanan tidak ditemukan", http.StatusNotFound)
		return
	}
	if o.RiderPhone != sPhone && o.DriverPhone != sPhone && sRole != "admin" {
		http.Error(w, "Anda bukan peserta pesanan ini", http.StatusForbidden)
		return
	}
	sName := ""
	if u, found := dbGetUser(sPhone); found {
		sName = u.Name
	}

	conn, err := wsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WS upgrade error: %v", err)
		return
	}
	client := &wsClient{conn: conn, phone: sPhone}
	defer func() {
		conn.Close()
		removeWSConn(orderID, client)
	}()
	wsMutex.Lock()
	wsConnections[orderID] = append(wsConnections[orderID], client)
	wsMutex.Unlock()

	history, _ := dbGetChatMessages(orderID)
	if history != nil {
		hj, _ := json.Marshal(map[string]interface{}{"type": "history", "messages": history})
		_ = client.send(hj)
	}
	for {
		_, mb, err := conn.ReadMessage()
		if err != nil {
			break
		}
		var inc map[string]string
		if err := json.Unmarshal(mb, &inc); err != nil || inc["content"] == "" {
			continue
		}
		msg := ChatMessage{ID: newID("msg"), OrderID: orderID, SenderPhone: sPhone, SenderName: sName, SenderRole: sRole, Content: inc["content"], Timestamp: time.Now().Format(time.RFC3339)}
		dbSaveChatMessage(msg)
		mj, _ := json.Marshal(map[string]interface{}{"type": "message", "message": msg})
		broadcastToRoom(orderID, mj)
		notifikasiChat(orderID, sPhone, sName, msg.Content)
	}
}

// notifikasiChat memberi tahu peserta lain bahwa ada pesan masuk.
//
// broadcastToRoom hanya sampai ke koneksi yang sedang terbuka, jadi tanpa ini
// pesan yang dikirim saat lawan bicara menutup layar chat hilang begitu saja
// sampai ia membukanya sendiri — dan driver menunggu di depan gerbang.
//
// Pesanannya dibaca ulang, bukan memakai salinan dari awal koneksi: penumpang
// bisa membuka chat sebelum ada driver, dan salinan lama masih kosong nomornya.
func notifikasiChat(orderID, pengirimPhone, pengirimNama, isi string) {
	o, ada := dbGetOrder(orderID)
	if !ada {
		return
	}
	terbuka := teleponDiRuang(orderID)
	judul := pengirimNama
	if judul == "" {
		judul = "Pesan baru"
	}
	for _, tujuan := range penerimaChat(o, pengirimPhone, terbuka) {
		notifikasiKe(tujuan, judul, isi, map[string]string{
			"tipe":     "chat",
			"order_id": orderID,
		})
	}
}

// penerimaChat memilih siapa yang perlu diberi tahu: peserta pesanan yang bukan
// pengirim dan tidak sedang membuka layar chatnya.
//
// Dipisah dari notifikasiChat supaya bisa diuji tanpa basis data — aturannya
// pendek tapi salah satunya diam-diam merugikan: keliru sedikit saja, notifikasi
// balik ke pengirimnya sendiri atau berdengung di tangan orang yang sedang
// membaca.
func penerimaChat(o Order, pengirim string, sedangTerbuka map[string]bool) []string {
	tujuan := []string{}
	for _, phone := range []string{o.RiderPhone, o.DriverPhone} {
		if phone == "" || phone == pengirim || sedangTerbuka[phone] {
			continue
		}
		if slices.Contains(tujuan, phone) {
			continue
		}
		tujuan = append(tujuan, phone)
	}
	return tujuan
}

// teleponDiRuang mendaftar nomor yang koneksi chatnya sedang terbuka.
func teleponDiRuang(orderID string) map[string]bool {
	wsMutex.RLock()
	defer wsMutex.RUnlock()
	hadir := map[string]bool{}
	for _, c := range wsConnections[orderID] {
		hadir[c.phone] = true
	}
	return hadir
}

func broadcastToRoom(orderID string, msg []byte) {
	wsMutex.RLock()
	clients := append([]*wsClient(nil), wsConnections[orderID]...)
	wsMutex.RUnlock()
	for _, c := range clients {
		_ = c.send(msg)
	}
}

func removeWSConn(orderID string, client *wsClient) {
	wsMutex.Lock()
	defer wsMutex.Unlock()
	for i, c := range wsConnections[orderID] {
		if c == client {
			wsConnections[orderID] = append(wsConnections[orderID][:i], wsConnections[orderID][i+1:]...)
			break
		}
	}
}

// ==================== BOHFOOD HANDLERS ====================

func foodMerchantHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		// Mitra selalu melihat merchant miliknya sendiri; admin boleh menyebut lain.
		phone := callerPhone(r)
		if q := r.URL.Query().Get("owner_phone"); q != "" && isAdmin(r) {
			phone = q
		}
		var m FoodMerchant
		err := db.QueryRow("SELECT id, owner_phone, restaurant_name, address, image_url, is_open, created_at FROM food_merchants WHERE owner_phone = ?", phone).Scan(&m.ID, &m.OwnerPhone, &m.RestaurantName, &m.Address, &m.ImageURL, &m.IsOpen, &m.CreatedAt)
		if err != nil {
			writeJSONResponse(w, 404, map[string]string{"error": "Merchant not found"})
			return
		}
		writeJSONResponse(w, 200, m)
	} else if r.Method == http.MethodPost {
		var m FoodMerchant
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		if m.ID == "" {
			m.ID = newID("merchant")
		} else if !ownsMerchant(r, m.ID) {
			denyOwnership(w)
			return
		}
		// owner_phone dari body diabaikan; pemilik selalu pemanggil.
		m.OwnerPhone = callerPhone(r)
		m.CreatedAt = time.Now().Format(time.RFC3339)
		_, err := db.Exec("INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, image_url, is_open, created_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE restaurant_name = VALUES(restaurant_name), address = VALUES(address), image_url = VALUES(image_url), is_open = VALUES(is_open)", m.ID, m.OwnerPhone, m.RestaurantName, m.Address, m.ImageURL, m.IsOpen, m.CreatedAt)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": fmt.Sprintf("Failed to save merchant: %v", err)})
			return
		}
		writeJSONResponse(w, 200, m)
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func foodMenusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		merchantID := r.URL.Query().Get("merchant_id")
		if merchantID == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "merchant_id is required"})
			return
		}
		if !ownsMerchant(r, merchantID) {
			denyOwnership(w)
			return
		}
		rows, err := db.Query("SELECT id, merchant_id, name, description, price, category, image_url, is_available FROM food_menus WHERE merchant_id = ?", merchantID)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer rows.Close()
		menus := []FoodMenu{}
		for rows.Next() {
			var m FoodMenu
			if err := rows.Scan(&m.ID, &m.MerchantID, &m.Name, &m.Description, &m.Price, &m.Category, &m.ImageURL, &m.IsAvailable); err == nil {
				menus = append(menus, m)
			}
		}
		writeJSONResponse(w, 200, menus)
	} else if r.Method == http.MethodPost {
		var m FoodMenu
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		// Menu baru harus masuk ke merchant milik pemanggil; menu lama harus miliknya.
		if m.ID == "" {
			if !ownsMerchant(r, m.MerchantID) {
				denyOwnership(w)
				return
			}
			m.ID = newID("menu")
		} else if !ownsMenu(r, m.ID) || !ownsMerchant(r, m.MerchantID) {
			denyOwnership(w)
			return
		}
		if m.Price < 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Harga tidak boleh negatif"})
			return
		}
		_, err := db.Exec("INSERT INTO food_menus (id, merchant_id, name, description, price, category, image_url, is_available) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), description = VALUES(description), price = VALUES(price), category = VALUES(category), image_url = VALUES(image_url), is_available = VALUES(is_available)", m.ID, m.MerchantID, m.Name, m.Description, m.Price, m.Category, m.ImageURL, m.IsAvailable)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, m)
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func foodMenuDetailHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSONResponse(w, 400, map[string]string{"error": "Menu ID required"})
		return
	}
	menuID := parts[3]
	if !ownsMenu(r, menuID) {
		denyOwnership(w)
		return
	}

	if r.Method == http.MethodDelete {
		_, err := db.Exec("DELETE FROM food_menus WHERE id = ?", menuID)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Menu deleted"})
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// ==================== BOHRENTAL HANDLERS ====================

func rentalCarsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		const cols = "SELECT id, owner_phone, brand, model, plate_number, transmission, seats, price_per_day, image_url, status, vehicle_type, COALESCE(color, ''), created_at FROM rental_cars"
		var rows *sql.Rows
		var err error
		if isAdmin(r) {
			if q := r.URL.Query().Get("owner_phone"); q != "" {
				rows, err = db.Query(cols+" WHERE owner_phone = ?", q)
			} else {
				rows, err = db.Query(cols)
			}
		} else {
			// Mitra hanya melihat armadanya sendiri, apa pun isi query string.
			rows, err = db.Query(cols+" WHERE owner_phone = ?", callerPhone(r))
		}
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer rows.Close()
		cars := []RentalCar{}
		for rows.Next() {
			var c RentalCar
			if err := rows.Scan(&c.ID, &c.OwnerPhone, &c.Brand, &c.Model, &c.PlateNumber, &c.Transmission, &c.Seats, &c.PricePerDay, &c.ImageURL, &c.Status, &c.VehicleType, &c.Color, &c.CreatedAt); err == nil {
				cars = append(cars, c)
			}
		}
		writeJSONResponse(w, 200, cars)
	} else if r.Method == http.MethodPost {
		var c RentalCar
		if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		if c.ID == "" {
			prefix := "car"
			if c.VehicleType == "motorcycle" {
				prefix = "motor"
			}
			c.ID = newID(prefix)
		} else if !ownsCar(r, c.ID) {
			denyOwnership(w)
			return
		}
		if c.PricePerDay < 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Harga sewa tidak boleh negatif"})
			return
		}
		c.PlateNumber = strings.TrimSpace(c.PlateNumber)
		if c.PlateNumber == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "Plat nomor wajib diisi"})
			return
		}
		if !validCarColor(c.Color) {
			writeJSONResponse(w, 400, map[string]string{"error": "Warna armada tidak valid"})
			return
		}
		// owner_phone dari body diabaikan; pemilik selalu pemanggil.
		c.OwnerPhone = callerPhone(r)
		if c.VehicleType == "" {
			c.VehicleType = "car"
		}
		c.CreatedAt = time.Now().Format(time.RFC3339)
		// INSERT biasa, bukan ON DUPLICATE KEY UPDATE: plate_number itu UNIQUE untuk
		// seluruh sistem, jadi upsert akan menimpa armada mitra LAIN yang platnya sama
		// (pemiliknya tidak ikut berubah, tapi merek/harga/statusnya tertimpa diam-diam,
		// dan mitra yang mendaftar tidak mendapat mobil apa pun). Penyuntingan armada
		// punya jalurnya sendiri lewat PUT /rental/cars/{id}.
		_, err := db.Exec("INSERT INTO rental_cars (id, owner_phone, brand, model, plate_number, transmission, seats, price_per_day, image_url, status, vehicle_type, color, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", c.ID, c.OwnerPhone, c.Brand, c.Model, c.PlateNumber, c.Transmission, c.Seats, c.PricePerDay, c.ImageURL, c.Status, c.VehicleType, c.Color, c.CreatedAt)
		if isDuplicateEntry(err) {
			writeJSONResponse(w, 409, map[string]string{"error": "Plat nomor ini sudah terdaftar di sistem"})
			return
		}
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, c)
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func rentalCarDetailHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSONResponse(w, 400, map[string]string{"error": "Car ID required"})
		return
	}
	carID := parts[3]
	if !ownsCar(r, carID) {
		denyOwnership(w)
		return
	}

	if r.Method == http.MethodDelete {
		_, err := db.Exec("DELETE FROM rental_cars WHERE id = ?", carID)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Car deleted"})
	} else if r.Method == http.MethodPut {
		var car RentalCar
		if err := json.NewDecoder(r.Body).Decode(&car); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		car.PlateNumber = strings.TrimSpace(car.PlateNumber)
		if car.PlateNumber == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "Plat nomor wajib diisi"})
			return
		}
		if !validCarColor(car.Color) {
			writeJSONResponse(w, 400, map[string]string{"error": "Warna armada tidak valid"})
			return
		}
		_, err := db.Exec("UPDATE rental_cars SET brand = ?, model = ?, plate_number = ?, transmission = ?, seats = ?, price_per_day = ?, image_url = ?, status = ?, vehicle_type = ?, color = ? WHERE id = ?",
			car.Brand, car.Model, car.PlateNumber, car.Transmission, car.Seats, car.PricePerDay, car.ImageURL, car.Status, car.VehicleType, car.Color, carID)
		if isDuplicateEntry(err) {
			writeJSONResponse(w, 409, map[string]string{"error": "Plat nomor ini sudah terdaftar di sistem"})
			return
		}
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Car updated"})
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// warna armada dipakai langsung sebagai nilai CSS di kalender, jadi hanya heksa
// enam digit yang diterima; kosong berarti biarkan UI yang memilih otomatis.
var hexColorPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)

func validCarColor(c string) bool {
	return c == "" || hexColorPattern.MatchString(c)
}

// isDuplicateEntry mengenali pelanggaran UNIQUE dari MySQL (error 1062), dipakai
// untuk membalas bentrok plat nomor dengan pesan yang bisa dibaca mitra.
func isDuplicateEntry(err error) bool {
	return err != nil && strings.Contains(err.Error(), "1062")
}

var validBookingStatus = map[string]bool{
	"pending": true, "confirmed": true, "ongoing": true,
	"completed": true, "cancelled": true, "rejected": true,
}

// parseBookingWindow menerima "YYYY-MM-DD HH:mm:ss" dan menolak rentang yang
// terbalik atau sudah lewat.
func parseBookingWindow(startStr, endStr string) (time.Time, time.Time, error) {
	const layout = "2006-01-02 15:04:05"
	start, err := time.ParseInLocation(layout, startStr, time.Local)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("format waktu mulai tidak valid")
	}
	end, err := time.ParseInLocation(layout, endStr, time.Local)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("format waktu selesai tidak valid")
	}
	if !end.After(start) {
		return time.Time{}, time.Time{}, fmt.Errorf("waktu selesai harus setelah waktu mulai")
	}
	if start.Before(time.Now().Add(-24 * time.Hour)) {
		return time.Time{}, time.Time{}, fmt.Errorf("tanggal sewa sudah lewat")
	}
	return start, end, nil
}

// rentalDays membulatkan durasi ke atas; sewa apa pun dihitung minimal satu hari.
func rentalDays(start, end time.Time) int {
	d := int(end.Sub(start).Hours() / 24)
	if end.Sub(start)%(24*time.Hour) != 0 {
		d++
	}
	if d < 1 {
		d = 1
	}
	return d
}

// lateFeeSettings membaca aturan denda pemilik armada; mitra yang belum pernah
// mengaturnya dianggap tidak memungut denda.
func lateFeeSettings(ownerPhone string) RentalSettings {
	s := RentalSettings{OwnerPhone: ownerPhone, LateFeeMode: "off"}
	_ = db.QueryRow("SELECT late_fee_mode, late_fee_value, COALESCE(late_fee_grace_minutes, 0), COALESCE(updated_at, '') FROM rental_settings WHERE owner_phone = ?", ownerPhone).
		Scan(&s.LateFeeMode, &s.LateFeeVal, &s.GraceMinutes, &s.UpdatedAt)
	return s
}

// lateFee menghitung denda sebuah sewa yang baru ditutup. Masa toleransi dianggap
// waktu gratis: jam denda baru berjalan setelah toleransi habis, lalu dihitung per
// hari dengan pembulatan ke atas — sama seperti cara tarif sewanya sendiri dihitung.
func lateFee(ownerPhone string, pricePerDay float64, endTime, returnedAt time.Time) float64 {
	s := lateFeeSettings(ownerPhone)
	if s.LateFeeVal <= 0 {
		return 0
	}
	deadline := endTime.Add(time.Duration(s.GraceMinutes) * time.Minute)
	if !returnedAt.After(deadline) {
		return 0
	}
	days := float64(rentalDays(deadline, returnedAt))
	switch s.LateFeeMode {
	case "percent":
		return days * pricePerDay * s.LateFeeVal / 100
	case "amount":
		return days * s.LateFeeVal
	}
	return 0
}

func rentalSettingsHandler(w http.ResponseWriter, r *http.Request) {
	me := callerPhone(r)
	switch r.Method {
	case http.MethodGet:
		writeJSONResponse(w, 200, lateFeeSettings(me))
	case http.MethodPut:
		var input RentalSettings
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		switch input.LateFeeMode {
		case "off", "percent", "amount":
		default:
			writeJSONResponse(w, 400, map[string]string{"error": "Mode denda tidak dikenal"})
			return
		}
		if input.LateFeeVal < 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Nilai denda tidak boleh negatif"})
			return
		}
		// Batas atas menahan salah ketik, bukan membatasi kebijakan mitra.
		if input.LateFeeMode == "percent" && input.LateFeeVal > 1000 {
			writeJSONResponse(w, 400, map[string]string{"error": "Persentase denda terlalu besar (maksimal 1000%)"})
			return
		}
		// Toleransi bebas ditentukan mitra; batasnya hanya menahan salah ketik.
		if input.GraceMinutes < 0 || input.GraceMinutes > 10080 {
			writeJSONResponse(w, 400, map[string]string{"error": "Toleransi keterlambatan harus antara 0 menit dan 7 hari"})
			return
		}
		if input.LateFeeMode == "off" {
			input.LateFeeVal = 0
		}
		input.OwnerPhone = me
		input.UpdatedAt = time.Now().Format(time.RFC3339)
		if _, err := db.Exec(`INSERT INTO rental_settings (owner_phone, late_fee_mode, late_fee_value, late_fee_grace_minutes, updated_at) VALUES (?, ?, ?, ?, ?)
			ON DUPLICATE KEY UPDATE late_fee_mode = VALUES(late_fee_mode), late_fee_value = VALUES(late_fee_value), late_fee_grace_minutes = VALUES(late_fee_grace_minutes), updated_at = VALUES(updated_at)`,
			input.OwnerPhone, input.LateFeeMode, input.LateFeeVal, input.GraceMinutes, input.UpdatedAt); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, input)
	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func rentalBookingsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		// LEFT JOIN users: nama penyewa ikut dikirim supaya halaman Pesanan Masuk
		// tidak cuma menampilkan nomor HP. Akun yang sudah dihapus jadi string kosong.
		const joined = "SELECT b.id, b.car_id, b.customer_phone, COALESCE(u.name, ''), b.start_time, b.end_time, b.total_price, COALESCE(b.late_fee, 0), b.status, b.created_at, b.updated_at, COALESCE(b.notes, '') FROM rental_bookings b JOIN rental_cars c ON b.car_id = c.id LEFT JOIN users u ON b.customer_phone = u.phone_number"
		var rows *sql.Rows
		var err error
		if isAdmin(r) {
			rows, err = db.Query(joined)
		} else {
			// Pemilik mobil melihat booking armadanya; pelanggan melihat sewaannya.
			me := callerPhone(r)
			rows, err = db.Query(joined+" WHERE c.owner_phone = ? OR b.customer_phone = ?", me, me)
		}
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer rows.Close()
		bookings := []RentalBooking{}
		for rows.Next() {
			var b RentalBooking
			var st, et time.Time
			if err := rows.Scan(&b.ID, &b.CarID, &b.CustomerPhone, &b.CustomerName, &st, &et, &b.TotalPrice, &b.LateFee, &b.Status, &b.CreatedAt, &b.UpdatedAt, &b.Notes); err == nil {
				b.StartTime = st.Format("2006-01-02 15:04:05")
				b.EndTime = et.Format("2006-01-02 15:04:05")
				bookings = append(bookings, b)
			}
		}
		writeJSONResponse(w, 200, bookings)
	} else if r.Method == http.MethodPost {
		var b RentalBooking
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		// ID dan pelanggan ditentukan server, bukan client.
		b.ID = newID("booking")
		b.CustomerPhone = callerPhone(r)
		b.CreatedAt = time.Now().Format(time.RFC3339)
		b.UpdatedAt = time.Now().Format(time.RFC3339)

		start, end, err := parseBookingWindow(b.StartTime, b.EndTime)
		if err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": err.Error()})
			return
		}

		// Pessimistic Locking & Conflict Avoidance
		tx, err := db.Begin()
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer tx.Rollback()

		// 1. Lock the car row to prevent race conditions
		var pricePerDay float64
		var carStatus string
		err = tx.QueryRow("SELECT price_per_day, status FROM rental_cars WHERE id = ? FOR UPDATE", b.CarID).Scan(&pricePerDay, &carStatus)
		if err != nil {
			writeJSONResponse(w, 404, map[string]string{"error": "Car not found"})
			return
		}
		if carStatus != "active" {
			writeJSONResponse(w, 409, map[string]string{"error": "Kendaraan ini sedang tidak disewakan"})
			return
		}

		// Harga selalu dihitung ulang di server; total_price dari client diabaikan.
		b.TotalPrice = pricePerDay * float64(rentalDays(start, end))

		// 2. Check conflicts (Active Bookings + Owner schedules)
		// "OR end_time < NOW()": sewa yang lewat jatuh tempo tapi belum ditutup berarti
		// kendaraannya masih di luar dan waktu kembalinya tidak diketahui, jadi armadanya
		// menolak jadwal baru sampai mitra menekan "Selesai".
		var activeConflicts int
		conflictQuery := `
			SELECT (
				SELECT COUNT(*) FROM rental_bookings 
				WHERE car_id = ? AND status NOT IN ('cancelled', 'rejected', 'completed') AND start_time < ? AND (end_time > ? OR end_time < NOW())
			) + (
				SELECT COUNT(*) FROM rental_car_schedules
				WHERE car_id = ? AND COALESCE(status, 'active') <> 'completed' AND start_time < ? AND (end_time > ? OR end_time < NOW())
			)`
		err = tx.QueryRow(conflictQuery, b.CarID, b.EndTime, b.StartTime, b.CarID, b.EndTime, b.StartTime).Scan(&activeConflicts)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": fmt.Sprintf("Error checking schedules: %v", err)})
			return
		}

		if activeConflicts > 0 {
			writeJSONResponse(w, 409, map[string]string{"error": "Jadwal sewa bertabrakan dengan penyewaan/servis lain pada mobil ini"})
			return
		}

		// 3. Insert booking
		_, err = tx.Exec("INSERT INTO rental_bookings (id, car_id, customer_phone, start_time, end_time, total_price, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", b.ID, b.CarID, b.CustomerPhone, b.StartTime, b.EndTime, b.TotalPrice, "pending", b.CreatedAt, b.UpdatedAt)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": fmt.Sprintf("Failed to insert booking: %v", err)})
			return
		}

		if err := tx.Commit(); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, b)
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// allowedTransition menjaga alur pesanan tetap searah:
// pending → confirmed → ongoing → completed, dengan penolakan/pembatalan hanya
// di awal. Tombol di halaman mitra memang sudah menyesuaikan status, tapi
// halaman yang sudah basi bisa mengirim aksi untuk status yang telanjur berubah
// (mis. dua tab terbuka), jadi urutannya diperiksa juga di server.
var allowedTransition = map[string][]string{
	"pending": {"confirmed", "rejected", "cancelled"},
	// confirmed → completed sengaja dibolehkan: banyak mitra tidak pernah menekan
	// "Mulai Jalan" dan langsung menutup sewa saat kendaraan kembali.
	"confirmed": {"ongoing", "completed", "cancelled"},
	"ongoing":   {"completed"},
}

func canTransition(from, to string) bool {
	for _, s := range allowedTransition[from] {
		if s == to {
			return true
		}
	}
	return false
}

func rentalBookingDetailHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSONResponse(w, 400, map[string]string{"error": "Booking ID required"})
		return
	}
	bookingID := parts[3]

	// Satu query untuk dua hal sekaligus: memastikan pemanggil berhak, dan
	// mengetahui dia pemilik armada atau penyewa. Keduanya boleh membuka
	// pesanan yang sama tapi haknya berbeda.
	var ownerPhone, customerPhone, currentStatus string
	err := db.QueryRow(`
		SELECT c.owner_phone, b.customer_phone, b.status FROM rental_bookings b
		JOIN rental_cars c ON b.car_id = c.id
		WHERE b.id = ?`, bookingID).Scan(&ownerPhone, &customerPhone, &currentStatus)
	if err != nil {
		denyOwnership(w)
		return
	}
	me := callerPhone(r)
	isOwner := isAdmin(r) || ownerPhone == me
	if !isOwner && customerPhone != me {
		denyOwnership(w)
		return
	}

	if r.Method == http.MethodPut {
		var input struct {
			Status string `json:"status"`
			Notes  string `json:"notes"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		if !validBookingStatus[input.Status] {
			writeJSONResponse(w, 400, map[string]string{"error": "Status booking tidak dikenal"})
			return
		}
		// Penyewa hanya boleh membatalkan pesanannya sendiri; menyetujui,
		// menolak, dan menjalankan sewa adalah keputusan pemilik armada.
		if !isOwner && input.Status != "cancelled" {
			writeJSONResponse(w, 403, map[string]string{"error": "Hanya pemilik armada yang bisa mengubah status ini"})
			return
		}
		if !canTransition(currentStatus, input.Status) {
			writeJSONResponse(w, 409, map[string]string{
				"error": fmt.Sprintf("Pesanan berstatus %s tidak bisa diubah menjadi %s", currentStatus, input.Status),
			})
			return
		}
		input.Notes = strings.TrimSpace(input.Notes)
		if input.Status == "rejected" && input.Notes == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "Catatan alasan wajib diisi saat menolak pesanan"})
			return
		}
		if len([]rune(input.Notes)) > 500 {
			writeJSONResponse(w, 400, map[string]string{"error": "Catatan maksimal 500 karakter"})
			return
		}

		// Catatan lama dipertahankan kalau aksi berikutnya tidak membawa catatan,
		// supaya alasan penolakan tidak hilang begitu saja.
		query := "UPDATE rental_bookings SET status = ?, updated_at = ? WHERE id = ?"
		args := []interface{}{input.Status, time.Now().Format(time.RFC3339), bookingID}
		if input.Notes != "" {
			query = "UPDATE rental_bookings SET status = ?, notes = ?, updated_at = ? WHERE id = ?"
			args = []interface{}{input.Status, input.Notes, time.Now().Format(time.RFC3339), bookingID}
		}
		if _, err := db.Exec(query, args...); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}

		// Pesanan yang ditutup ikut dikenai denda keterlambatan pemilik armada,
		// memakai jam penutupan sebagai waktu pengembalian kendaraan.
		var fee float64
		if input.Status == "completed" {
			var pricePerDay float64
			var end time.Time
			if err := db.QueryRow(`SELECT c.price_per_day, b.end_time
				FROM rental_bookings b JOIN rental_cars c ON b.car_id = c.id
				WHERE b.id = ?`, bookingID).Scan(&pricePerDay, &end); err == nil {
				fee = lateFee(ownerPhone, pricePerDay, end, time.Now())
				if _, err := db.Exec("UPDATE rental_bookings SET late_fee = ? WHERE id = ?", fee, bookingID); err != nil {
					writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
					return
				}
			}
		}
		writeJSONResponse(w, 200, map[string]any{"status": "success", "message": "Booking status updated", "late_fee": fee})
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func rentalSchedulesHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		const cols = "SELECT s.id, s.car_id, s.start_time, s.end_time, s.reason, COALESCE(s.status, 'active'), COALESCE(s.late_fee, 0), s.created_at FROM rental_car_schedules s JOIN rental_cars c ON s.car_id = c.id"
		carID := r.URL.Query().Get("car_id")
		var rows *sql.Rows
		var err error
		switch {
		case carID != "":
			if !ownsCar(r, carID) {
				denyOwnership(w)
				return
			}
			rows, err = db.Query(cols+" WHERE s.car_id = ?", carID)
		case isAdmin(r):
			rows, err = db.Query(cols)
		default:
			rows, err = db.Query(cols+" WHERE c.owner_phone = ?", callerPhone(r))
		}
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer rows.Close()
		schedules := []RentalCarSchedule{}
		for rows.Next() {
			var s RentalCarSchedule
			var st, et time.Time
			if err := rows.Scan(&s.ID, &s.CarID, &st, &et, &s.Reason, &s.Status, &s.LateFee, &s.CreatedAt); err == nil {
				s.StartTime = st.Format("2006-01-02 15:04:05")
				s.EndTime = et.Format("2006-01-02 15:04:05")
				schedules = append(schedules, s)
			}
		}
		writeJSONResponse(w, 200, schedules)
	} else if r.Method == http.MethodPost {
		var s RentalCarSchedule
		if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		if s.ID == "" {
			s.ID = newID("schedule")
		} else if !ownsSchedule(r, s.ID) {
			denyOwnership(w)
			return
		}
		if !ownsCar(r, s.CarID) {
			denyOwnership(w)
			return
		}
		if _, _, err := parseBookingWindow(s.StartTime, s.EndTime); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": err.Error()})
			return
		}
		s.CreatedAt = time.Now().Format(time.RFC3339)
		s.Status = "active"

		// Check conflict before blocking manual schedule. Sama seperti pemesanan
		// dari aplikasi, sewa yang telat dikembalikan tetap mengunci armadanya.
		tx, err := db.Begin()
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer tx.Rollback()

		var activeConflicts int
		conflictQuery := `
			SELECT (
				SELECT COUNT(*) FROM rental_bookings 
				WHERE car_id = ? AND status NOT IN ('cancelled', 'rejected', 'completed') AND start_time < ? AND (end_time > ? OR end_time < NOW())
			) + (
				SELECT COUNT(*) FROM rental_car_schedules
				WHERE car_id = ? AND COALESCE(status, 'active') <> 'completed' AND start_time < ? AND (end_time > ? OR end_time < NOW())
			)`
		err = tx.QueryRow(conflictQuery, s.CarID, s.EndTime, s.StartTime, s.CarID, s.EndTime, s.StartTime).Scan(&activeConflicts)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": fmt.Sprintf("Error checking schedules: %v", err)})
			return
		}

		if activeConflicts > 0 {
			writeJSONResponse(w, 409, map[string]string{"error": "Jadwal blokir bertabrakan dengan booking/servis yang sudah ada"})
			return
		}

		_, err = tx.Exec("INSERT INTO rental_car_schedules (id, car_id, start_time, end_time, reason, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", s.ID, s.CarID, s.StartTime, s.EndTime, s.Reason, s.Status, s.CreatedAt)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}

		if err := tx.Commit(); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, s)
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func rentalScheduleDetailHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSONResponse(w, 400, map[string]string{"error": "Schedule ID required"})
		return
	}
	scheduleID := parts[3]
	if !ownsSchedule(r, scheduleID) {
		denyOwnership(w)
		return
	}

	if r.Method == http.MethodDelete {
		_, err := db.Exec("DELETE FROM rental_car_schedules WHERE id = ?", scheduleID)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Schedule blocked period deleted"})
	} else if r.Method == http.MethodPut {
		var input struct {
			CarID     string `json:"car_id"`
			StartTime string `json:"start_time"`
			EndTime   string `json:"end_time"`
			Reason    string `json:"reason"`
			Status    string `json:"status"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}

		// Menutup/membuka jadwal cukup kirim {"status": ...}; jadwal yang selesai
		// tetap tersimpan sebagai riwayat dan armadanya kembali bisa dipesan.
		if input.Status != "" && input.CarID == "" {
			if input.Status != "active" && input.Status != "completed" {
				writeJSONResponse(w, 400, map[string]string{"error": "Status jadwal tidak dikenal"})
				return
			}
			// Denda dihitung sekali di sini memakai jam penutupan sebagai waktu
			// pengembalian, lalu disimpan. Membuka lagi jadwal menghapus dendanya.
			var fee float64
			if input.Status == "completed" {
				var owner string
				var pricePerDay float64
				var end time.Time
				if err := db.QueryRow(`SELECT c.owner_phone, c.price_per_day, s.end_time
					FROM rental_car_schedules s JOIN rental_cars c ON s.car_id = c.id
					WHERE s.id = ?`, scheduleID).Scan(&owner, &pricePerDay, &end); err != nil {
					writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
					return
				}
				fee = lateFee(owner, pricePerDay, end, time.Now())
			}
			if _, err := db.Exec("UPDATE rental_car_schedules SET status = ?, late_fee = ? WHERE id = ?", input.Status, fee, scheduleID); err != nil {
				writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
				return
			}
			writeJSONResponse(w, 200, map[string]any{"status": "success", "message": "Status jadwal diperbarui", "late_fee": fee})
			return
		}

		var activeConflicts int
		conflictQuery := `
			SELECT (
				SELECT COUNT(*) FROM rental_bookings 
				WHERE car_id = ? AND status NOT IN ('cancelled', 'rejected', 'completed') AND start_time < ? AND (end_time > ? OR end_time < NOW())
			) + (
				SELECT COUNT(*) FROM rental_car_schedules
				WHERE car_id = ? AND id != ? AND COALESCE(status, 'active') <> 'completed' AND start_time < ? AND (end_time > ? OR end_time < NOW())
			)`
		err := db.QueryRow(conflictQuery, input.CarID, input.EndTime, input.StartTime, input.CarID, scheduleID, input.EndTime, input.StartTime).Scan(&activeConflicts)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": fmt.Sprintf("Error checking schedules: %v", err)})
			return
		}

		if activeConflicts > 0 {
			writeJSONResponse(w, 409, map[string]string{"error": "Jadwal sewa bertabrakan dengan penyewaan/servis lain pada mobil ini"})
			return
		}

		_, err = db.Exec("UPDATE rental_car_schedules SET car_id = ?, start_time = ?, end_time = ?, reason = ? WHERE id = ?",
			input.CarID, input.StartTime, input.EndTime, input.Reason, scheduleID)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Schedule updated successfully"})
	} else {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

// Tiap ekstensi hanya menerima satu tipe isi. Menerima octet-stream secara umum
// akan meloloskan file apa pun yang diberi nama .jpg, jadi HEIC/HEIF diperiksa
// terpisah lewat kotak "ftyp" di header berkasnya.
var uploadTypeByExt = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg",
	".png": "image/png", ".webp": "image/webp",
	".pdf": "application/pdf",
}

// isHEIF mengenali berkas HEIC/HEIF dari kotak ftyp pada 12 byte pertama.
func isHEIF(head []byte) bool {
	if len(head) < 12 || string(head[4:8]) != "ftyp" {
		return false
	}
	switch string(head[8:12]) {
	case "heic", "heix", "heim", "heis", "hevc", "mif1", "msf1":
		return true
	}
	return false
}

func uploadContentAllowed(ext string, head []byte) bool {
	if ext == ".heic" || ext == ".heif" {
		return isHEIF(head)
	}
	want, known := uploadTypeByExt[ext]
	return known && http.DetectContentType(head) == want
}

func uploadHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}

	// Batasi ukuran body sebelum apa pun dibaca ke memori atau disk.
	const maxUpload = 5 << 20 // 5 MB
	r.Body = http.MaxBytesReader(w, r.Body, maxUpload)
	if err := r.ParseMultipartForm(maxUpload); err != nil {
		writeJSONResponse(w, 413, map[string]string{"error": "Ukuran file melebihi batas 5 MB"})
		return
	}
	file, handler, err := r.FormFile("file")
	if err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Error retrieving the file"})
		return
	}
	defer file.Close()

	if err := os.MkdirAll("uploads", os.ModePerm); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Failed to create upload directory"})
		return
	}

	ext := strings.ToLower(filepath.Ext(handler.Filename))

	// Validasi Ekstensi File
	if ext != ".jpg" && ext != ".jpeg" && ext != ".png" && ext != ".webp" && ext != ".pdf" && ext != ".heic" && ext != ".heif" {
		writeJSONResponse(w, 400, map[string]string{"error": "Format file tidak valid. Hanya gambar (termasuk HEIC/iPhone) dan PDF yang diperbolehkan."})
		return
	}

	// Ekstensi saja bisa dipalsukan; isi file harus cocok dengan ekstensinya.
	head := make([]byte, 512)
	n, _ := io.ReadFull(file, head)
	if !uploadContentAllowed(ext, head[:n]) {
		writeJSONResponse(w, 400, map[string]string{"error": "Isi file tidak cocok dengan ekstensinya"})
		return
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca ulang file"})
		return
	}

	newFileName := newID("f") + ext
	dstPath := filepath.Join("uploads", newFileName)

	dst, err := os.Create(dstPath)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Error saving the file"})
		return
	}
	defer dst.Close()

	if _, err := io.Copy(dst, file); err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Error copying the file content"})
		return
	}

	fileURL := fmt.Sprintf("/uploads/%s", newFileName)
	writeJSONResponse(w, 200, map[string]string{
		"status": "success",
		"url":    fileURL,
	})
}

// ==================== AUTH HANDLERS ====================

type LoginInput struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var input LoginInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
		return
	}
	ip := alamatPemanggil(r)
	if terlaluSeringGagal(ip) {
		writeJSONResponse(w, 429, map[string]string{"error": "Terlalu banyak percobaan masuk yang gagal. Coba lagi 15 menit lagi."})
		return
	}
	u, hash, found := dbFindUserByEmail(strings.ToLower(strings.TrimSpace(input.Email)))
	if !found || !checkPassword(hash, input.Password) {
		catatGagalLogin(ip)
		writeJSONResponse(w, 401, map[string]string{"error": "Email atau password salah"})
		return
	}
	token, err := issueToken(u.PhoneNumber, u.Role)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat token sesi"})
		return
	}
	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"token":  token,
		"role":   u.Role,
		"phone":  u.PhoneNumber,
		"name":   u.Name,
		"email":  u.Email,
	})
}

// ==================== SUBSCRIPTION & XENDIT HANDLERS ====================

// startTrialSubscription mendaftarkan masa percobaan 14 hari untuk mitra rental.
func startTrialSubscription(phone string) PartnerSubscription {
	sub := PartnerSubscription{
		PhoneNumber: phone,
		Status:      "TRIAL",
		ValidUntil:  time.Now().AddDate(0, 0, 14).Format(time.RFC3339),
		UpdatedAt:   time.Now().Format(time.RFC3339),
	}
	_ = dbSavePartnerSubscription(sub)
	return sub
}

func subscriptionStatusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	// Mitra hanya melihat langganannya sendiri; admin boleh menyebut nomor lain.
	phone := callerPhone(r)
	if q := r.URL.Query().Get("phone"); q != "" && isAdmin(r) {
		phone = q
	}

	sub, exists := dbGetPartnerSubscription(phone)
	if !exists {
		// Jika dia adalah mitra rental, daftarkan otomatis masa trial selama 14 hari
		var role string
		err := db.QueryRow("SELECT role FROM users WHERE phone_number = ?", phone).Scan(&role)
		if err == nil && role == "rental_partner" {
			sub = startTrialSubscription(phone)
			exists = true
		}
	}

	if !exists {
		writeJSONResponse(w, 404, map[string]string{"error": "Subscription not found"})
		return
	}

	// Update status secara dinamis jika masa aktif telah habis
	validTime, err := time.Parse(time.RFC3339, sub.ValidUntil)
	if err == nil && time.Now().After(validTime) && sub.Status != "EXPIRED" {
		sub.Status = "EXPIRED"
		sub.UpdatedAt = time.Now().Format(time.RFC3339)
		_ = dbSavePartnerSubscription(sub)
	}

	writeJSONResponse(w, 200, sub)
}

type CreateSubInput struct {
	Phone string `json:"phone"`
}

func subscriptionCreateHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	// Invoice selalu dibuat atas nama pemanggil; nomor dari body diabaikan.
	var input CreateSubInput
	_ = json.NewDecoder(r.Body).Decode(&input)
	input.Phone = callerPhone(r)

	// Ambil data email mitra dan pastikan user tersebut terdaftar
	var email string
	err := db.QueryRow("SELECT email FROM users WHERE phone_number = ?", input.Phone).Scan(&email)
	if err != nil {
		writeJSONResponse(w, 404, map[string]string{"error": "Nomor handphone tidak terdaftar di sistem"})
		return
	}

	origin := r.Header.Get("Origin")
	if origin == "" {
		origin = "http://localhost:5173"
	}
	successRedirectURL := origin + "/#/subscription"

	// Awalan "bohantar-" bukan hiasan: akun Xendit ini dipakai bersama Kasvo
	// Indonesia, dan awalan inilah yang dipakai callback Kasvo untuk memutuskan
	// payload mana yang diteruskan ke sini. Kalau diubah, ubah juga
	// AdminLanggananController::xenditCallback di sisi Kasvo.
	externalID := fmt.Sprintf("bohantar-sub-%d-%s", time.Now().Unix(), input.Phone)
	xenditKey := getEnv("XENDIT_SECRET_KEY", "mock")

	invoiceID := newID("inv")
	var paymentURL string

	if xenditKey == "mock" || xenditKey == "" {
		// Mock Xendit URL
		paymentURL = fmt.Sprintf("http://localhost:8080/api/xendit/mock-checkout?id=%s&phone=%s&external_id=%s&redirect_url=%s", invoiceID, input.Phone, externalID, url.QueryEscape(successRedirectURL+"?payment=success"))
	} else {
		// Real Xendit API Call
		payload := map[string]interface{}{
			"external_id":          externalID,
			"amount":               100000,
			"payer_email":          email,
			"description":          "Pembayaran Langganan SaaS bohRental (1 Bulan)",
			"success_redirect_url": successRedirectURL,
		}
		jsonPayload, _ := json.Marshal(payload)

		req, err := http.NewRequest("POST", "https://api.xendit.co/v2/invoices", bytes.NewBuffer(jsonPayload))
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membuat invoice request"})
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.SetBasicAuth(xenditKey, "")

		// Dukungan xenPlatform: Kirimkan tagihan atas nama sub-akun jika ID ditentukan
		subAccountID := getEnv("XENDIT_SUB_ACCOUNT_ID", "")
		if subAccountID != "" {
			req.Header.Set("for-user-id", subAccountID)
		}

		client := &http.Client{}
		resp, err := client.Do(req)
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Koneksi Xendit API error"})
			return
		}
		defer resp.Body.Close()

		var xenditResp struct {
			ID         string `json:"id"`
			InvoiceURL string `json:"invoice_url"`
			Error      string `json:"error_message"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&xenditResp); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal membaca response Xendit"})
			return
		}

		if xenditResp.Error != "" {
			writeJSONResponse(w, 400, map[string]string{"error": xenditResp.Error})
			return
		}

		invoiceID = xenditResp.ID
		paymentURL = xenditResp.InvoiceURL
	}

	// Simpan invoice tagihan
	inv := SubscriptionInvoice{
		ID:          invoiceID,
		PhoneNumber: input.Phone,
		Amount:      100000,
		Status:      "PENDING",
		PaymentURL:  paymentURL,
		CreatedAt:   time.Now().Format(time.RFC3339),
	}
	_ = dbSaveSubscriptionInvoice(inv)

	writeJSONResponse(w, 200, map[string]string{
		"invoice_id":  invoiceID,
		"payment_url": paymentURL,
	})
}

func subscriptionInvoicesHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	phone := callerPhone(r)
	if q := r.URL.Query().Get("phone"); q != "" && isAdmin(r) {
		phone = q
	}
	invoices, err := dbGetSubscriptionInvoices(phone)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
		return
	}
	writeJSONResponse(w, 200, invoices)
}

// Xendit memakai PAID saat invoice dibayar dan SETTLED saat dananya sudah
// diteruskan ke saldo. Keduanya berarti uangnya masuk; menerima PAID saja
// membuat sebagian pembayaran diabaikan diam-diam.
func statusLunas(s string) bool {
	switch strings.ToUpper(strings.TrimSpace(s)) {
	case "PAID", "SETTLED":
		return true
	}
	return false
}

// Callback invoice Xendit membawa `amount` (nilai tagihan) dan `paid_amount`
// (yang benar-benar dibayar). Yang menentukan kurang bayar adalah yang kedua —
// membandingkan `amount` dengan nilai tersimpan selalu sama besar, jadi
// pemeriksaannya tidak pernah menolak apa pun. `amount` hanya dipakai kalau
// `paid_amount` tidak dikirim, misalnya oleh jalur mock lokal.
func nominalDibayar(paidAmount, amount float64) float64 {
	if paidAmount > 0 {
		return paidAmount
	}
	return amount
}

func xenditWebhookHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}

	// Verifikasi callback token. Di produksi token wajib ada dan wajib cocok;
	// tidak ada lagi jalur "lolos karena belum dikonfigurasi".
	expectedToken := getEnv("XENDIT_CALLBACK_TOKEN", "")
	if isProduction() {
		if expectedToken == "" {
			log.Println("Webhook ditolak: XENDIT_CALLBACK_TOKEN belum diisi")
			writeJSONResponse(w, 503, map[string]string{"error": "Webhook belum dikonfigurasi"})
			return
		}
		if !subtleEqual(r.Header.Get("X-Callback-Token"), expectedToken) {
			writeJSONResponse(w, 401, map[string]string{"error": "Token callback tidak cocok"})
			return
		}
	}

	var payload struct {
		ID         string  `json:"id"`
		ExternalID string  `json:"external_id"`
		Status     string  `json:"status"`
		Amount     float64 `json:"amount"`
		PaidAmount float64 `json:"paid_amount"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSONResponse(w, 400, map[string]string{"error": "Invalid JSON"})
		return
	}

	if !statusLunas(payload.Status) {
		// Diam-diam melewatkan status yang tak dikenal pernah menghabiskan satu jam
		// penelusuran. Sekarang meninggalkan jejak.
		log.Printf("Webhook dilewati: status %q bukan pembayaran lunas (invoice %s)", payload.Status, payload.ID)
	}

	if statusLunas(payload.Status) {
		inv, exists := dbGetSubscriptionInvoice(payload.ID)
		if !exists {
			log.Printf("Webhook: invoice %s tidak ditemukan, langganan tidak diaktifkan (external_id=%s)", payload.ID, payload.ExternalID)
		}
		// Nominal yang dibayar harus sama dengan tagihan; pembayaran kurang ditolak.
		dibayar := nominalDibayar(payload.PaidAmount, payload.Amount)
		if exists && dibayar > 0 && dibayar < inv.Amount {
			log.Printf("Webhook ditolak: invoice %s tertagih %.0f tapi dibayar %.0f", inv.ID, inv.Amount, dibayar)
			writeJSONResponse(w, 400, map[string]string{"error": "Nominal pembayaran tidak sesuai tagihan"})
			return
		}
		if exists && inv.Status != "PAID" {
			inv.Status = "PAID"
			_ = dbSaveSubscriptionInvoice(inv)

			// Update partner subscription
			sub, subExists := dbGetPartnerSubscription(inv.PhoneNumber)
			var baseTime time.Time
			if subExists {
				validTime, err := time.Parse(time.RFC3339, sub.ValidUntil)
				if err == nil && validTime.After(time.Now()) {
					baseTime = validTime
				} else {
					baseTime = time.Now()
				}
			} else {
				baseTime = time.Now()
			}

			newValidUntil := baseTime.AddDate(0, 1, 0).Format(time.RFC3339) // Tambah 1 bulan
			sub.PhoneNumber = inv.PhoneNumber
			sub.Status = "ACTIVE"
			sub.ValidUntil = newValidUntil
			sub.UpdatedAt = time.Now().Format(time.RFC3339)
			_ = dbSavePartnerSubscription(sub)
		}
	}

	writeJSONResponse(w, 200, map[string]string{"message": "Webhook berhasil diproses"})
}

func adminReportsSubscriptionsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	invoices, err := dbGetSubscriptionInvoices("")
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
		return
	}
	writeJSONResponse(w, 200, invoices)
}

func xenditMockCheckoutHandler(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	phone := r.URL.Query().Get("phone")
	externalID := r.URL.Query().Get("external_id")
	redirectURL := r.URL.Query().Get("redirect_url")
	if redirectURL == "" {
		redirectURL = "http://localhost:5173/#/subscription?payment=success"
	}

	html := fmt.Sprintf(`
	<!DOCTYPE html>
	<html>
	<head>
		<title>Simulasi Xendit Payment</title>
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<style>
			body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f3f4f6; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
			.card { background: white; padding: 32px; border-radius: 16px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); max-width: 400px; width: 100%%; text-align: center; }
			.logo { font-size: 24px; font-weight: bold; color: #1e3a8a; margin-bottom: 8px; }
			.merchant { font-size: 14px; color: #6b7280; margin-bottom: 24px; }
			.amount { font-size: 32px; font-weight: 800; color: #111827; margin-bottom: 24px; }
			.btn { background: #2563eb; color: white; border: none; padding: 12px 24px; border-radius: 8px; font-weight: 600; cursor: pointer; width: 100%%; font-size: 16px; transition: background 0.2s; }
			.btn:hover { background: #1d4ed8; }
			.details { text-align: left; margin: 24px 0; font-size: 14px; color: #374151; }
			.detail-row { display: flex; justify-content: space-between; margin-bottom: 8px; }
		</style>
	</head>
	<body>
		<div class="card">
			<div class="logo">XENDIT SIMULATOR</div>
			<div class="merchant">Kasvo Indonesia</div>
			<div class="amount">Rp 100.000</div>
			<hr style="border: 0; border-top: 1px solid #e5e7eb; margin: 24px 0;">
			<div class="details">
				<div class="detail-row"><span>Deskripsi:</span><strong>Langganan SaaS bohRental</strong></div>
				<div class="detail-row"><span>ID Invoice:</span><strong>%s</strong></div>
				<div class="detail-row"><span>No HP Mitra:</span><strong>%s</strong></div>
			</div>
			<form method="POST" action="/api/xendit/mock-pay">
				<input type="hidden" name="id" value="%s">
				<input type="hidden" name="phone" value="%s">
				<input type="hidden" name="external_id" value="%s">
				<input type="hidden" name="redirect_url" value="%s">
				<button type="submit" class="btn">Selesaikan Pembayaran (Simulasi)</button>
			</form>
		</div>
	</body>
	</html>
	`, id, phone, id, phone, externalID, redirectURL)

	w.Header().Set("Content-Type", "text/html")
	w.Write([]byte(html))
}

func xenditMockPayHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", 405)
		return
	}
	r.ParseForm()
	id := r.FormValue("id")
	externalID := r.FormValue("external_id")
	redirectURL := r.FormValue("redirect_url")
	if redirectURL == "" {
		redirectURL = "http://localhost:5173/#/subscription?payment=success"
	}

	// Panggil webhook internal secara lokal
	payload := map[string]interface{}{
		"id":          id,
		"external_id": externalID,
		"status":      "PAID",
	}
	jsonPayload, _ := json.Marshal(payload)

	req, _ := http.NewRequest("POST", "http://localhost:8080/api/xendit/webhook", bytes.NewBuffer(jsonPayload))
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	_, err := client.Do(req)
	if err != nil {
		http.Error(w, "Gagal memproses webhook simulasi", 500)
		return
	}

	// Alihkan kembali ke frontend React menggunakan URL dinamis
	http.Redirect(w, r, redirectURL, http.StatusSeeOther)
}

// ==================== BOHRENTAL: JASA / LAYANAN ====================

// RentalService adalah layanan tambahan yang ditawarkan mitra, misalnya
// "Lepas Kunci" (gratis) atau "Dengan Supir" (ada tarif harian). Isinya
// sepenuhnya diatur mitra lewat CRUD, tidak ada daftar bawaan sistem.
type RentalService struct {
	ID         string  `json:"id"`
	OwnerPhone string  `json:"owner_phone"`
	Name       string  `json:"name"`
	Price      float64 `json:"price"` // tarif tambahan per hari; 0 = tidak menambah biaya
	CreatedAt  string  `json:"created_at"`
}

// sanitizeServiceName menahan karakter "|" karena reason jadwal disimpan
// sebagai teks berpemisah pipa; nama jasa yang mengandung "|" merusak parsing.
func sanitizeServiceName(name string) string {
	return strings.TrimSpace(strings.ReplaceAll(name, "|", "/"))
}

func rentalServicesHandler(w http.ResponseWriter, r *http.Request) {
	// ponytail: hanya scope mitra sendiri; super admin belum punya halaman jasa.
	switch r.Method {
	case http.MethodGet:
		rows, err := db.Query("SELECT id, owner_phone, name, price, created_at FROM rental_services WHERE owner_phone = ? ORDER BY name", callerPhone(r))
		if err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		defer rows.Close()
		services := []RentalService{}
		for rows.Next() {
			var s RentalService
			if err := rows.Scan(&s.ID, &s.OwnerPhone, &s.Name, &s.Price, &s.CreatedAt); err == nil {
				services = append(services, s)
			}
		}
		writeJSONResponse(w, 200, services)
	case http.MethodPost:
		var s RentalService
		if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		s.Name = sanitizeServiceName(s.Name)
		if s.Name == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "Nama jasa wajib diisi"})
			return
		}
		if s.Price < 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Tarif jasa tidak boleh negatif"})
			return
		}
		s.OwnerPhone = callerPhone(r)
		s.ID = newID("service")
		s.CreatedAt = time.Now().Format(time.RFC3339)
		if _, err := db.Exec("INSERT INTO rental_services (id, owner_phone, name, price, created_at) VALUES (?, ?, ?, ?, ?)", s.ID, s.OwnerPhone, s.Name, s.Price, s.CreatedAt); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, s)
	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}

func rentalServiceDetailHandler(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSONResponse(w, 400, map[string]string{"error": "Service ID required"})
		return
	}
	serviceID := parts[3]
	var owner string
	if db.QueryRow("SELECT owner_phone FROM rental_services WHERE id = ?", serviceID).Scan(&owner) != nil || owner != callerPhone(r) {
		denyOwnership(w)
		return
	}

	switch r.Method {
	case http.MethodDelete:
		if _, err := db.Exec("DELETE FROM rental_services WHERE id = ?", serviceID); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Service deleted"})
	case http.MethodPut:
		var input struct {
			Name  string  `json:"name"`
			Price float64 `json:"price"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			writeJSONResponse(w, 400, map[string]string{"error": "Invalid request body"})
			return
		}
		input.Name = sanitizeServiceName(input.Name)
		if input.Name == "" {
			writeJSONResponse(w, 400, map[string]string{"error": "Nama jasa wajib diisi"})
			return
		}
		if input.Price < 0 {
			writeJSONResponse(w, 400, map[string]string{"error": "Tarif jasa tidak boleh negatif"})
			return
		}
		if _, err := db.Exec("UPDATE rental_services SET name = ?, price = ? WHERE id = ?", input.Name, input.Price, serviceID); err != nil {
			writeJSONResponse(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSONResponse(w, 200, map[string]string{"status": "success", "message": "Service updated"})
	default:
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
	}
}
