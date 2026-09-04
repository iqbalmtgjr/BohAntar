package main

import (
	"testing"
	"time"
)

// Seluruh migrasi 002 bertumpu pada satu perilaku database/sql: kolom DATETIME
// yang dibaca dengan parseTime=true tetap bisa dipindai ke field string, dan
// hasilnya berformat RFC3339 seperti yang sudah dikirim API selama ini. Kalau
// itu tidak benar, mengubah tipe kolom akan membuat setiap pembacaan gagal.
func TestDATETIMEBisaDipindaiKeString(t *testing.T) {
	bukaDBTes(t)
	if _, err := db.Exec("CREATE TEMPORARY TABLE uji_waktu (a DATETIME NULL)"); err != nil {
		t.Fatalf("bikin tabel: %v", err)
	}
	if _, err := db.Exec("INSERT INTO uji_waktu VALUES (?), (NULL)", time.Now()); err != nil {
		t.Fatalf("tulis time.Time: %v", err)
	}
	var s string
	if err := db.QueryRow("SELECT a FROM uji_waktu WHERE a IS NOT NULL").Scan(&s); err != nil {
		t.Fatalf("pindai DATETIME ke string: %v", err)
	}
	if _, err := time.Parse(time.RFC3339, s); err != nil {
		t.Fatalf("hasilnya bukan RFC3339: %q (%v)", s, err)
	}
	t.Logf("DATETIME terbaca sebagai %q", s)

	// NULL tidak boleh dipindai ke string biasa — inilah sebabnya driver_loc_at
	// yang kosong dibaca lewat sql.NullString, bukan string.
	if err := db.QueryRow("SELECT a FROM uji_waktu WHERE a IS NULL").Scan(&s); err == nil {
		t.Fatal("NULL ke string seharusnya gagal, tapi lolos")
	}
}
