-- Migrasi 011 — toko Kasvo bergabung ke BohFood
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom/indeks yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya
-- bisa dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 011-kasvo-bohfood.sql
--
-- food_merchants.kasvo_toko_uuid terisi = menu warung dibaca langsung dari
-- Kasvo (lihat kasvo.go). NULL boleh berulang di indeks UNIQUE, jadi warung
-- biasa tidak saling bertabrakan. Empat kolom partner_applications membawa
-- profil toko dari tombol "Gabung bohFood" sampai admin menyetujuinya.

ALTER TABLE food_merchants ADD COLUMN kasvo_toko_uuid VARCHAR(36) NULL;
ALTER TABLE food_merchants ADD UNIQUE INDEX uq_food_merchants_kasvo (kasvo_toko_uuid);

ALTER TABLE partner_applications ADD COLUMN kasvo_toko_uuid VARCHAR(36) NULL;
ALTER TABLE partner_applications ADD COLUMN lat DOUBLE NOT NULL DEFAULT 0;
ALTER TABLE partner_applications ADD COLUMN lng DOUBLE NOT NULL DEFAULT 0;
ALTER TABLE partner_applications ADD COLUMN image_url TEXT;

-- Pemeriksaan: 5 kolom, 1 indeks.
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND ((TABLE_NAME = 'food_merchants' AND COLUMN_NAME = 'kasvo_toko_uuid')
    OR (TABLE_NAME = 'partner_applications' AND COLUMN_NAME IN ('kasvo_toko_uuid', 'lat', 'lng', 'image_url')))
ORDER BY TABLE_NAME, ORDINAL_POSITION;

SELECT INDEX_NAME, NON_UNIQUE
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'food_merchants' AND INDEX_NAME = 'uq_food_merchants_kasvo';
