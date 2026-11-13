package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Admin boleh masuk ke akun mitra (token berperan mitra), tapi tidak ke akun
// penumpang/driver/admin, dan hanya lewat token admin.
func TestMasukSebagaiMitra(t *testing.T) {
	bukaDBTes(t)

	akhir := time.Now().Format("150405")
	mitra, penumpang := "+62891"+akhir, "+62892"+akhir
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number IN (?, ?)", mitra, penumpang) })
	for p, role := range map[string]string{mitra: "food_merchant", penumpang: "rider"} {
		if err := dbSaveUser(User{PhoneNumber: p, Name: "Uji", Role: role, CreatedAt: time.Now().Format(time.RFC3339)}); err != nil {
			t.Fatal(err)
		}
	}

	adminTok := tokenAdminUji(t, "+62893"+akhir)
	masuk := func(tok, phone string) *httptest.ResponseRecorder {
		b, _ := json.Marshal(map[string]string{"phone": phone})
		r := httptest.NewRequest(http.MethodPost, "/api/admin/masuk-sebagai", bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		requireRole("admin")(adminMasukSebagaiHandler)(w, r)
		return w
	}

	w := masuk(adminTok, mitra)
	if w.Code != 200 {
		t.Fatalf("admin gagal masuk ke akun mitra: %d %s", w.Code, w.Body.String())
	}
	var hasil struct{ Token string }
	json.Unmarshal(w.Body.Bytes(), &hasil)
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Authorization", "Bearer "+hasil.Token)
	if phone, role, ok := parseBearer(r); !ok || phone != mitra || role != "food_merchant" {
		t.Fatalf("token bukan milik mitra: %q %q %v", phone, role, ok)
	}

	if w := masuk(adminTok, penumpang); w.Code != 403 {
		t.Fatalf("admin bisa masuk ke akun penumpang: %d", w.Code)
	}
	mitraTok, _ := issueToken(mitra, "food_merchant")
	if w := masuk(mitraTok, mitra); w.Code != 403 {
		t.Fatalf("non-admin bisa memakai masuk-sebagai: %d", w.Code)
	}
}
