package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

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

	// --- daftar dari HP: form + tiga dokumen dalam satu permintaan ---
	body := &bytes.Buffer{}
	form := multipart.NewWriter(body)
	for k, v := range map[string]string{
		"phone_number": phone, "name": "Uji Driver", "email": email,
		"ktp_number": "1234567890123456", "sim_number": "SIM123",
		"vehicle_plate": "KB1234XY", "vehicle_type": "motor", "vehicle_model": "Beat",
		"password": "rahasia123",
	} {
		form.WriteField(k, v)
	}
	// PNG 1x1 sungguhan: isi berkas diperiksa, bukan hanya ekstensinya.
	png := []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 'I', 'H', 'D', 'R'}
	for _, f := range []string{"ktp_photo", "sim_photo", "stnk_photo"} {
		w, _ := form.CreateFormFile(f, f+".png")
		w.Write(png)
	}
	form.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/admin/drivers/register", body)
	req.Header.Set("Content-Type", form.FormDataContentType())
	rec := httptest.NewRecorder()
	adminDriverRegisterHandler(rec, req)
	if rec.Code != 201 {
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
}
