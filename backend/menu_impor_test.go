package main

import (
	"bytes"
	"testing"
	"time"
)

// Impor Excel: berkas yang ditulis tulisXLSX dibaca kembali bacaXLSX, kategori
// dan grup varian baru lahir otomatis, menu terpasang ke variannya, dan satu
// baris salah membatalkan semuanya.
func TestImporMenuExcel(t *testing.T) {
	// Template harus lolos pemeriksaannya sendiri (tanpa DB: merchant kosong).
	var tpl bytes.Buffer
	if err := tulisXLSX(&tpl, templateImporMenu()); err != nil {
		t.Fatal(err)
	}
	lembar, err := bacaXLSX(tpl.Bytes())
	if err != nil || len(lembar) != 3 || lembar[0].Nama != "Menu" || lembar[0].Baris[1].Sel[2] != "15000" {
		t.Fatalf("template tidak terbaca kembali: %v %+v", err, lembar)
	}
	if _, err := bacaXLSX([]byte("nama,harga\nsoto,10000")); err == nil {
		t.Fatal("CSV harus ditolak dengan pesan simpan sebagai .xlsx")
	}
	if f, ok := angkaRupiah("Rp 15.000"); !ok || f != 15000 {
		t.Fatalf("angkaRupiah(Rp 15.000) = %v", f)
	}

	bukaDBTes(t)
	pemilik := "+62800000961"
	penggunaUji(t, pemilik)
	mid := newID("merchant")
	if _, err := db.Exec(`INSERT INTO food_merchants (id, owner_phone, restaurant_name, address, is_open, created_at, lat, lng)
		VALUES (?, ?, 'Warung Impor', '', 1, ?, -0.07, 111.49)`, mid, pemilik, time.Now().Format(time.RFC3339)); err != nil {
		t.Fatalf("gagal menyiapkan warung uji: %v", err)
	}
	t.Cleanup(func() {
		db.Exec("DELETE FROM food_menu_grup WHERE grup_id IN (SELECT id FROM food_grup_opsi WHERE merchant_id = ?)", mid)
		db.Exec("DELETE FROM food_opsi WHERE grup_id IN (SELECT id FROM food_grup_opsi WHERE merchant_id = ?)", mid)
		db.Exec("DELETE FROM food_grup_opsi WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_kategori WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_menus WHERE merchant_id = ?", mid)
		db.Exec("DELETE FROM food_merchants WHERE id = ?", mid)
	})

	if h := susunImpor(mid, lembar, false); len(h.Galat) != 0 || len(h.Menu) != 4 || len(h.VarianBaru) != 3 || len(h.KategoriBaru) != 2 {
		t.Fatalf("template harus lolos tanpa galat: %+v", h)
	}

	// Satu baris salah (varian tak dikenal) → tidak ada yang tersimpan.
	salah := templateImporMenu()
	salah[0].Baris = append(salah[0].Baris, []string{"Minuman", "Kopi", "8000", "", "Gula"})
	var b bytes.Buffer
	tulisXLSX(&b, salah)
	lembarSalah, _ := bacaXLSX(b.Bytes())
	if h := susunImpor(mid, lembarSalah, false); len(h.Galat) != 1 || h.Galat[0].Baris != 6 {
		t.Fatalf("varian tak dikenal harus jadi satu galat di baris 6: %+v", h.Galat)
	}

	h := susunImpor(mid, lembar, false)
	if err := jalankanImpor(mid, &h); err != nil {
		t.Fatalf("impor gagal: %v", err)
	}
	menus, _ := dbMenuWarung(mid, true)
	if len(menus) != 4 {
		t.Fatalf("harus ada 4 menu, dapat %d", len(menus))
	}
	var mie FoodMenu
	for _, m := range menus {
		if m.Name == "Mie Goreng Spesial" {
			mie = m
		}
		if m.Name == "Jus Alpukat" && m.IsAvailable {
			t.Fatal("Jus Alpukat ditulis Habis, harus tidak tersedia")
		}
	}
	if len(mie.OptionGroups) != 2 || mie.OptionGroups[0].Name != "Level Pedas" || len(mie.OptionGroups[0].Options) != 3 || !mie.OptionGroups[0].Required {
		t.Fatalf("Mie Goreng harus punya Level Pedas (wajib, 3 pilihan) + Topping: %+v", mie.OptionGroups)
	}
	if top := mie.OptionGroups[1]; top.Type != "multiple" || top.Max != 3 || top.Required {
		t.Fatalf("Topping harus pilih beberapa, maks 3, opsional: %+v", top)
	}

	// Impor kedua: menu bernama sama dilewati, grup lama tidak diubah/digandakan.
	h2 := susunImpor(mid, lembar, false)
	if len(h2.VarianBaru) != 0 || len(h2.VarianAda) != 3 || h2.Menu[0].Aksi != "lewati" {
		t.Fatalf("impor ulang harus melewati menu & memakai grup lama: %+v", h2)
	}
	if err := jalankanImpor(mid, &h2); err != nil {
		t.Fatal(err)
	}
	if grup, _ := dbGrupWarung(mid); len(grup) != 3 {
		t.Fatalf("grup tidak boleh tergandakan, dapat %d", len(grup))
	}
}
