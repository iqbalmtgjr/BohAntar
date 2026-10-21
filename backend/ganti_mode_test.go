package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Akun driver bisa memesan dari mode penumpang. Kalau dia beralih lagi ke mode
// driver selagi pesanannya masih menunggu, pesanan itu tidak boleh dia ambil.
func TestDriverTidakBisaMengambilPesanannyaSendiri(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000210"
	oid := pesananUji(t, phone, "cash", "pending", 10000)
	if _, err := db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1 WHERE phone_number = ?", phone); err != nil {
		t.Fatalf("gagal menjadikan pengguna uji driver: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/orders/"+oid+"/accept", nil)
	req.Header.Set("Authorization", "Bearer "+tokenUji(t, phone))
	rec := httptest.NewRecorder()
	acceptOrder(rec, req, oid)

	if rec.Code != 403 {
		t.Fatalf("mengambil pesanan sendiri dapat HTTP %d, harusnya 403", rec.Code)
	}
	if o, _ := dbGetOrder(oid); o.Status != "pending" || o.DriverPhone != "" {
		t.Fatalf("pesanan berubah jadi %q oleh %q padahal ditolak", o.Status, o.DriverPhone)
	}
}

// Penumpang yang disetujui jadi driver masih memegang token "rider". Profil
// harus menukarnya, kalau tidak setiap rute driver menjawab 403.
func TestProfilMenukarTokenYangPerannyaTertinggal(t *testing.T) {
	bukaDBTes(t)
	const phone = "+62800000211"
	penggunaUji(t, phone)
	if _, err := db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1 WHERE phone_number = ?", phone); err != nil {
		t.Fatalf("gagal menjadikan pengguna uji driver: %v", err)
	}

	tokenDari := func(tok string) string {
		req := httptest.NewRequest(http.MethodGet, "/api/users/profile", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		rec := httptest.NewRecorder()
		profileHandler(rec, req)
		if rec.Code != 200 {
			t.Fatalf("profil dapat HTTP %d: %s", rec.Code, rec.Body.String())
		}
		var body struct {
			Token string `json:"token"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &body)
		return body.Token
	}

	lama, _ := issueToken(phone, "rider")
	baru := tokenDari(lama)
	if baru == "" {
		t.Fatal("token berperan rider tidak ditukar padahal akunnya sudah driver")
	}
	cek := httptest.NewRequest(http.MethodGet, "/", nil)
	cek.Header.Set("Authorization", "Bearer "+baru)
	if _, peran, ok := parseBearer(cek); !ok || peran != "driver" {
		t.Fatalf("token pengganti berperan %q, harusnya driver", peran)
	}
	if tokenDari(baru) != "" {
		t.Fatal("token yang perannya sudah cocok tidak perlu ditukar lagi")
	}
}
