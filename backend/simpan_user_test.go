package main

import (
	"testing"
	"time"
)

// dbSaveUser pernah rusak total selama beberapa hari di produksi: `COALESCE`
// tersalin ke dalam DAFTAR KOLOM INSERT, yang bukan SQL yang sah, jadi setiap
// pemanggilan membalas error 1064. Sebagian besar pemanggilnya membuang error
// itu, jadi menyetujui driver tampak berhasil di layar admin padahal akunnya
// tidak pernah lahir.
//
// Tesnya menembak MySQL sungguhan karena yang salah memang cuma kelihatan di
// sana: kode Go-nya sendiri lolos kompilasi dengan senang hati.
func TestSaveUserMenyimpanSungguhan(t *testing.T) {
	bukaDBTes(t)

	phone := "+62899" + time.Now().Format("150405")
	t.Cleanup(func() { db.Exec("DELETE FROM users WHERE phone_number = ?", phone) })

	u := User{
		PhoneNumber: phone, Name: "Uji Simpan", Email: phone + "@contoh.test",
		Role: "rider", CreatedAt: time.Now().Format(time.RFC3339),
		Badge: "Silver", Rating: 5,
	}
	if err := dbSaveUser(u); err != nil {
		t.Fatalf("dbSaveUser gagal: %v", err)
	}

	simpan, ok := dbGetUser(phone)
	if !ok {
		t.Fatal("pengguna tidak ditemukan setelah disimpan")
	}
	if simpan.Email != u.Email || simpan.Role != "rider" {
		t.Fatalf("isi tidak sama: %+v", simpan)
	}

	// Email kosong harus menjadi NULL, bukan string kosong: indeks unik email
	// mengizinkan banyak NULL tapi menolak string kosong kedua, jadi pengguna
	// tanpa email akan saling menendang kalau ini salah.
	tanpaEmail := u
	tanpaEmail.Email = ""
	if err := dbSaveUser(tanpaEmail); err != nil {
		t.Fatalf("menyimpan tanpa email gagal: %v", err)
	}
	var nul bool
	if err := db.QueryRow("SELECT email IS NULL FROM users WHERE phone_number = ?", phone).Scan(&nul); err != nil {
		t.Fatalf("membaca kembali gagal: %v", err)
	}
	if !nul {
		t.Fatal("email kosong disimpan sebagai string kosong, seharusnya NULL")
	}
}
