package main

import "testing"

// Harga pesanan makanan harus datang dari menu warung, bukan dari aplikasi, dan
// menu yang habis atau tidak dikenal tidak boleh lolos jadi pesanan.
func TestSusunItemMakanan(t *testing.T) {
	menu := []FoodMenu{
		{ID: "soto", Name: "Soto Ayam", Price: 18000, IsAvailable: true},
		{ID: "teh", Name: "Es Teh", Price: 5000, IsAvailable: true},
		{ID: "rendang", Name: "Rendang", Price: 30000, IsAvailable: false},
	}
	for _, k := range []struct {
		nama    string
		diminta []itemPesanan
		total   float64
		jumlah  int    // jenis menu di hasil
		galat   string // "" berarti harus lolos
	}{
		{"dua menu", []itemPesanan{{"soto", 2}, {"teh", 1}}, 41000, 2, ""},
		{"menu sama dua kali digabung", []itemPesanan{{"soto", 1}, {"soto", 2}}, 54000, 1, ""},
		{"keranjang kosong", nil, 0, 0, "Keranjang masih kosong"},
		{"menu tidak dikenal", []itemPesanan{{"pizza", 1}}, 0, 0, "Ada menu yang sudah tidak dijual warung ini"},
		{"menu habis", []itemPesanan{{"rendang", 1}}, 0, 0, "Rendang sedang habis"},
		{"porsi nol", []itemPesanan{{"soto", 0}}, 0, 0, "Jumlah porsi tidak masuk akal"},
		{"porsi kebanyakan lewat penggabungan", []itemPesanan{{"soto", 30}, {"soto", 30}}, 0, 0, "Jumlah porsi tidak masuk akal"},
	} {
		items, total, galat := susunItemMakanan(k.diminta, menu)
		if galat != k.galat {
			t.Errorf("%s: galat %q, mau %q", k.nama, galat, k.galat)
			continue
		}
		if galat != "" {
			continue
		}
		if total != k.total || len(items) != k.jumlah {
			t.Errorf("%s: total %v (%d jenis), mau %v (%d jenis)", k.nama, total, len(items), k.total, k.jumlah)
		}
	}

	// Harga yang tersimpan harus harga menu, bukan angka lain.
	items, _, _ := susunItemMakanan([]itemPesanan{{"soto", 3}}, menu)
	if items[0].Price != 18000 || items[0].Qty != 3 || items[0].Name != "Soto Ayam" {
		t.Errorf("item tersalin salah: %+v", items[0])
	}
}
