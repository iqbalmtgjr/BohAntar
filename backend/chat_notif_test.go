package main

import (
	"slices"
	"testing"
)

// Aturan penerima notifikasi chat pendek, tapi dua kesalahannya sama-sama tidak
// terlihat di layar mana pun: notifikasi yang balik ke pengirimnya sendiri, dan
// notifikasi yang berdengung di tangan orang yang sedang membaca pesannya.

func TestPenerimaChat(t *testing.T) {
	pesanan := Order{RiderPhone: "0811", DriverPhone: "0822"}

	kasus := []struct {
		nama     string
		order    Order
		pengirim string
		terbuka  map[string]bool
		mau      []string
	}{
		{
			nama:     "driver kirim, penumpang tidak membuka chat",
			order:    pesanan,
			pengirim: "0822",
			mau:      []string{"0811"},
		},
		{
			nama:     "penumpang kirim, driver tidak membuka chat",
			order:    pesanan,
			pengirim: "0811",
			mau:      []string{"0822"},
		},
		{
			nama:     "penerima sedang membuka chat, WebSocket sudah menyampaikan",
			order:    pesanan,
			pengirim: "0822",
			terbuka:  map[string]bool{"0811": true, "0822": true},
			mau:      []string{},
		},
		{
			nama:     "pesanan belum punya driver",
			order:    Order{RiderPhone: "0811"},
			pengirim: "0811",
			mau:      []string{},
		},
		{
			nama:     "admin menyapa, keduanya diberi tahu",
			order:    pesanan,
			pengirim: "0899",
			mau:      []string{"0811", "0822"},
		},
	}

	for _, k := range kasus {
		got := penerimaChat(k.order, k.pengirim, k.terbuka)
		if !slices.Equal(got, k.mau) {
			t.Errorf("%s: dapat %v, mau %v", k.nama, got, k.mau)
		}
		if slices.Contains(got, k.pengirim) {
			t.Errorf("%s: notifikasi dikirim balik ke pengirimnya sendiri", k.nama)
		}
	}
}
