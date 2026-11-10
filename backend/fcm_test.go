package main

import (
	"testing"
	"time"
)

// Jendela tiap menit bersambung: pesanan yang menunggu 3 menit dilaporkan
// tepat sekali, dan yang sudah diambil driver tidak dilaporkan sama sekali.
func TestPesananTerlantarDilaporkanSekali(t *testing.T) {
	bukaDBTes(t)
	stempel := time.Now().Format("150405")
	sekarang := time.Now()
	buat := func(rider, status string, umur time.Duration) string {
		id := pesananUji(t, rider+stempel, "cash", status, 10000)
		db.Exec("UPDATE orders SET created_at = ? WHERE id = ?", sekarang.Add(-umur), id)
		return id
	}
	lama := buat("+62895", "pending", 3*time.Minute+30*time.Second)
	baru := buat("+62894", "pending", 2*time.Minute+30*time.Second)
	diambil := buat("+62893", "accepted", 3*time.Minute+30*time.Second)

	milikTes := func(dari, sampai time.Time) (ids []string) {
		daftar, err := pesananTerlantar(dari, sampai)
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range daftar {
			if o.ID == lama || o.ID == baru || o.ID == diambil {
				ids = append(ids, o.ID)
			}
		}
		return
	}
	if ids := milikTes(sekarang.Add(-time.Minute), sekarang); len(ids) != 1 || ids[0] != lama {
		t.Errorf("menit ini harusnya hanya %s, dapat %v", lama, ids)
	}
	if ids := milikTes(sekarang, sekarang.Add(time.Minute)); len(ids) != 1 || ids[0] != baru {
		t.Errorf("menit berikutnya harusnya hanya %s, dapat %v", baru, ids)
	}
}
