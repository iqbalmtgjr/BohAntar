package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Lencana merah tab Chat: pesan lawan bicara terhitung belum dibaca sampai
// layar chatnya dibuka, dan pesan sendiri tidak pernah terhitung.
func TestDaftarChatDanLencana(t *testing.T) {
	bukaDBTes(t)
	const penumpang, driver = "+62800000301", "+62800000302"
	penggunaUji(t, penumpang)
	penggunaUji(t, driver)
	migrasiSkema("ALTER TABLE chat_messages ADD COLUMN dibaca TINYINT(1) NOT NULL DEFAULT 1")

	oid := newID("test")
	now := time.Now()
	if err := dbSaveOrder(Order{
		ID: oid, RiderPhone: penumpang, RiderName: "Uji", DriverPhone: driver, DriverName: "Pak Uji",
		PickupAddress: "A", DropoffAddress: "B", Fare: 10000, PaymentMethod: "cash", Service: "BohRide",
		Status: "accepted", CreatedAt: now.Format(time.RFC3339), UpdatedAt: now.Format(time.RFC3339),
	}); err != nil {
		t.Fatalf("pesanan uji: %v", err)
	}
	t.Cleanup(func() { db.Exec("DELETE FROM orders WHERE id = ?", oid) })

	for i, p := range []struct{ dari, isi string }{{driver, "Saya di depan"}, {driver, "Gerbang hijau?"}, {penumpang, "Iya, tunggu"}} {
		waktu := now.Add(time.Duration(i-3) * time.Minute).Format(time.RFC3339)
		if err := dbSaveChatMessage(ChatMessage{ID: newID("msg"), OrderID: oid, SenderPhone: p.dari, Content: p.isi, Timestamp: waktu}, false); err != nil {
			t.Fatalf("pesan uji: %v", err)
		}
	}

	daftar := func(phone, peran string) (RingkasanChat, int) {
		t.Helper()
		tok, _ := issueToken(phone, peran)
		req := httptest.NewRequest(http.MethodGet, "/api/chats", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		daftarChatHandler(w, req)
		var hasil struct {
			Chats       []RingkasanChat `json:"chats"`
			BelumDibaca int             `json:"belum_dibaca"`
		}
		json.Unmarshal(w.Body.Bytes(), &hasil)
		if w.Code != 200 || len(hasil.Chats) != 1 {
			t.Fatalf("%s: kode %d, isi %s", phone, w.Code, w.Body)
		}
		return hasil.Chats[0], hasil.BelumDibaca
	}

	c, total := daftar(penumpang, "rider")
	if c.BelumDibaca != 2 || total != 2 || c.LawanPeran != "driver" || c.LawanNama != "Pak Uji" || !c.DariSaya || c.PesanTerakhir != "Iya, tunggu" {
		t.Fatalf("penumpang sebelum membuka chat: %+v total %d", c, total)
	}
	if c, _ := daftar(driver, "driver"); c.BelumDibaca != 1 || c.LawanPeran != "penumpang" || c.DariSaya {
		t.Fatalf("driver: %+v", c)
	}

	// Penumpang membuka layar chat: pesan driver jadi terbaca, milik driver tidak.
	srv := httptest.NewServer(http.HandlerFunc(chatWebSocketHandler))
	defer srv.Close()
	tok, _ := issueToken(penumpang, "rider")
	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/ws/chat/"+oid+"?token="+tok, nil)
	if err != nil {
		t.Fatalf("buka chat: %v", err)
	}
	conn.ReadMessage() // riwayat; tandai-baca terjadi sebelum riwayat dikirim
	conn.Close()

	if c, total := daftar(penumpang, "rider"); c.BelumDibaca != 0 || total != 0 {
		t.Fatalf("penumpang sesudah membuka chat: %+v total %d", c, total)
	}
	if c, _ := daftar(driver, "driver"); c.BelumDibaca != 1 {
		t.Fatalf("driver ikut terhapus lencananya: %+v", c)
	}
}
