-- Migrasi 007 — Biaya jasa aplikasi
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya bisa
-- dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 007-biaya-jasa-aplikasi.sql

-- Rupiah tetap yang dibayar penumpang di luar ongkos dan masuk utuh ke
-- aplikator, tidak dibagi dengan driver. Ada supaya pendapatan bohAntar tidak
-- seluruhnya bergantung pada persentase komisi, yang untuk ojek roda dua
-- dibatasi 8% oleh Perpres 27/2026.
ALTER TABLE tarif ADD COLUMN biaya_jasa DECIMAL(12,2) NOT NULL DEFAULT 0;

-- DEFAULT 0, bukan 1000. Pesanan lama memang tidak pernah menagih biaya jasa,
-- dan mengisinya surut akan memalsukan riwayat serta laporan pendapatan.
ALTER TABLE orders ADD COLUMN biaya_jasa DECIMAL(12,2) NOT NULL DEFAULT 0;

-- Batasan terpisah, bukan menambah kolom ke chk_tarif_masuk_akal: yang itu
-- sudah terpasang di produksi, dan mengubahnya menuntut drop lalu pasang lagi.
ALTER TABLE tarif ADD CONSTRAINT chk_tarif_biaya_jasa CHECK (biaya_jasa >= 0);

-- Isi biaya jasa untuk layanan yang sudah ada. Baris tarif sudah dibuat
-- seedTarif() jauh sebelumnya, jadi INSERT IGNORE saat backend start TIDAK akan
-- menyentuhnya — nilai ini harus diisi di sini atau lewat dashboard.
UPDATE tarif SET biaya_jasa = 1000, updated_at = NOW() WHERE biaya_jasa = 0;

-- Pemeriksaan: kedua kolom ada, batasan terpasang, dan setiap layanan punya
-- biaya jasa 1000.
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_NAME = 'biaya_jasa'
ORDER BY TABLE_NAME;

SELECT CONSTRAINT_NAME
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'tarif' AND CONSTRAINT_NAME = 'chk_tarif_biaya_jasa';

SELECT layanan, base, per_km, komisi_persen, biaya_jasa FROM tarif ORDER BY layanan;
