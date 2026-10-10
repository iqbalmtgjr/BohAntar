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
		{"dua menu", []itemPesanan{{MenuID: "soto", Qty: 2}, {MenuID: "teh", Qty: 1}}, 41000, 2, ""},
		{"menu sama dua kali digabung", []itemPesanan{{MenuID: "soto", Qty: 1}, {MenuID: "soto", Qty: 2}}, 54000, 1, ""},
		{"keranjang kosong", nil, 0, 0, "Keranjang masih kosong"},
		{"menu tidak dikenal", []itemPesanan{{MenuID: "pizza", Qty: 1}}, 0, 0, "Ada menu yang sudah tidak dijual warung ini"},
		{"menu habis", []itemPesanan{{MenuID: "rendang", Qty: 1}}, 0, 0, "Rendang sedang habis"},
		{"porsi nol", []itemPesanan{{MenuID: "soto", Qty: 0}}, 0, 0, "Jumlah porsi tidak masuk akal"},
		{"porsi kebanyakan lewat penggabungan", []itemPesanan{{MenuID: "soto", Qty: 30}, {MenuID: "soto", Qty: 30}}, 0, 0, "Jumlah porsi tidak masuk akal"},
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
	items, _, _ := susunItemMakanan([]itemPesanan{{MenuID: "soto", Qty: 3}}, menu)
	if items[0].Price != 18000 || items[0].Qty != 3 || items[0].Name != "Soto Ayam" {
		t.Errorf("item tersalin salah: %+v", items[0])
	}
}

// Aturan varian harus sama dengan kasir Kasvo, karena driver memesan di kasir
// itu: pesanan yang lolos di sini tapi ditolak kasir membuat driver bingung di
// depan etalase.
func TestPilihOpsiIkutAturanKasvo(t *testing.T) {
	kopi := FoodMenu{ID: "kopi", Name: "Kopi Susu", Price: 15000, IsAvailable: true, OptionGroups: []GrupOpsi{
		{ID: "1", Name: "Suhu", Type: "single", Required: true, Options: []OpsiMenu{{ID: "panas", Name: "Panas"}, {ID: "dingin", Name: "Dingin", Price: 2000}}},
		{ID: "2", Name: "Topping", Type: "multiple", Max: 2, Options: []OpsiMenu{{ID: "boba", Name: "Boba", Price: 3000}, {ID: "keju", Name: "Keju", Price: 4000}, {ID: "oreo", Name: "Oreo", Price: 3000}}},
		{ID: "3", Name: "Gula", Type: "multiple", Required: true, Min: 2, Options: []OpsiMenu{{ID: "aren", Name: "Aren"}, {ID: "putih", Name: "Putih"}, {ID: "madu", Name: "Madu", Price: 1000}}},
	}}
	for _, k := range []struct {
		nama     string
		pilih    []string
		tambahan float64
		galat    string
	}{
		{"lengkap", []string{"dingin", "boba", "aren", "madu"}, 6000, ""},
		{"grup wajib kosong", []string{"aren", "putih"}, 0, "Pilih Suhu untuk Kopi Susu"},
		{"single dua pilihan", []string{"panas", "dingin", "aren", "putih"}, 0, "Pilih satu saja untuk Suhu"},
		{"multiple wajib di bawah min", []string{"panas", "aren"}, 0, "Pilih Gula untuk Kopi Susu"},
		{"multiple melewati max", []string{"panas", "boba", "keju", "oreo", "aren", "putih"}, 0, "Topping paling banyak 2 pilihan"},
		{"varian karangan", []string{"panas", "aren", "putih", "emas"}, 0, "Ada varian Kopi Susu yang sudah tidak tersedia"},
		{"varian dikirim dua kali", []string{"panas", "panas", "aren", "putih"}, 0, "Pilihan varian Kopi Susu tidak sah"},
	} {
		opsi, tambahan, galat := pilihOpsi(kopi, k.pilih)
		if galat != k.galat {
			t.Errorf("%s: galat %q, mau %q", k.nama, galat, k.galat)
			continue
		}
		if galat == "" && (tambahan != k.tambahan || len(opsi) != len(k.pilih)) {
			t.Errorf("%s: tambahan %v (%d opsi), mau %v (%d opsi)", k.nama, tambahan, len(opsi), k.tambahan, len(k.pilih))
		}
	}

	// Menu tanpa varian menolak varian apa pun.
	if _, _, galat := pilihOpsi(FoodMenu{Name: "Soto"}, []string{"x"}); galat == "" {
		t.Error("menu tanpa varian menerima varian")
	}
}

// Menu yang sama dengan varian berbeda adalah dua baris dengan harga sendiri;
// varian yang sama digabung, apa pun urutan kirimannya.
func TestSusunItemMakananDenganVarian(t *testing.T) {
	teh := FoodMenu{ID: "teh", Name: "Es Teh", Price: 5000, IsAvailable: true, OptionGroups: []GrupOpsi{
		{ID: "1", Name: "Rasa", Type: "single", Required: true, Options: []OpsiMenu{{ID: "manis", Name: "Manis"}, {ID: "lemon", Name: "Lemon", Price: 2000}}},
		{ID: "2", Name: "Ekstra", Type: "multiple", Options: []OpsiMenu{{ID: "es", Name: "Es banyak"}, {ID: "jelly", Name: "Jelly", Price: 1000}}},
	}}
	items, total, galat := susunItemMakanan([]itemPesanan{
		{MenuID: "teh", Qty: 1, Options: []string{"manis"}},
		{MenuID: "teh", Qty: 2, Options: []string{"lemon", "jelly"}},
		{MenuID: "teh", Qty: 1, Options: []string{"jelly", "lemon"}},
	}, []FoodMenu{teh})
	if galat != "" {
		t.Fatalf("pesanan sah ditolak: %s", galat)
	}
	if len(items) != 2 || total != 5000+3*8000 {
		t.Fatalf("hasil %d baris total %v, mau 2 baris total %v: %+v", len(items), total, 5000+3*8000, items)
	}
	if b := items[1]; b.Price != 8000 || b.Qty != 3 || len(b.Options) != 2 || b.Options[0].Group != "Rasa" {
		t.Errorf("baris varian tersalin salah: %+v", b)
	}
	if _, _, galat := susunItemMakanan([]itemPesanan{{MenuID: "teh", Qty: 1}}, []FoodMenu{teh}); galat != "Pilih Rasa untuk Es Teh" {
		t.Errorf("varian wajib yang tidak dipilih lolos: %q", galat)
	}
}
