package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// BohFood yang sudah dapat driver tidak bisa dibatalkan langsung: penumpang
// mengajukan, driver menyetujui atau menolak (makanan bisa sudah dibeli).
func TestPengajuanBatalBohFood(t *testing.T) {
	bukaDBTes(t)
	const driver, penumpang = "+62800000230", "+62800000231"
	penggunaUji(t, driver)
	db.Exec("UPDATE users SET role = 'driver', is_driver_active = 1 WHERE phone_number = ?", driver)

	pesananMakananBaru := func() string {
		t.Helper()
		oid := pesananUji(t, penumpang, "cash", "pending", 10000)
		db.Exec("UPDATE orders SET service = 'BohFood', merchant_name = 'Warung Uji' WHERE id = ?", oid)
		if menang, err := dbClaimOrder(oid, driver, "Driver Uji", time.Now().Format(time.RFC3339)); err != nil || !menang {
			t.Fatalf("gagal menyiapkan pesanan diterima: %v", err)
		}
		return oid
	}
	kirim := func(fungsi func(http.ResponseWriter, *http.Request, string), oid, hp, peran, badan string) int {
		t.Helper()
		tok, _ := issueToken(hp, peran)
		req := httptest.NewRequest(http.MethodPost, "/api/orders/"+oid+"/x", strings.NewReader(badan))
		req.Header.Set("Authorization", "Bearer "+tok)
		rec := httptest.NewRecorder()
		fungsi(rec, req, oid)
		return rec.Code
	}
	setuju := func(w http.ResponseWriter, r *http.Request, id string) { jawabBatalOrder(w, r, id, true) }
	tolak := func(w http.ResponseWriter, r *http.Request, id string) { jawabBatalOrder(w, r, id, false) }

	oid := pesananMakananBaru()
	// Batal langsung ditolak (aplikasi lama tidak boleh mengira sudah batal).
	if c := kirim(cancelOrder, oid, penumpang, "rider", `{"alasan":"Berubah pikiran"}`); c != 409 {
		t.Fatalf("batal langsung BohFood diterima: HTTP %d", c)
	}
	if c := kirim(mintaBatalOrder, oid, penumpang, "rider", ""); c != 400 {
		t.Fatalf("pengajuan tanpa alasan: HTTP %d, mau 400", c)
	}
	if c := kirim(mintaBatalOrder, oid, penumpang, "rider", `{"alasan":"Berubah pikiran"}`); c != 200 {
		t.Fatalf("ajukan batal: HTTP %d", c)
	}
	if c := kirim(mintaBatalOrder, oid, penumpang, "rider", `{"alasan":"Berubah pikiran"}`); c != 409 {
		t.Fatalf("pengajuan ganda: HTTP %d, mau 409", c)
	}
	if o, _ := dbGetOrder(oid); o.MintaBatalAt == "" || o.Status != "accepted" {
		t.Fatalf("setelah diajukan: status %q minta %q", o.Status, o.MintaBatalAt)
	}

	// Driver menolak: wajib beralasan, pesanan berjalan terus.
	if c := kirim(tolak, oid, driver, "driver", ""); c != 400 {
		t.Fatalf("tolak tanpa alasan: HTTP %d, mau 400", c)
	}
	if c := kirim(tolak, oid, driver, "driver", `{"alasan":"Makanan sudah dibeli"}`); c != 200 {
		t.Fatalf("tolak: HTTP %d", c)
	}
	if o, _ := dbGetOrder(oid); o.Status != "accepted" || o.MintaBatalAt != "" || o.TolakBatal != "Makanan sudah dibeli" {
		t.Fatalf("setelah ditolak: status %q minta %q tolak %q", o.Status, o.MintaBatalAt, o.TolakBatal)
	}

	// Diajukan lagi lalu disetujui: batal, tercatat atas persetujuan driver.
	kirim(mintaBatalOrder, oid, penumpang, "rider", `{"alasan":"Salah pilih menu"}`)
	if c := kirim(setuju, oid, driver, "driver", ""); c != 200 {
		t.Fatalf("setujui: HTTP %d", c)
	}
	if o, _ := dbGetOrder(oid); o.Status != "cancelled" || o.AlasanBatal != "Salah pilih menu (disetujui driver)" {
		t.Fatalf("setelah disetujui: status %q alasan %q", o.Status, o.AlasanBatal)
	}

	// Pengajuan yang belum dijawab gugur begitu makanan diambil.
	oid2 := pesananMakananBaru()
	kirim(mintaBatalOrder, oid2, penumpang, "rider", `{"alasan":"Berubah pikiran"}`)
	if c := kirim(pickupOrder, oid2, driver, "driver", ""); c != 200 {
		t.Fatalf("ambil makanan: HTTP %d", c)
	}
	if o, _ := dbGetOrder(oid2); o.Status != "picked_up" || o.MintaBatalAt != "" {
		t.Fatalf("setelah diambil: status %q minta %q", o.Status, o.MintaBatalAt)
	}
	if c := kirim(mintaBatalOrder, oid2, penumpang, "rider", `{"alasan":"Berubah pikiran"}`); c != 409 {
		t.Fatalf("ajukan setelah makanan dibawa: HTTP %d, mau 409", c)
	}
}
