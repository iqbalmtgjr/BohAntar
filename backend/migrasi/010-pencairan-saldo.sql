-- Migrasi 010 — tabel pencairan saldo manual
--
-- TIDAK WAJIB. initDB() membuat tabel ini sendiri saat backend start, dan
-- perintah di bawah persis sama dengan yang ada di sana.
--
-- Gunanya sama seperti 003 dan 008: initDB memanggil log.Fatalf kalau satu saja
-- CREATE TABLE gagal, jadi DDL yang ditolak server membuat backend TIDAK BISA
-- START. Menjalankan berkas ini lebih dulu memindahkan risiko itu ke tempat
-- aman — yang gagal cuma perintah SQL ini, backend lama tetap melayani.
--
-- Jalankan:  mysql -u USER -p bohantar < 010-pencairan-saldo.sql
--
-- Saldo sudah dipotong saat baris lahir (status 'menunggu'). Admin menandai
-- 'selesai' setelah transfer, atau 'ditolak' dan saldonya dikembalikan.
-- Tanpa FOREIGN KEY ke users, mengikuti setoran_komisi dan tagihan_qr.

CREATE TABLE IF NOT EXISTS pencairan_saldo (
	id VARCHAR(64) PRIMARY KEY,
	phone_number VARCHAR(20) NOT NULL,
	nama_akun VARCHAR(100) NOT NULL,
	peran VARCHAR(20) NOT NULL,
	amount DECIMAL(12,2) NOT NULL,
	bank VARCHAR(50) NOT NULL,
	nomor_rekening VARCHAR(30) NOT NULL,
	nama_pemilik VARCHAR(100) NOT NULL,
	status VARCHAR(10) NOT NULL DEFAULT 'menunggu',
	catatan VARCHAR(200) NULL,
	diproses_oleh VARCHAR(20) NULL,
	created_at DATETIME NOT NULL,
	processed_at DATETIME NULL,
	INDEX idx_pencairan_status (status, created_at),
	INDEX idx_pencairan_phone (phone_number, created_at)
);

-- Pemeriksaan: harus mengembalikan 13 baris kolom, dan kedua indeksnya ada.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pencairan_saldo'
ORDER BY ORDINAL_POSITION;

SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pencairan_saldo'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;
