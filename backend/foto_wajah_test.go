package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Foto wajah dipasang driver lewat PUT profil lalu sampai ke penumpang lewat
// infoDriver. Penumpang tidak boleh memasangnya, dan alamat luar ditolak
// karena aplikasi penumpang memuatnya sebagai gambar.
func TestFotoWajahDriverSampaiKePenumpang(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000212"
	penggunaUji(t, phone)

	pasang := func(foto string) int {
		req := httptest.NewRequest(http.MethodPut, "/api/users/profile", strings.NewReader(`{"foto_wajah":"`+foto+`"}`))
		req.Header.Set("Authorization", "Bearer "+tokenUji(t, phone))
		rec := httptest.NewRecorder()
		profileHandler(rec, req)
		return rec.Code
	}

	if kode := pasang("/uploads/f-wajah.jpg"); kode != 403 {
		t.Fatalf("penumpang memasang foto wajah dapat HTTP %d, harusnya 403", kode)
	}
	if _, err := db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1 WHERE phone_number = ?", phone); err != nil {
		t.Fatalf("gagal menjadikan pengguna uji driver: %v", err)
	}
	for _, buruk := range []string{"https://evil.example/x.jpg", "/uploads/../etc/passwd", "/uploads/f-ktp.pdf"} {
		if kode := pasang(buruk); kode != 400 {
			t.Fatalf("foto %q dapat HTTP %d, harusnya 400", buruk, kode)
		}
	}
	if kode := pasang("/uploads/f-wajah.jpg"); kode != 200 {
		t.Fatalf("driver memasang foto wajah dapat HTTP %d", kode)
	}
	if got := infoDriver(phone)["foto"]; got != "/uploads/f-wajah.jpg" {
		t.Fatalf("penumpang melihat foto %q, harusnya /uploads/f-wajah.jpg", got)
	}

	// Dikunci: driver tidak bisa menggantinya sendiri...
	if kode := pasang("/uploads/f-orang-lain.jpg"); kode != 409 {
		t.Fatalf("mengganti foto yang terkunci dapat HTTP %d, harusnya 409", kode)
	}
	// ...sampai admin membuka kuncinya.
	req := httptest.NewRequest(http.MethodPut, "/api/admin/users/"+strings.TrimPrefix(phone, "+"), strings.NewReader(`{"hapus_foto_wajah":true}`))
	rec := httptest.NewRecorder()
	adminUserDetailHandler(rec, req)
	if rec.Code != 200 || fotoWajah(phone) != "" {
		t.Fatalf("admin membuka kunci foto: HTTP %d, foto %q", rec.Code, fotoWajah(phone))
	}
	if kode := pasang("/uploads/f-wajah-baru.jpg"); kode != 200 {
		t.Fatalf("setelah dibuka admin, driver memasang foto baru dapat HTTP %d", kode)
	}
	if got := fotoWajah(phone); got != "/uploads/f-wajah-baru.jpg" {
		t.Fatalf("foto setelah ambil ulang %q", got)
	}
	// Akun dihapus → selfie ikut dihapus dari disk.
	ada := false
	for _, b := range berkasMilikAkun(phone) {
		ada = ada || b == "/uploads/f-wajah-baru.jpg"
	}
	if !ada {
		t.Fatal("foto wajah tidak ikut dibersihkan saat akun dihapus")
	}
}
