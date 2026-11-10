package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func TestTerbilang(t *testing.T) {
	for n, mau := range map[int64]string{
		0: "nol", 11: "sebelas", 15: "lima belas", 100: "seratus", 1000: "seribu",
		1500: "seribu lima ratus", 37000: "tiga puluh tujuh ribu",
		111111:  "seratus sebelas ribu seratus sebelas",
		1250000: "satu juta dua ratus lima puluh ribu",
	} {
		if got := terbilang(n); got != mau {
			t.Errorf("terbilang(%d) = %q, mau %q", n, got, mau)
		}
	}
}

// Array [95]int yang isinya kurang tetap lolos kompilasi (sisanya nol) —
// teks rata kanan lalu bergeser diam-diam.
func TestTabelLebarHurufLengkap(t *testing.T) {
	for i := range lebarHelvetica {
		if lebarHelvetica[i] == 0 || lebarHelveticaTebal[i] == 0 {
			t.Fatalf("lebar huruf %q kosong", rune(32+i))
		}
	}
}

// PDF tulis tangan: xref harus menunjuk tepat ke tiap objek dan /Length ke
// panjang stream — pembaca PDF yang ketat menolak berkas yang melenceng.
func TestKuitansiPDFUtuh(t *testing.T) {
	o := Order{
		ID: "order-0123456789abcdef01234567", RiderName: "Budi", Service: "BohFood",
		MerchantName: "Warung Uji", PickupAddress: "Jl. Merdeka (depan masjid) \\ 🍜",
		DropoffAddress: "Kantor Bupati\nSintang", DriverName: "Joko", PaymentMethod: "cash",
		CreatedAt: "2026-11-10T14:05:00+07:00", UpdatedAt: "2026-11-10T14:32:00+07:00",
		Items: []OrderItem{
			{Name: "Nasi goreng", Price: 15000, Qty: 2, Options: []OpsiTerpilih{{Name: "Pedas"}}},
			{Name: "Es teh", Price: 5000, Qty: 1},
		},
		FoodTotal: 35000, Fare: 8000, BiayaJasa: 1000, Diskon: 7000,
	}
	pdf := kuitansiPDF(o)

	for _, mau := range []string{
		"(No. BA-20261110-01234567)", "(Total dibayar)", "(Rp37.000)", "(-Rp7.000)",
		"(Terbilang: Tiga puluh tujuh ribu rupiah)", "(2 \xd7 Nasi goreng \xb7 Pedas @ Rp15.000)",
		`(Jl. Merdeka \(depan masjid\) \\ ?)`, "(Kantor Bupati Sintang)",
		"(" + alamatPublik + jalurKuitansi(o.ID) + ")", "(10 November 2026, 14.32 WIB)",
	} {
		if !bytes.Contains(pdf, []byte(mau)) {
			t.Errorf("PDF tidak memuat %q", mau)
		}
	}
	// Logo tertanam (dekode PNG embed tidak panik) dan benar-benar digambar.
	if logo := logoKuitansi(); logo.lebar == 0 || !bytes.Contains(pdf, []byte("/Logo Do")) || !bytes.Contains(pdf, []byte("/Width 660 /Height 180")) {
		t.Error("logo tidak ada di kop kuitansi")
	}
	if n := periksaStrukturPDF(t, pdf); n != 1 {
		t.Errorf("pesanan pendek jadi %d halaman", n)
	}

	// BohFood 30 jenis menu (batas maksJenisMenu) tidak boleh keluar dari
	// kertas: bersambung ke halaman berikutnya, total dan kaki tetap tercetak.
	o.Items = nil
	for i := 1; i <= maksJenisMenu; i++ {
		o.Items = append(o.Items, OrderItem{Name: fmt.Sprintf("Menu nomor %d dengan nama yang lumayan panjang", i), Price: 1000, Qty: 1})
	}
	o.FoodTotal = float64(maksJenisMenu) * 1000
	panjang := kuitansiPDF(o)
	if n := periksaStrukturPDF(t, panjang); n < 2 {
		t.Errorf("30 menu muat di %d halaman?", n)
	}
	for _, mau := range []string{
		"(1 \xd7 Menu nomor 30 dengan nama yang lumayan panjang @ Rp1.000)", "(Total dibayar)",
		`(Kuitansi BohAntar No. BA-20261110-01234567 \(lanjutan\))`,
	} {
		if !bytes.Contains(panjang, []byte(mau)) {
			t.Errorf("PDF panjang tidak memuat %q", mau)
		}
	}
}

