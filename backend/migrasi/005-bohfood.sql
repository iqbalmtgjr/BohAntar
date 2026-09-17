-- Migrasi 005 — BohFood: lokasi warung, isi pesanan makanan, uang talangan
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya bisa
-- dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
-- Baris tarif BohFood diisi seedTarif() saat backend start (INSERT IGNORE).
--
-- Jalankan:  mysql -u USER -p bohantar < 005-bohfood.sql

ALTER TABLE food_merchants ADD COLUMN lat DOUBLE NOT NULL DEFAULT 0;
ALTER TABLE food_merchants ADD COLUMN lng DOUBLE NOT NULL DEFAULT 0;

ALTER TABLE orders ADD COLUMN merchant_id VARCHAR(50);
ALTER TABLE orders ADD COLUMN merchant_name VARCHAR(100);
ALTER TABLE orders ADD COLUMN items_json TEXT;
ALTER TABLE orders ADD COLUMN food_total DECIMAL(12,2) NOT NULL DEFAULT 0;
ALTER TABLE orders ADD INDEX idx_orders_merchant (merchant_id, created_at);

-- Pemeriksaan: 2 baris dari food_merchants, 4 baris dari orders, 1 indeks.
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND ((TABLE_NAME = 'food_merchants' AND COLUMN_NAME IN ('lat', 'lng'))
    OR (TABLE_NAME = 'orders' AND COLUMN_NAME IN ('merchant_id', 'merchant_name', 'items_json', 'food_total')))
ORDER BY TABLE_NAME, ORDINAL_POSITION;

SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders' AND INDEX_NAME = 'idx_orders_merchant'
ORDER BY SEQ_IN_INDEX;
