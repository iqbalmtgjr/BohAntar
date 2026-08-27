package main

import "testing"

func TestStatusLunas(t *testing.T) {
	lunas := []string{"PAID", "SETTLED", "paid", "settled", " PAID "}
	for _, s := range lunas {
		if !statusLunas(s) {
			t.Errorf("statusLunas(%q) = false, seharusnya true", s)
		}
	}

	// EXPIRED dan PENDING tidak boleh mengaktifkan langganan.
	tidak := []string{"EXPIRED", "PENDING", "FAILED", "", "PAIDX"}
	for _, s := range tidak {
		if statusLunas(s) {
			t.Errorf("statusLunas(%q) = true, seharusnya false", s)
		}
	}
}

func TestNominalDibayar(t *testing.T) {
	// Inti bug yang diperbaiki: kalau paid_amount ada, dialah yang dipakai,
	// bukan amount. Kurang bayar 50.000 dari tagihan 100.000 harus terlihat.
	if got := nominalDibayar(50000, 100000); got != 50000 {
		t.Errorf("nominalDibayar(50000, 100000) = %.0f, mau 50000", got)
	}

	// paid_amount tidak dikirim (jalur mock lokal): jatuh ke amount, bukan nol,
	// supaya pembayaran yang sah tidak ikut tertolak.
	if got := nominalDibayar(0, 100000); got != 100000 {
		t.Errorf("nominalDibayar(0, 100000) = %.0f, mau 100000", got)
	}

	// Dua-duanya kosong: nol, dan pemeriksaan `dibayar > 0` di pemanggil yang
	// memutuskan untuk melewatkannya, bukan menolak.
	if got := nominalDibayar(0, 0); got != 0 {
		t.Errorf("nominalDibayar(0, 0) = %.0f, mau 0", got)
	}
}
