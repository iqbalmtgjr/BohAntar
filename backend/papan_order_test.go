package main

import "testing"

// Papan orderan driver diam-diam mati empat hari: `${apos}${apos}` — sisa
// template yang tersasar ke dalam SQL — membuat MySQL menolak seluruh kueri
// daftar pesanan dengan 1064, dan enam dari delapan pemanggilnya membuang
// error itu. Yang terlihat di HP driver hanya "Mencari Orderan Pelanggan..."
// selamanya, tanpa satu baris log pun.
//
// Kode Go-nya lolos kompilasi dengan senang hati — SQL rusak itu string yang
// sah — jadi tesnya harus menembak MySQL sungguhan, seperti
// TestSaveUserMenyimpanSungguhan yang lahir dari kecelakaan yang sama.
func TestDaftarPesananTidakDitolakDatabase(t *testing.T) {
	bukaDBTes(t)

	for _, k := range []struct {
		nama                  string
		driver, rider, status string
		page, limit           int
	}{
		{"papan order driver", "", "", "pending", 0, 0},
		{"riwayat penumpang", "", "+6289900000000", "", 0, 0},
		{"riwayat driver", "+6289900000000", "", "", 0, 0},
		{"daftar admin berhalaman", "", "", "", 1, 20},
	} {
		if _, _, err := dbGetOrders(k.driver, k.rider, k.status, k.page, k.limit); err != nil {
			t.Errorf("%s ditolak database: %v", k.nama, err)
		}
	}
}
