-- Migrasi 013 — kurir bohAntar untuk pelanggan toko Kasvo (fase 4)
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom/indeks yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya
-- bisa dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 013-kasvo-kurir.sql
--
-- orders.kasvo_pengantaran_id: id baris `pengantaran` di Kasvo untuk pesanan
-- kurir yang diminta toko (NULL untuk pesanan biasa). Sengaja tidak UNIQUE:
-- kurir yang kedaluwarsa boleh dicari ulang untuk pengantaran yang sama.
-- orders.kasvo_status_terkirim: "status:nomor driver" terakhir yang diterima
-- Kasvo. Lihat kasvo_kurir.go.

ALTER TABLE orders ADD COLUMN kasvo_pengantaran_id BIGINT NULL;
ALTER TABLE orders ADD COLUMN kasvo_status_terkirim VARCHAR(80) NULL;
ALTER TABLE orders ADD INDEX idx_orders_kasvo_pengantaran (kasvo_pengantaran_id);

-- Pemeriksaan: 2 kolom, 1 indeks.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders'
  AND COLUMN_NAME IN ('kasvo_pengantaran_id', 'kasvo_status_terkirim');

SELECT INDEX_NAME
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' AND INDEX_NAME = 'idx_orders_kasvo_pengantaran';
