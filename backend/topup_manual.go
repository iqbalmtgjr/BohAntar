package main

import (
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strings"
)

// ==================== TOP UP MANUAL (16 Nov 2026) ====================
//
// Driver mengajukan nominal di aplikasi (topUpHandler), aplikasi membuka
// halaman petunjuk transfer, admin dapat email, mengecek uang masuk, lalu
// menekan Setujui/Tolak di dashboard #/topup. Env di run.sh:
//
//	TOPUP_TUJUAN       rekening tujuan, mis. "DANA Bisnis 0812xxxx a.n. ..." (wajib)
//	TOPUP_QRIS         alamat gambar QRIS statis, mis. "/uploads/qris-topup.png"
//	                   (18 Nov 2026). Kosong = halaman kembali ke petunjuk transfer.
//	NOTIF_ADMIN_EMAIL  penerima email pengajuan (email.go)
//
// ponytail: QRIS statis, nominal diketik driver dan dicocokkan admin dengan
// mata. QRIS dinamis (nominal terkunci, lunas otomatis) menunggu Duitku.

// kirimEmailAdmin: pengajuan tetap tercatat dan tampil di dashboard walau
// emailnya gagal, jadi galat cukup ke log.
func kirimEmailAdmin(judul, isi string) {
	kirimEmail(getEnv("NOTIF_ADMIN_EMAIL", ""), judul, isi)
}

