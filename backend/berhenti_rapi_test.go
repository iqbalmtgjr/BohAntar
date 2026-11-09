package main

import (
	"io"
	"net"
	"net/http"
	"os"
	"testing"
	"time"
)

// Sinyal berhenti tidak boleh memotong permintaan yang sedang diproses (driver
// yang sedang menekan Selesai), tapi koneksi baru harus langsung ditolak supaya
// semuanya jatuh ke binary baru.
func TestBerhentiRapiMenuntaskanPermintaan(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mulai := make(chan struct{})
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(mulai)
		time.Sleep(400 * time.Millisecond)
		io.WriteString(w, "selesai")
	})}
	henti := make(chan os.Signal, 1)
	hasilLayani := make(chan error, 1)
	go func() { hasilLayani <- layaniSampaiBerhenti(srv, ln, henti) }()

	balasan := make(chan string, 1)
	go func() {
		res, err := http.Get("http://" + ln.Addr().String())
		if err != nil {
			balasan <- "galat: " + err.Error()
			return
		}
		b, _ := io.ReadAll(res.Body)
		res.Body.Close()
		balasan <- string(b)
	}()
	<-mulai
	henti <- os.Interrupt

	if b := <-balasan; b != "selesai" {
		t.Fatalf("permintaan yang sedang berjalan harus dituntaskan, dapat %q", b)
	}
	select {
	case err := <-hasilLayani:
		if err != nil {
			t.Fatalf("berhenti rapi harus tanpa galat: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server tidak berhenti setelah permintaan terakhir selesai")
	}
	if c, err := net.DialTimeout("tcp", ln.Addr().String(), time.Second); err == nil {
		c.Close()
		t.Fatal("setelah berhenti, koneksi baru harus ditolak")
	}
}
