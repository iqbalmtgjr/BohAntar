package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// pengajuanDariHP meniru formulir daftar driver di aplikasi (tanpa token).
func pengajuanDariHP(phone, email, password, kendaraan string) *httptest.ResponseRecorder {
	body := &bytes.Buffer{}
	form := multipart.NewWriter(body)
	for k, v := range map[string]string{
		"phone_number": phone, "name": "Uji Driver", "email": email,
		"ktp_number": "1234567890123456", "sim_number": "SIM123",
		"vehicle_plate": "KB1234XY", "vehicle_type": kendaraan, "vehicle_model": "Beat",
		"password": password,
	} {
		form.WriteField(k, v)
	}
	// PNG 1x1 sungguhan: isi berkas diperiksa, bukan hanya ekstensinya.
	png := []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 'I', 'H', 'D', 'R'}
	for _, f := range []string{"ktp_photo", "sim_photo", "stnk_photo", "face_photo"} {
		w, _ := form.CreateFormFile(f, f+".png")
		w.Write(png)
	}
	form.Close()
	req := httptest.NewRequest(http.MethodPost, "/api/admin/drivers/register", body)
	req.Header.Set("Content-Type", form.FormDataContentType())
	req.RemoteAddr = "198.51.100.7:1234" // ember rem sendiri, lepas dari tes lain
	rec := httptest.NewRecorder()
	adminDriverRegisterHandler(rec, req)
	return rec
}

// Akun berperan driver, nonaktif, tanpa baris pengajuan = sisa pengajuan yang
// gagal tersimpan. Penjaga "sudah jadi driver" tidak boleh menguncinya: dia
// belum pernah bisa bekerja, jadi harus bisa mengajukan ulang.
func TestAkunDriverTanpaPengajuanBolehMengajukanUlang(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000213"
	penggunaUji(t, phone)
	t.Cleanup(func() { db.Exec("DELETE FROM driver_applications WHERE phone_number = ?", phone) })
	db.Exec("UPDATE users SET role = 'driver', is_driver_active = 0 WHERE phone_number = ?", phone)

	rec := pengajuanDariHP(phone, "", "rahasia123", "mobil")
	if rec.Code != 201 {
		t.Fatalf("akun yatim ditolak mengajukan ulang: %d %s", rec.Code, rec.Body.String())
	}
	var hasil struct {
		AkunLama bool `json:"akun_lama"`
	}
	json.Unmarshal(rec.Body.Bytes(), &hasil)
	if !hasil.AkunLama {
		t.Fatal("nomor yang sudah punya akun tidak ditandai akun_lama — aplikasi akan menyuruh masuk dengan password yang tidak dipakai")
	}
}

