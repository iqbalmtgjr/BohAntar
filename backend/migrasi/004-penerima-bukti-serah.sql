-- Migrasi 004 — penerima di tujuan dan bukti serah-terima barang
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya bisa
-- dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 004-penerima-bukti-serah.sql

ALTER TABLE orders ADD COLUMN receiver_name VARCHAR(100);
ALTER TABLE orders ADD COLUMN receiver_phone VARCHAR(20);
ALTER TABLE orders ADD COLUMN pickup_photo_url VARCHAR(255);
ALTER TABLE orders ADD COLUMN delivery_photo_url VARCHAR(255);
ALTER TABLE orders ADD COLUMN received_by VARCHAR(100);

-- Pemeriksaan: harus mengembalikan 5 baris.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders'
  AND COLUMN_NAME IN ('receiver_name', 'receiver_phone', 'pickup_photo_url', 'delivery_photo_url', 'received_by')
ORDER BY ORDINAL_POSITION;
