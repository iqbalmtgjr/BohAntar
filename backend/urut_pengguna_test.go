package main

import (
	"testing"
	"time"
)

// Halaman Pengguna di dashboard: akun terbaru tampil paling atas.
func TestDaftarPenggunaTerbaruDiAtas(t *testing.T) {
	bukaDBTes(t)

	akhir := time.Now().Format("150405")
	lama, baru := "+62893"+akhir, "+62894"+akhir
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number IN (?, ?)", lama, baru) })
	sekarang := time.Now().Add(time.Hour) // lebih baru dari semua akun lain di DB lokal
	for p, w := range map[string]time.Time{lama: sekarang, baru: sekarang.Add(time.Minute)} {
		if err := dbSaveUser(User{PhoneNumber: p, Name: "Uji", Role: "rider", CreatedAt: w.Format(time.RFC3339)}); err != nil {
			t.Fatal(err)
		}
	}

	users, _, err := dbGetUsers("rider", "", 1, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(users) != 2 || users[0].PhoneNumber != baru || users[1].PhoneNumber != lama {
		t.Fatalf("urutan salah, ingin %s lalu %s: %+v", baru, lama, users)
	}

	// Cari dari halaman 1 harus menemukan akun yang tampil di halaman 2,
	// juga saat nomornya diketik "08xx".
	for _, q := range []string{"0893" + akhir, "893" + akhir} {
		users, total, err := dbGetUsers("rider", q, 1, 1)
		if err != nil {
			t.Fatal(err)
		}
		if total != 1 || len(users) != 1 || users[0].PhoneNumber != lama {
			t.Fatalf("cari %q: ingin hanya %s, dapat total %d %+v", q, lama, total, users)
		}
	}
}
