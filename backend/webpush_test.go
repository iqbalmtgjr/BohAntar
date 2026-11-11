package main

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Vektor uji RFC 8291 lampiran A: kalau satu langkah HKDF/label/format
// header meleset, hasilnya beda total dan browser menolak pesannya.
func TestEnkripsiWebPushVektorRFC8291(t *testing.T) {
	d := base64.RawURLEncoding.DecodeString
	asPriv, _ := d("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
	salt, _ := d("DGv6ra1nlYgDCS1FRnbzlw")
	eph, err := ecdh.P256().NewPrivateKey(asPriv)
	if err != nil {
		t.Fatal(err)
	}
	got, err := enkripsiWebPushDengan(eph, salt,
		"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
		"BTBZMqHH6r4Tts7J_aSIgg", []byte("When I grow up, I want to be a watermelon"))
	if err != nil {
		t.Fatal(err)
	}
	want := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
	if s := base64.RawURLEncoding.EncodeToString(got); s != want {
		t.Fatalf("hasil enkripsi tidak sama dengan RFC 8291:\n got %s\nwant %s", s, want)
	}
}

// Langganan hanya ke layanan push resmi; browser yang berhenti berlangganan
// (410) dihapus; notifikasiKe ikut mengirim ke browser mitra.
func TestWebPushLanggananDanKirim(t *testing.T) {
	for s, sah := range map[string]bool{
		"https://fcm.googleapis.com/fcm/send/abc":       true,
		"https://web.push.apple.com/QGx":                true,
		"https://127.0.0.1/fcm.googleapis.com":          false,
		"http://fcm.googleapis.com/x":                   false,
		"https://fcm.googleapis.com.jahat.example/x":    false,
		"https://wns2-sg2p.notify.windows.com/w/?token": true,
	} {
		if endpointPushSah(s) != sah {
			t.Errorf("endpointPushSah(%q) != %v", s, sah)
		}
	}

	bukaDBTes(t)
	migrasiWebPush()
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	lama := vapidKunci
	vapidKunci, vapidPublik = k, "uji"
	t.Cleanup(func() { vapidKunci = lama })

	var hdr http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hdr = r.Header.Clone()
		w.WriteHeader(410)
	}))
	defer srv.Close()

	ua, _ := ecdh.P256().GenerateKey(rand.Reader)
	phone := "+62895" + time.Now().Format("150405")
	ep := srv.URL + "/push/" + phone
	t.Cleanup(func() { db.Exec("DELETE FROM webpush WHERE phone_number = ?", phone) })
	if _, err := db.Exec("INSERT INTO webpush (endpoint, phone_number, p256dh, auth) VALUES (?, ?, ?, ?)", ep, phone,
		base64.RawURLEncoding.EncodeToString(ua.PublicKey().Bytes()), "BTBZMqHH6r4Tts7J_aSIgg"); err != nil {
		t.Fatal(err)
	}

	kirimWebPush(phone, "Budi · Avanza", strings.Repeat("halo ", 500), map[string]string{"tipe": "chat_sewa"})
	if hdr == nil || !strings.HasPrefix(hdr.Get("Authorization"), "vapid t=") || hdr.Get("Content-Encoding") != "aes128gcm" {
		t.Fatalf("permintaan push tidak sesuai: %v", hdr)
	}
	var n int
	db.QueryRow("SELECT COUNT(*) FROM webpush WHERE phone_number = ?", phone).Scan(&n)
	if n != 0 {
		t.Fatal("langganan yang dijawab 410 tidak dihapus")
	}
}