// Pendaftaran driver dari HP menyentuh tiga hal yang cuma kelihatan salah kalau
// dijalankan sungguhan: baris pengajuan ditolak foreign key kalau akunnya belum
// dibuat, dan gerbang login harus menahan akun yang perannya sudah "driver"
// tapi pengajuannya belum disetujui. Satu tes menelusuri seluruh alurnya.
func TestDaftarDriverDariHPTertahanSampaiDisetujui(t *testing.T) {
	bukaDBTes(t)

	phone := "+62898" + time.Now().Format("150405")
	email := "driver" + time.Now().Format("150405") + "@contoh.test"
	t.Cleanup(func() {
		db.Exec("DELETE FROM driver_applications WHERE phone_number = ?", phone)
		db.Exec("DELETE FROM users WHERE phone_number = ?", phone)
	})

	// --- daftar dari HP: form + foto wajah + tiga dokumen dalam satu permintaan ---
	dariHP := func(password, kendaraan string) *httptest.ResponseRecorder {
		return pengajuanDariHP(phone, email, password, kendaraan)
	}
	if rec := dariHP("rahasia123", "motor"); rec.Code != 201 {
		t.Fatalf("pendaftaran ditolak: %d %s", rec.Code, rec.Body.String())
	}

	// Pengajuan harus benar-benar ada di database, bukan cuma dibalas "success".
	if s := statusPengajuanDriver(phone); s != "pending" {
		t.Fatalf("status pengajuan = %q, mau \"pending\"", s)
	}
	if _, ada := dbGetUser(phone); !ada {
		t.Fatal("akun driver tidak dibuat, pengajuannya pasti ditolak foreign key")
	}

	// --- login harus ditolak walau passwordnya benar ---
	login := func() *httptest.ResponseRecorder {
		b, _ := json.Marshal(map[string]string{"email": email, "password": "rahasia123"})
		r := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewReader(b))
		r.RemoteAddr = "203.0.113.9:1234"
		w := httptest.NewRecorder()
		loginHandler(w, r)
		return w
	}
	if got := login(); got.Code != 403 {
		t.Fatalf("driver pending bisa masuk: %d %s", got.Code, got.Body.String())
	}

	// --- setelah disetujui, password yang sama harus lolos ---
	var appID string
	if err := db.QueryRow("SELECT id FROM driver_applications WHERE phone_number = ?", phone).Scan(&appID); err != nil {
		t.Fatalf("id pengajuan tidak terbaca: %v", err)
	}
	ar := httptest.NewRecorder()
	adminDriverApproveHandler(ar, httptest.NewRequest(http.MethodPost, fmt.Sprintf("/api/admin/drivers/%s/approve", appID), nil))
	if ar.Code != 200 {
		t.Fatalf("approve gagal: %d %s", ar.Code, ar.Body.String())
	}
	// Password pilihannya sendiri tidak boleh ditimpa password acak.
	var hasil struct {
		InitialPassword string `json:"initial_password"`
	}
	json.Unmarshal(ar.Body.Bytes(), &hasil)
	if hasil.InitialPassword != "" {
		t.Fatal("approve menimpa password yang sudah dipilih pendaftar")
	}
	if got := login(); got.Code != 200 {
		t.Fatalf("driver yang sudah disetujui tetap tidak bisa masuk: %d %s", got.Code, got.Body.String())
	}
	// Selfie yang dicek admin saat approve jadi foto yang dilihat penumpang.
	t.Cleanup(func() {
		if f := fotoWajah(phone); isUploadedFileURL(f) {
			os.Remove(filepath.Join("uploads", strings.TrimPrefix(f, "/uploads/")))
		}
	})
	if a, _ := dbGetApplication(appID); a.FacePhotoURL == "" || fotoWajah(phone) != a.FacePhotoURL {
		t.Fatalf("foto wajah pengajuan %q tidak tersalin ke akun (foto akun %q)", a.FacePhotoURL, fotoWajah(phone))
	}

	// --- orang asing yang tahu nomornya mengisi formulir publik lagi ---
	// Dulu password driver langsung ditimpa dan loginnya tertahan "ditinjau".
	if rec := dariHP("penyerang123", "mobil"); rec.Code != 409 {
		t.Fatalf("formulir publik menerima pengajuan untuk driver aktif: %d %s", rec.Code, rec.Body.String())
	}
	if s := statusPengajuanDriver(phone); s != "approved" {
		t.Fatalf("status pengajuan berubah jadi %q, driver aslinya terkunci", s)
	}
	if got := login(); got.Code != 200 {
		t.Fatalf("password driver ditimpa formulir publik: %d %s", got.Code, got.Body.String())
	}

	// --- ganti motor ke mobil tetap bisa, lewat admin ---
	b, _ := json.Marshal(map[string]string{
		"phone_number": phone, "name": "Uji Driver", "ktp_number": "1234567890123456",
		"sim_number": "SIMA123", "vehicle_plate": "KB1234XY", "vehicle_type": "mobil",
		"ktp_photo_url": "/uploads/ktp.png", "sim_photo_url": "/uploads/sim.png", "stnk_photo_url": "/uploads/stnk.png",
	})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/drivers/register", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+mustToken(t, "+620000000001", "admin"))
	rec := httptest.NewRecorder()
	adminDriverRegisterHandler(rec, req)
	if rec.Code != 201 {
		t.Fatalf("admin tidak bisa mengajukan ganti kendaraan: %d %s", rec.Code, rec.Body.String())
	}
}
