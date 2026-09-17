package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

// Body kosong dari aplikasi lama harus tetap sah; foto dari alamat luar tidak.
func TestBacaBuktiSerah(t *testing.T) {
	for _, k := range []struct {
		nama, body  string
		ok          bool
		foto, nama2 string
	}{
		{"body kosong (aplikasi lama)", "", true, "", ""},
		{"foto hasil unggahan", `{"photo_url":" /uploads/f_1.jpg ","received_by":" Bu Ani "}`, true, "/uploads/f_1.jpg", "Bu Ani"},
		{"nama saja tanpa foto", `{"received_by":"Pak Budi"}`, true, "", "Pak Budi"},
		{"foto dari luar", `{"photo_url":"https://evil.example/x.jpg"}`, false, "", ""},
		{"path traversal", `{"photo_url":"/uploads/../../etc/passwd"}`, false, "", ""},
		{"json rusak", `{"photo_url":`, false, "", ""},
	} {
		r := httptest.NewRequest("POST", "/api/orders/x/pickup", strings.NewReader(k.body))
		b, ok := bacaBuktiSerah(r)
		if ok != k.ok {
			t.Errorf("%s: ok=%v, mau %v", k.nama, ok, k.ok)
			continue
		}
		if ok && (b.PhotoURL != k.foto || b.ReceivedBy != k.nama2) {
			t.Errorf("%s: dapat %+v, mau foto=%q nama=%q", k.nama, b, k.foto, k.nama2)
		}
	}
}
