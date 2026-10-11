package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Potongan tagihan QR wajib masuk laporan bagi hasil sebelum super admin
// mengisi persen TagihanQR > 0 — kalau tidak, pendapatannya ada di saldo tapi
// tidak tercatat di mana pun. Rentang 2001 dipakai supaya data lokal lain tidak
// ikut terhitung.
func TestLaporanBagiHasilMemuatTagihanQR(t *testing.T) {
	bukaDBTes(t)
	waktu := func(s string) time.Time { w, _ := time.ParseInLocation("2006-01-02 15:04", s, time.Local); return w }
	tagihan := []struct {
		id      string
		jumlah  float64
		komisi  float64
		dibayar interface{}
	}{
		{newID("tagih"), 50000, 1500, waktu("2001-01-15 12:00")}, // dihitung
		{newID("tagih"), 80000, 2400, nil},                       // tidak pernah dibayar
		{newID("tagih"), 30000, 900, waktu("2001-02-01 00:00")},  // di luar rentang
	}
	for _, x := range tagihan {
		if _, err := db.Exec(`INSERT INTO tagihan_qr (id, penerima_phone, penerima_nama, amount, komisi, created_at, expires_at, paid_at)
			VALUES (?, '+62800000096', 'Warung Uji', ?, ?, ?, ?, ?)`, x.id, x.jumlah, x.komisi, waktu("2001-01-15 11:55"), waktu("2001-01-15 12:10"), x.dibayar); err != nil {
			t.Fatalf("gagal menyiapkan tagihan uji: %v", err)
		}
		id := x.id
		t.Cleanup(func() { db.Exec("DELETE FROM tagihan_qr WHERE id = ?", id) })
	}

	w := httptest.NewRecorder()
	adminKomisiHandler(w, httptest.NewRequest(http.MethodGet, "/api/admin/komisi?from=2001-01-01&to=2001-01-31", nil))
	if w.Code != 200 {
		t.Fatalf("laporan gagal: %d %s", w.Code, w.Body.String())
	}
	var lap struct {
		TotalPendapatan    float64          `json:"total_pendapatan"`
		KomisiWallet       float64          `json:"komisi_wallet"`
		TotalKomisiTagihan float64          `json:"total_komisi_tagihan"`
		TotalTagihan       float64          `json:"total_tagihan"`
		TagihanQR          []barisTagihanQR `json:"tagihan_qr"`
	}
	json.Unmarshal(w.Body.Bytes(), &lap)
	if lap.TotalKomisiTagihan != 1500 || lap.TotalTagihan != 50000 || len(lap.TagihanQR) != 1 || lap.TagihanQR[0].Jumlah != 1 {
		t.Fatalf("hanya tagihan yang dibayar di rentang yang dihitung: %+v", lap)
	}
	if lap.TotalPendapatan != 1500 || lap.KomisiWallet != 1500 {
		t.Fatalf("potongan tagihan harus masuk pendapatan dan golongan dompet: %+v", lap)
	}
}
