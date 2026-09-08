-- Migrasi 003 — tabel setoran komisi tunai
--
-- TIDAK WAJIB. initDB() membuat tabel ini sendiri saat backend start, dan
-- perintah di bawah persis sama dengan yang ada di sana.
--
-- Gunanya: initDB memanggil log.Fatalf kalau satu saja CREATE TABLE gagal, jadi
-- DDL yang ditolak server membuat backend TIDAK BISA START sama sekali.
-- Menjalankan berkas ini lebih dulu memindahkan risiko itu ke tempat yang aman:
-- kalau MariaDB menolak sesuatu, yang gagal cuma perintah SQL ini, dan backend
-- lama masih melayani seperti biasa. Setelah tabelnya ada, CREATE TABLE IF NOT
-- EXISTS di initDB tidak melakukan apa-apa.
--
-- Jalankan:  mysql -u USER -p bohantar < 003-setoran-komisi.sql
--
-- Sengaja tanpa FOREIGN KEY ke users(phone_number): kolasi kolom itu berbeda
-- antara MySQL lokal (utf8mb4_0900_ai_ci) dan MariaDB produksi, dan menyamakan
-- kolasi di sini hanya memindahkan penolakannya ke sisi yang lain. Keberadaan
-- drivernya sudah diperiksa handler sebelum baris dibuat.

CREATE TABLE IF NOT EXISTS setoran_komisi (
	id VARCHAR(64) PRIMARY KEY,
	driver_phone VARCHAR(20) NOT NULL,
	amount DECIMAL(12,2) NOT NULL,
	dibuat_oleh VARCHAR(20) NOT NULL,
	created_at DATETIME NOT NULL,
	expires_at DATETIME NOT NULL,
	claimed_at DATETIME NULL,
	INDEX idx_setoran_driver (driver_phone, created_at)
);

-- Pemeriksaan: harus mengembalikan 8 baris kolom, dan indeksnya ada.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'setoran_komisi'
ORDER BY ORDINAL_POSITION;

SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'setoran_komisi'
ORDER BY INDEX_NAME, SEQ_IN_INDEX;
