-- Migrasi 009 — Jarak dasar dan pembulatan per layanan
--
-- TIDAK WAJIB. initDB() menjalankan ALTER yang sama lewat migrasiSkema(), dan
-- kolom yang sudah ada dilewati diam-diam. Berkas ini ada supaya DDL-nya bisa
-- dicoba di MariaDB produksi lebih dulu, terpisah dari restart backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 009-tarif-jarak-dasar.sql
--
-- Kenapa ada: rumus lama (buka pintu + km x per km) tidak bisa meniru harga
-- flat sampai 3 km yang dipakai aplikasi lokal di Sintang. Dengan jarak dasar,
-- buka pintu menanggung kilometer pertama dan per_km baru menghitung sisanya.

-- Kilometer pertama yang sudah termasuk ongkos buka pintu. 0 = perilaku lama,
-- yaitu per_km dihitung sejak meter pertama.
ALTER TABLE tarif ADD COLUMN jarak_dasar_km SMALLINT UNSIGNED NOT NULL DEFAULT 0;

-- Kelipatan pembulatan ongkos dalam rupiah, dan arahnya. DEFAULT 100 + FALSE
-- adalah perilaku lama persis: dibulatkan ke ratusan terdekat.
ALTER TABLE tarif ADD COLUMN pembulatan SMALLINT UNSIGNED NOT NULL DEFAULT 100;
ALTER TABLE tarif ADD COLUMN pembulatan_ke_atas BOOLEAN NOT NULL DEFAULT FALSE;

-- Nilai bohRide hasil pencocokan dengan harga aplikasi lokal: 11.000 flat
-- sampai 3 km, lalu naik Rp 1.000 tiap 400 m (2.500/km dibulatkan ke atas ke
-- ribuan). Baris tarif sudah dibuat seedTarif() jauh sebelumnya, jadi INSERT
-- IGNORE saat backend start TIDAK akan menyentuhnya — angka ini harus diisi di
-- sini atau lewat dashboard.
--
-- Layanan lain sengaja tidak disentuh: jarak dasar 0 dan pembulatan 100
-- terdekat membuat hasilnya sama persis seperti sebelum migrasi ini.
--
-- komisi_persen sengaja TIDAK ikut diubah: tetap berapa pun nilainya sekarang
-- (20% per 9 Okt 2026), dan diatur super admin lewat halaman Tarif.
UPDATE tarif SET base = 10000, per_km = 2500, jarak_dasar_km = 3,
       pembulatan = 1000, pembulatan_ke_atas = TRUE,
       biaya_jasa = 1000, updated_at = NOW()
WHERE layanan = 'BohRide';

-- Pemeriksaan: ketiga kolom ada dengan default yang benar, dan hanya bohRide
-- yang punya jarak dasar bukan nol.
SELECT COLUMN_NAME, COLUMN_TYPE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'tarif'
  AND COLUMN_NAME IN ('jarak_dasar_km', 'pembulatan', 'pembulatan_ke_atas')
ORDER BY COLUMN_NAME;

SELECT layanan, base, per_km, jarak_dasar_km, pembulatan, pembulatan_ke_atas,
       komisi_persen, biaya_jasa
FROM tarif ORDER BY layanan;
