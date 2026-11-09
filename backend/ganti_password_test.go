package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Aplikasi kini punya tombol ganti password (driver menerima password awal
// yang cuma ditampilkan sekali). Yang dijaga: tanpa password lama yang benar,
// sesi yang dibajak tidak boleh bisa mengunci pemilik akun.
func TestGantiPasswordDariAplikasi(t *testing.T) {
	bukaDBTes(t)
	phone := "+62800000095"
	penggunaUji(t, phone)
	if err := dbSetPassword(phone, "rahasia-lama"); err != nil {
		t.Fatalf("gagal menyiapkan password: %v", err)
	}

	ganti := func(isi string) int {
		r := httptest.NewRequest(http.MethodPut, "/api/users/profile", strings.NewReader(isi))
		r.Header.Set("Authorization", "Bearer "+tokenUji(t, phone))
		w := httptest.NewRecorder()
		profileHandler(w, r)
		return w.Code
	}
	hashSekarang := func() string {
		var h string
		db.QueryRow("SELECT COALESCE(password, '') FROM users WHERE phone_number = ?", phone).Scan(&h)
		return h
	}

	if k := ganti(`{"current_password":"salah","new_password":"rahasia-baru"}`); k != 401 {
		t.Fatalf("password lama salah harus 401, dapat %d", k)
	}
	if k := ganti(`{"current_password":"rahasia-lama","new_password":"pendek"}`); k != 400 {
		t.Fatalf("password baru < 8 harus 400, dapat %d", k)
	}
	if !checkPassword(hashSekarang(), "rahasia-lama") {
		t.Fatal("permintaan yang ditolak ternyata tetap mengubah password")
	}
	if k := ganti(`{"current_password":"rahasia-lama","new_password":"rahasia-baru"}`); k != 200 {
		t.Fatalf("ganti password sah harus 200, dapat %d", k)
	}
	if h := hashSekarang(); !checkPassword(h, "rahasia-baru") || checkPassword(h, "rahasia-lama") {
		t.Fatal("password baru tidak berlaku atau password lama masih berlaku")
	}
}

// Rekening pembayaran mitra rental (dicetak di invoice) disimpan lewat Akun
// Saya; nomor rekening hanya angka, dan permintaan lain tidak ikut menghapusnya.
func TestRekeningPembayaranDiProfil(t *testing.T) {
	bukaDBTes(t)
	migrasiRekening()
	phone := "+62800000096"
	penggunaUji(t, phone)

	kirim := func(method, isi string) (int, string) {
		r := httptest.NewRequest(method, "/api/users/profile", strings.NewReader(isi))
		r.Header.Set("Authorization", "Bearer "+tokenUji(t, phone))
		w := httptest.NewRecorder()
		profileHandler(w, r)
		return w.Code, w.Body.String()
	}

	if k, _ := kirim(http.MethodPut, `{"rek_nomor":"12ab"}`); k != 400 {
		t.Fatalf("nomor rekening berhuruf harus 400, dapat %d", k)
	}
	if k, b := kirim(http.MethodPut, `{"rek_nama":" RBA Transport ","rek_bank":"BRI","rek_nomor":"0123-01-000123-30-1"}`); k != 200 {
		t.Fatalf("simpan rekening gagal: %d %s", k, b)
	}
	// Ganti nama saja tidak boleh mengosongkan rekening.
	kirim(http.MethodPut, `{"name":"Uji Rekening"}`)
	_, b := kirim(http.MethodGet, "")
	for _, mau := range []string{`"rek_nama":"RBA Transport"`, `"rek_bank":"BRI"`, `"rek_nomor":"0123-01-000123-30-1"`} {
		if !strings.Contains(b, mau) {
			t.Errorf("profil tidak memuat %s: %s", mau, b)
		}
	}
}
