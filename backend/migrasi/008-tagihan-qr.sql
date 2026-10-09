-- Migrasi 008 — tabel tagihan QR (bayar warung pakai saldo)
--
-- TIDAK WAJIB. initDB() membuat tabel ini sendiri saat backend start, dan
-- perintah di bawah persis sama dengan yang ada di sana.
--
-- Gunanya sama seperti 003: initDB memanggil log.Fatalf kalau satu saja CREATE
-- TABLE gagal, jadi DDL yang ditolak server membuat backend TIDAK BISA START.
-- Menjalankan berkas ini lebih dulu memindahkan risiko itu ke tempat aman —
-- yang gagal cuma perintah SQL ini, backend lama tetap melayani.
--
-- Jalankan:  mysql -u USER -p bohantar < 008-tagihan-qr.sql
--
-- Sengaja tanpa FOREIGN KEY ke users(phone_number), mengikuti setoran_komisi:
-- kolasi kolom itu berbeda antara MySQL lokal (utf8mb4_0900_ai_ci) dan MariaDB
-- produksi, dan menyamakannya di sini hanya memindahkan penolakannya ke sisi
-- lain. Keberadaan warungnya sudah diperiksa handler sebelum baris dibuat.

CREATE TABLE IF NOT EXISTS tagihan_qr (
	id VARCHAR(64) PRIMARY KEY,
	penerima_phone VARCHAR(20) NOT NULL,
	penerima_nama VARCHAR(100) NOT NULL,
	amount DECIMAL(12,2) NOT NULL,
	-- Potongan bohAntar, dikunci saat tagihan dibuat. Persennya di baris
	-- tarif 'TagihanQR' (bawaan 0%), diatur super admin lewat halaman Tarif.
	komisi DECIMAL(12,2) NOT NULL DEFAULT 0,
	created_at DATETIME NOT NULL,
	expires_at DATETIME NOT NULL,
	paid_at DATETIME NULL,
	payer_phone VARCHAR(20) NULL,
	INDEX idx_tagihan_penerima (penerima_phone, created_at)
);

-- Pemeriksaan: harus mengembalikan 9 baris kolom, dan indeksnya ada.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'tagihan_qr'
ORDER BY ORDINAL_POSITION;

SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'tagihan_qr'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;