// kodeUnikTopUp: kode 1–999 terkecil yang membuat nominal+kode belum dipakai
// pengajuan MENUNGGU mana pun, supaya admin cukup mencari angka itu di riwayat
// DANA (QRIS tidak punya berita transfer). Kode ikut masuk ke saldo.
//
// ponytail: dibaca lalu ditulis tanpa kunci; dua pengajuan di milidetik yang
// sama bisa dapat total kembar, admin tetap bisa mencocokkan lewat jam & nama.
func kodeUnikTopUp(nominal float64) (int, error) {
	rows, err := db.Query("SELECT amount FROM topup_invoices WHERE status = 'MENUNGGU' AND amount > ? AND amount < ?", nominal, nominal+1000)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	dipakai := map[int]bool{}
	for rows.Next() {
		var a float64
		if err := rows.Scan(&a); err != nil {
			return 0, err
		}
		dipakai[int(a-nominal)] = true
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	for kode := 1; kode <= 999; kode++ {
		if !dipakai[kode] {
			return kode, nil
		}
	}
	return 0, errors.New("semua kode unik untuk nominal ini sedang dipakai")
}

var halamanBayarTopUp =template.Must(template.New("bayar").Parse(`<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Isi saldo BohAntar</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;max-width:440px;margin:0 auto;padding:24px 16px;color:#1a1a1a;background:#f3f6fb;line-height:1.5}
.kartu{background:#fff;border-radius:16px;padding:20px;box-shadow:0 1px 4px rgba(0,0,0,.08);margin-bottom:16px}
.nominal{font-size:32px;font-weight:800;color:#1565c0;margin:4px 0 10px}
.tujuan{white-space:pre-line;font-size:18px;font-weight:700;margin:6px 0 12px}
.status{display:inline-block;padding:4px 12px;border-radius:99px;font-size:13px;font-weight:700;background:#eceff1;color:#455a64}
.MENUNGGU{background:#fff3cd;color:#7a5d00}.PAID{background:#d4edda;color:#1e6b34}.DITOLAK{background:#f8d7da;color:#842029}
small{color:#5f6b7a}
.qris{display:block;width:100%;max-width:320px;margin:8px auto;border-radius:8px}
.tombol{display:block;text-align:center;background:#1565c0;color:#fff;text-decoration:none;font-weight:700;padding:12px;border-radius:12px;margin:12px 0 4px}
ol{padding-left:20px;margin:8px 0}
</style></head><body>
<div class="kartu"><small>Isi saldo komisi</small><div class="nominal">{{.Nominal}}</div><span class="status {{.Status}}">{{.Label}}</span></div>
{{if eq .Status "MENUNGGU"}}
{{if .QRIS}}
<div class="kartu"><small>Bayar lewat QRIS ke</small><div class="tujuan">{{.Tujuan}}</div>
<img class="qris" src="{{.QRIS}}" alt="Kode QRIS BohAntar">
<a class="tombol" href="{{.QRIS}}" download>Simpan gambar QRIS</a>
<ol>
<li>Simpan gambar QRIS di atas.</li>
<li>Buka DANA, GoPay, OVO, ShopeePay, atau m-banking, pilih <b>Scan/Bayar</b>, lalu ambil gambar QRIS dari galeri.</li>
<li>Ketik nominal tepat <b>{{.Nominal}}</b>, lalu bayar. Tiga angka terakhir adalah kode unik supaya pembayaranmu mudah dicari, dan ikut masuk ke saldomu.</li>
</ol></div>
{{else}}
<div class="kartu"><small>Transfer tepat {{.Nominal}} ke</small><div class="tujuan">{{.Tujuan}}</div>
<p>Tulis <b>{{.HP}}</b> di catatan/berita transfer supaya admin mudah mencocokkan.</p></div>
{{end}}
<p><small>Sudah bayar? Kembali ke aplikasi BohAntar. Admin mengecek pembayaranmu, saldo masuk setelah disetujui — ketuk "Cek saldo" untuk melihat.</small></p>
{{end}}
</body></html>`))

// topUpBayarHandler: GET /api/topup/bayar/{id} — halaman yang dibuka aplikasi
// sebagai "payment_url". Tanpa login (dibuka di browser luar); id-nya acak 24
// heksa dari newID, jadi tidak bisa ditebak untuk mengintip pengajuan orang lain.
func topUpBayarHandler(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/topup/bayar/")
	var phone, status string
	var jumlah float64
	if err := db.QueryRow("SELECT phone_number, amount, status FROM topup_invoices WHERE id = ?", id).
		Scan(&phone, &jumlah, &status); err != nil {
		http.Error(w, "Pengajuan top up tidak ditemukan", http.StatusNotFound)
		return
	}
	label := map[string]string{"MENUNGGU": "Menunggu dicek admin", "PAID": "Saldo sudah masuk", "DITOLAK": "Ditolak — hubungi admin"}[status]
	if label == "" {
		label = "Kedaluwarsa"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	halamanBayarTopUp.Execute(w, map[string]string{
		"Nominal": formatRupiah(int64(jumlah)),
		"Status":  status,
		"Label":   label,
		"Tujuan":  getEnv("TOPUP_TUJUAN", ""),
		"QRIS":    getEnv("TOPUP_QRIS", ""),
		// Format 08xx: sebagian aplikasi bank menolak "+" di berita transfer.
		"HP": "0" + strings.TrimPrefix(phone, "+62"),
	})
}

// adminProsesTopUpHandler: POST /api/admin/topup/{id}/setujui|tolak
func adminProsesTopUpHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSONResponse(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	bagian := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/admin/topup/"), "/"), "/")
	if len(bagian) != 2 || (bagian[1] != "setujui" && bagian[1] != "tolak") {
		writeJSONResponse(w, 404, map[string]string{"error": "Tidak ditemukan"})
		return
	}
	id := bagian[0]

	if bagian[1] == "setujui" {
		// Bersyarat status MENUNGGU di dalam dbKreditTopUp: dua klik atau dua
		// admin bersamaan hanya menambah saldo sekali.
		phone, jumlah, err := dbKreditTopUp(id, "MENUNGGU", 0)
		switch {
		case errors.Is(err, errTopUpTakDitemukan):
			writeJSONResponse(w, 404, map[string]string{"error": "Pengajuan tidak ditemukan"})
		case err != nil:
			log.Printf("Top up %s gagal disetujui: %v", id, err)
			writeJSONResponse(w, 500, map[string]string{"error": "Gagal menambah saldo"})
		case jumlah == 0:
			writeJSONResponse(w, 409, map[string]string{"error": "Pengajuan ini sudah diproses"})
		default:
			log.Printf("Top up %s disetujui %s: %s +Rp%.0f", id, callerPhone(r), phone, jumlah)
			notifikasiKe(phone, "Saldo masuk", fmt.Sprintf("Isi saldo %s sudah disetujui, saldo komisimu bertambah.", formatRupiah(int64(jumlah))), map[string]string{"tipe": "topup"})
			writeJSONResponse(w, 200, map[string]string{"status": "success"})
		}
		return
	}

	var phone string
	var jumlah float64
	if err := db.QueryRow("SELECT phone_number, amount FROM topup_invoices WHERE id = ?", id).Scan(&phone, &jumlah); err != nil {
		writeJSONResponse(w, 404, map[string]string{"error": "Pengajuan tidak ditemukan"})
		return
	}
	res, err := db.Exec("UPDATE topup_invoices SET status = 'DITOLAK' WHERE id = ? AND status = 'MENUNGGU'", id)
	if err != nil {
		writeJSONResponse(w, 500, map[string]string{"error": "Gagal menolak pengajuan"})
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeJSONResponse(w, 409, map[string]string{"error": "Pengajuan ini sudah diproses"})
		return
	}
	log.Printf("Top up %s ditolak %s", id, callerPhone(r))
	notifikasiKe(phone, "Isi saldo ditolak", fmt.Sprintf("Transfer %s belum kami terima. Sudah transfer? Hubungi admin BohAntar.", formatRupiah(int64(jumlah))), map[string]string{"tipe": "topup"})
	writeJSONResponse(w, 200, map[string]string{"status": "success"})
}
