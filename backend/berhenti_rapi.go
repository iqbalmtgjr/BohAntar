package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"time"
)

// Ganti binary tanpa jeda (9 Nov 2026). Dulu: pkill → backend mati seketika
// (permintaan yang sedang diproses terpotong) → cron baru menyalakan yang baru
// sampai satu menit kemudian. Sekarang ganti-binary.sh menyalakan binary baru
// DULU di port yang sama (dengarPort, SO_REUSEPORT di Linux), lalu memberi yang
// lama SIGTERM. Yang lama menutup pintu untuk koneksi baru, menuntaskan
// permintaan yang sedang berjalan, lalu keluar.
//
// Uang tetap aman di kedua cara: semua perpindahan saldo ada di transaksi
// database, yang dibatalkan utuh kalau prosesnya mati di tengah. Yang hilang
// dengan cara ini adalah gangguannya — tombol Selesai yang gagal dan harus
// diulang, layar yang berputar selama satu menit.
//
// ponytail: koneksi WebSocket chat tidak ditunggu (Shutdown tidak melacak
// koneksi yang di-hijack); terputus saat proses lama keluar dan aplikasi
// menyambung ulang sendiri. Kunci di dalam proses (gerbangSaldoMu dkk.) hanya
// berlaku per proses: selama beberapa detik dua proses hidup bersamaan.

const batasTungguBerhenti = 25 * time.Second

// layaniSampaiBerhenti melayani sampai sinyal berhenti datang, lalu menunggu
// permintaan yang sedang berjalan selesai (maks batasTungguBerhenti).
func layaniSampaiBerhenti(srv *http.Server, ln net.Listener, henti <-chan os.Signal) error {
	selesai := make(chan error, 1)
	go func() {
		<-henti
		log.Println("Sinyal berhenti diterima: tidak menerima koneksi baru, menuntaskan permintaan yang sedang berjalan…")
		ctx, cancel := context.WithTimeout(context.Background(), batasTungguBerhenti)
		defer cancel()
		selesai <- srv.Shutdown(ctx)
	}()
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	if err := <-selesai; err != nil {
		log.Printf("Masih ada permintaan setelah %s, dihentikan paksa: %v", batasTungguBerhenti, err)
		return nil
	}
	log.Println("Backend berhenti dengan rapi")
	return nil
}
