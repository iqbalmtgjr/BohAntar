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
// Tiap driver ditawari jemputan terdekatnya, jadi driver yang berjauhan tidak
// berebut kartu yang sama. Dalam kilometer yang sama, yang lama menunggu menang.
func TestUrutPapanOrderTerdekatLaluTerlama(t *testing.T) {
	const lat, lng = 0.07, 111.5 // ±1 derajat lintang = 111 km
	pesanan := func() []Order {
		return []Order{ // urutan dari database: terbaru dulu
			{ID: "dekat-baru", PickupLat: lat + 0.0036, PickupLng: lng, CreatedAt: "2026-11-09 10:05:00"},
			{ID: "dekat-lama", PickupLat: lat + 0.0072, PickupLng: lng, CreatedAt: "2026-11-09 10:03:00"},
			{ID: "jauh-terlama", PickupLat: lat + 0.0288, PickupLng: lng, CreatedAt: "2026-11-09 10:00:00"},
		}
	}
	cek := func(nama string, o []Order, mau ...string) {
		t.Helper()
		for i, id := range mau {
			if o[i].ID != id {
				t.Errorf("%s: urutan ke-%d %s, mau %s", nama, i+1, o[i].ID, id)
			}
		}
	}

	o := pesanan()
	urutPapanOrder(o, lat, lng, true)
	cek("driver berposisi", o, "dekat-lama", "dekat-baru", "jauh-terlama")

	o = pesanan()
	urutPapanOrder(o, 0, 0, false)
	cek("driver tanpa posisi", o, "jauh-terlama", "dekat-lama", "dekat-baru")
}

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
