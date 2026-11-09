package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Pesanan manual admin yang ditujukan ke satu driver: hanya driver itu yang
// ditawari dan boleh mengambilnya. Tanpa saringan di papan orderan dan syarat
// di klaim, pesanan telepon admin jadi rebutan seperti pesanan biasa.
func TestPesananManualHanyaUntukDriverTujuan(t *testing.T) {
	bukaDBTes(t)
	const tujuan, lain = "+62800000901", "+62800000902"
	for _, p := range []string{tujuan, lain} {
		penggunaUji(t, p)
		db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1 WHERE phone_number = ?", p)
	}

	if _, pesan := pesananManual("Budi", "0812", "BohRide", "A", "B", 0.07, 111.49, 0.08, 111.50, ""); pesan == "" {
		t.Fatal("nomor HP 4 digit seharusnya ditolak")
	}
	o, pesan := pesananManual("Budi", "0812 9999 0001", "BohRide", "Pasar", "Terminal", 0.0785, 111.494, 0.09, 111.50, tujuan)
	if pesan != "" {
		t.Fatalf("pesanan manual ditolak: %s", pesan)
	}
	if o.RiderPhone != "" || o.RiderName != "Budi · 081299990001" || o.Fare <= 0 {
		t.Fatalf("pemesan/ongkos keliru: %q %q %v", o.RiderPhone, o.RiderName, o.Fare)
	}
	if err := dbSaveOrder(o); err != nil {
		t.Fatalf("gagal menyimpan: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", o.ID) })

	papan := func(phone string) []map[string]interface{} {
		r := httptest.NewRequest(http.MethodGet, "/api/orders/active", nil)
		r = r.WithContext(context.WithValue(context.WithValue(r.Context(), ctxPhone, phone), ctxRole, "driver"))
		w := httptest.NewRecorder()
		getActiveOrdersHandler(w, r)
		var res struct{ Orders []map[string]interface{} }
		json.Unmarshal(w.Body.Bytes(), &res)
		return res.Orders
	}
	for _, m := range papan(lain) {
		if m["id"] == o.ID {
			t.Fatal("driver lain ikut ditawari pesanan yang ditujukan ke driver tujuan")
		}
	}
	if p := papan(tujuan); len(p) == 0 || p[0]["id"] != o.ID {
		t.Fatal("pesanan untuk driver tujuan harus jadi kartu pertama di papannya")
	}

	if menang, _ := dbClaimOrder(o.ID, lain, "Lain", o.CreatedAt); menang {
		t.Fatal("driver lain berhasil mengklaim pesanan yang bukan untuknya")
	}
	if menang, err := dbClaimOrder(o.ID, tujuan, "Tujuan", o.CreatedAt); err != nil || !menang {
		t.Fatalf("driver tujuan gagal mengklaim: %v", err)
	}
}
