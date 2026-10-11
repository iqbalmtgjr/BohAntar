-- Migrasi 012 — pesanan BohFood masuk kasir Kasvo
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya bisa
-- dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 012-kasvo-pesanan.sql
--
-- orders.kasvo_pesanan_id: NULL = belum dikirim ke kasir, >0 = nomor pesanan
-- di kasir Kasvo, 0 = ditolak kasir (driver memesan manual). Lihat
-- sinkronKasvo di kasvo.go. Pasangannya di Kasvo: migrasi
-- 2026_10_11_000001_bohfood_order_id (kolom order.bohfood_order_id).

ALTER TABLE orders ADD COLUMN kasvo_pesanan_id BIGINT NULL;

-- Pemeriksaan: 1 baris.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' AND COLUMN_NAME = 'kasvo_pesanan_id';