// periksaStrukturPDF memeriksa xref, /Length tiap stream, dan bahwa semua
// teks jatuh di dalam kertas. Membalas jumlah halaman.
func periksaStrukturPDF(t *testing.T, pdf []byte) int {
	t.Helper()
	m := regexp.MustCompile(`startxref\n(\d+)\n%%EOF\n$`).FindSubmatch(pdf)
	if !bytes.HasPrefix(pdf, []byte("%PDF-1.4\n")) || m == nil {
		t.Fatal("kepala/ekor PDF rusak")
	}
	xref, _ := strconv.Atoi(string(m[1]))
	baris := strings.Split(string(pdf[xref:]), "\n")
	var jumlah int
	fmt.Sscanf(baris[1], "0 %d", &jumlah)
	if baris[0] != "xref" || jumlah < 2 {
		t.Fatalf("startxref tidak menunjuk ke xref: %q %q", baris[0], baris[1])
	}
	for i := 1; i < jumlah; i++ {
		pos, _ := strconv.Atoi(baris[2+i][:10])
		if !bytes.HasPrefix(pdf[pos:], []byte(fmt.Sprintf("%d 0 obj\n", i))) {
			t.Errorf("xref objek %d melenceng ke %q", i, pdf[pos:pos+10])
		}
	}
	stream := regexp.MustCompile(`(?s)/Length (\d+) >>\nstream\n(.*?)\nendstream`).FindAllSubmatch(pdf, -1)
	if len(stream) < 2 {
		t.Errorf("hanya %d stream (logo + isi halaman)", len(stream))
	}
	for _, s := range stream {
		if n, _ := strconv.Atoi(string(s[1])); n != len(s[2]) {
			t.Errorf("/Length %d, isi stream %d byte", n, len(s[2]))
		}
	}
	for _, td := range regexp.MustCompile(`(-?[\d.]+) (-?[\d.]+) Td`).FindAllSubmatch(pdf, -1) {
		x, _ := strconv.ParseFloat(string(td[1]), 64)
		y, _ := strconv.ParseFloat(string(td[2]), 64)
		if x < 40 || x > 560 || y < 40 || y > 800 {
			t.Errorf("teks keluar kertas di (%v, %v)", x, y)
		}
	}
	var halaman int
	fmt.Sscanf(string(regexp.MustCompile(`/Count \d+`).Find(pdf)), "/Count %d", &halaman)
	return halaman
}

func TestAksesKuitansi(t *testing.T) {
	bukaDBTes(t)
	const pemesan, orangLain = "+62800000240", "+62800000241"
	penggunaUji(t, orangLain)
	selesai := pesananUji(t, pemesan, "cash", "completed", 11000)
	berjalan := pesananUji(t, pemesan, "cash", "accepted", 11000)
	// Pengantaran dari kasir Kasvo: akun pemesannya toko, penerimalah yang bayar.
	kasir := pesananUji(t, pemesan, "cash", "completed", 11000)
	db.Exec("UPDATE orders SET kasvo_pengantaran_id = 1 WHERE id = ?", kasir)

	minta := func(oid, hp string) (int, string) {
		t.Helper()
		tok, _ := issueToken(hp, "rider")
		req := httptest.NewRequest(http.MethodGet, "/api/orders/"+oid+"/kuitansi", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		rec := httptest.NewRecorder()
		kuitansiTautanHandler(rec, req, oid)
		var isi struct{ Path, Nomor string }
		json.Unmarshal(rec.Body.Bytes(), &isi)
		if rec.Code == 200 && !strings.HasPrefix(isi.Nomor, "BA-") {
			t.Errorf("nomor kuitansi untuk nama berkas kosong/aneh: %q", isi.Nomor)
		}
		return rec.Code, isi.Path
	}
	unduh := func(jalur string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		kuitansiPDFHandler(rec, httptest.NewRequest(http.MethodGet, jalur, nil))
		return rec
	}

	c, jalur := minta(selesai, pemesan)
	if c != 200 || jalur != jalurKuitansi(selesai) {
		t.Fatalf("pemesan minta kuitansi: HTTP %d jalur %q", c, jalur)
	}
	if rec := unduh(jalur); rec.Code != 200 || rec.Header().Get("Content-Type") != "application/pdf" || !bytes.HasPrefix(rec.Body.Bytes(), []byte("%PDF")) {
		t.Fatalf("unduh kuitansi: HTTP %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
	if c, _ := minta(selesai, orangLain); c != 404 {
		t.Errorf("orang lain minta kuitansi: HTTP %d, mau 404", c)
	}
	for _, oid := range []string{berjalan, kasir} {
		if c, _ := minta(oid, pemesan); c != 409 {
			t.Errorf("pesanan %s: HTTP %d, mau 409", oid, c)
		}
	}
	// Tanda dipalsukan, atau tanda sah untuk pesanan yang tak boleh dikuitansi.
	palsu := jalur[:len(jalur)-1] + map[bool]string{true: "1", false: "0"}[strings.HasSuffix(jalur, "0")]
	for _, j := range []string{palsu, "/api/kuitansi/" + selesai + "/", jalurKuitansi(berjalan), jalurKuitansi(kasir)} {
		if rec := unduh(j); rec.Code != 404 {
			t.Errorf("unduh %s: HTTP %d, mau 404", j, rec.Code)
		}
	}
}
