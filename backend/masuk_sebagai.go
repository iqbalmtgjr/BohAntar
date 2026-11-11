package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

// adminMasukSebagaiHandler: POST /api/admin/masuk-sebagai {"phone": "..."}
//
// Super admin masuk ke portal mitra BohFood/BohRental untuk membantu mereka
// (impor menu, input kendaraan) tanpa meminta password mitra. Token yang
// diterbitkan sama persis dengan token login mitra itu sendiri.
//
// Sengaja hanya untuk akun mitra: token driver, penumpang, atau admin lain
// tidak pernah lahir dari sini, jadi admin tidak bisa memesan/menerima order
// atau memakai saldo atas nama orang lain.
//
// ponytail: jejaknya cuma satu baris log (siapa masuk ke akun siapa). Pindah
// ke tabel audit kalau suatu hari ada lebih dari satu super admin yang perlu
// dimintai pertanggungjawaban.
func adminMasukSebagaiHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	var in struct {
		Phone string `json:"phone"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || strings.TrimSpace(in.Phone) == "" {
		writeJSONResponse(w, 400, map[string]string{"error": "Nomor mitra wajib diisi"})
		return
	}
	u, ok := dbGetUser(strings.TrimSpace(in.Phone))
	if !ok {
		writeJSONResponse(w, 404, map[string]string{"error": "Akun tidak ditemukan"})
		return
	}
	if u.Role != "food_merchant" && u.Role != "rental_partner" {
		writeJSONResponse(w, 403, map[string]string{"error": "Hanya bisa masuk ke akun mitra BohFood atau BohRental"})
		return
	}
	token, err := issueToken(u.PhoneNumber, u.Role)
	if err != nil {
		galatServer(w, r, err)
		return
	}
	log.Printf("[masuk-sebagai] admin %s masuk ke akun %s (%s)", callerPhone(r), u.PhoneNumber, u.Role)
	writeJSONResponse(w, 200, map[string]interface{}{
		"status": "success",
		"token":  token,
		"role":   u.Role,
		"phone":  u.PhoneNumber,
		"name":   u.Name,
	})
}
