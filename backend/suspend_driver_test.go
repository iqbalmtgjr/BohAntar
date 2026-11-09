package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Admin menonaktifkan (suspend) driver yang melanggar lalu mengaktifkannya lagi.
func TestSuspendDriverOlehAdmin(t *testing.T) {
	bukaDBTes(t)
	const driver = "+62800000220"
	penggunaUji(t, driver)
	db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1, alasan_nonaktif = '' WHERE phone_number = ?", driver)

	ubah := func(hp, badan string) *httptest.ResponseRecorder {
		t.Helper()
		rec := httptest.NewRecorder()
		adminUserDetailHandler(rec, httptest.NewRequest(http.MethodPut, "/api/admin/users/"+strings.TrimPrefix(hp, "+"), strings.NewReader(badan)))
		return rec
	}
	status := func(hp string) (bool, string) {
		t.Helper()
		var aktif bool
		var alasan string
		db.QueryRow("SELECT is_driver_active, alasan_nonaktif FROM users WHERE phone_number = ?", hp).Scan(&aktif, &alasan)
		return aktif, alasan
	}

	// Tanpa alasan ditolak: driver berhak tahu kenapa.
	if w := ubah(driver, `{"is_driver_active":false}`); w.Code != 400 {
		t.Fatalf("nonaktif tanpa alasan: HTTP %d, mau 400", w.Code)
	}
	if w := ubah(driver, `{"is_driver_active":false,"alasan_nonaktif":"  Menagih ongkos di atas tarif "}`); w.Code != 200 {
		t.Fatalf("nonaktifkan: HTTP %d %s", w.Code, w.Body)
	}
	if aktif, alasan := status(driver); aktif || alasan != "Menagih ongkos di atas tarif" {
		t.Fatalf("setelah dinonaktifkan: aktif=%v alasan=%q", aktif, alasan)
	}

	// Driver yang disuspend ditolak menerima orderan, dan diberi tahu alasannya.
	oid := pesananUji(t, "+62800000221", "cash", "pending", 10000)
	req := httptest.NewRequest(http.MethodPost, "/api/orders/"+oid+"/accept", nil)
	req.Header.Set("Authorization", "Bearer "+tokenUji(t, driver))
	rec := httptest.NewRecorder()
	acceptOrder(rec, req, oid)
	if rec.Code != 403 || !strings.Contains(rec.Body.String(), "Menagih ongkos di atas tarif") {
		t.Fatalf("driver nonaktif menerima orderan: HTTP %d %s", rec.Code, rec.Body)
	}
	// Aplikasi membaca alasannya dari profil.
	req = httptest.NewRequest(http.MethodGet, "/api/users/profile", nil)
	req.Header.Set("Authorization", "Bearer "+tokenUji(t, driver))
	rec = httptest.NewRecorder()
	profileHandler(rec, req)
	var profil map[string]any
	json.Unmarshal(rec.Body.Bytes(), &profil)
	if profil["alasan_nonaktif"] != "Menagih ongkos di atas tarif" {
		t.Fatalf("profil tidak membawa alasan nonaktif: %s", rec.Body)
	}

	// Diaktifkan lagi: alasannya dibersihkan.
	if w := ubah(driver, `{"is_driver_active":true}`); w.Code != 200 {
		t.Fatalf("aktifkan: HTTP %d %s", w.Code, w.Body)
	}
	if aktif, alasan := status(driver); !aktif || alasan != "" {
		t.Fatalf("setelah diaktifkan: aktif=%v alasan=%q", aktif, alasan)
	}

	// Pengaju yang masih ditinjau tidak bisa diaktifkan dari sini (melewati
	// peninjauan dokumen); penumpang tidak punya status driver sama sekali.
	const pengaju = "+62800000222"
	penggunaUji(t, pengaju)
	db.Exec("UPDATE users SET role = 'driver', is_driver_active = 0 WHERE phone_number = ?", pengaju)
	if err := dbSaveApplication(DriverApplication{ID: newID("app"), PhoneNumber: pengaju, Name: "Uji", Status: "pending", CreatedAt: time.Now().Format(time.RFC3339)}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM driver_applications WHERE phone_number = ?", pengaju) })
	if w := ubah(pengaju, `{"is_driver_active":true}`); w.Code != 409 {
		t.Fatalf("aktifkan pengaju pending: HTTP %d, mau 409", w.Code)
	}
	const penumpang = "+62800000223"
	penggunaUji(t, penumpang)
	if w := ubah(penumpang, `{"is_driver_active":true}`); w.Code != 400 {
		t.Fatalf("aktifkan status driver penumpang: HTTP %d, mau 400", w.Code)
	}

	// Dijadikan driver lewat form Edit = langsung aktif (penyebab akun admin
	// sendiri "sedang dinonaktifkan" padahal tidak pernah disuspend).
	if w := ubah(penumpang, `{"role":"driver"}`); w.Code != 200 {
		t.Fatalf("ganti peran: HTTP %d %s", w.Code, w.Body)
	}
	if aktif, _ := status(penumpang); !aktif {
		t.Fatal("penumpang yang dijadikan driver oleh admin masih nonaktif")
	}
}
