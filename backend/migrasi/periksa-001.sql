-- =====================================================================
-- Pemeriksaan migrasi 001 — jalankan kapan saja, tidak mengubah apa pun
--
--   mysql -u bohantar -p bohantar < periksa-001.sql
--
-- Membaca keadaan database apa adanya, lalu menjawab OK atau CACAT untuk
-- tiap hal yang seharusnya dikerjakan migrasi 001. Semua baris OK berarti
-- migrasinya tuntas; satu CACAT menyebutkan sendiri apa yang kurang.
--
-- Aman diulang, aman dijalankan saat server sedang melayani: tidak ada
-- satu pun perintah yang menulis.
-- =====================================================================

SELECT 'charset database' AS pemeriksaan,
       IF(@@character_set_database = 'utf8mb4',
          'OK', CONCAT('CACAT: masih ', @@character_set_database)) AS hasil

UNION ALL
SELECT 'tabel utf8mb4',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' tabel tertinggal — ', GROUP_CONCAT(table_name)))
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_collation NOT LIKE 'utf8mb4%'

UNION ALL
-- Tabel bisa saja sudah utf8mb4 sementara kolomnya belum ikut. Kolom
-- itulah yang sebenarnya menolak emoji, jadi diperiksa sendiri.
SELECT 'kolom teks utf8mb4',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' kolom — ', GROUP_CONCAT(CONCAT(table_name, '.', column_name))))
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND character_set_name IS NOT NULL
  AND character_set_name <> 'utf8mb4'

UNION ALL
SELECT 'kolom uang DECIMAL',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: masih DOUBLE — ', GROUP_CONCAT(CONCAT(table_name, '.', column_name))))
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND data_type = 'double'
  AND column_name IN ('balance','rating','fare','komisi','amount','price',
                      'price_per_day','total_price','late_fee','late_fee_value',
                      'base','per_km','komisi_persen')

UNION ALL
SELECT 'foreign key utuh',
       IF(COUNT(*) = 10, 'OK', CONCAT('CACAT: ada ', COUNT(*), ' dari 10 — ada yang tidak terpasang kembali setelah konversi'))
FROM information_schema.key_column_usage
WHERE table_schema = DATABASE() AND referenced_table_name IS NOT NULL

UNION ALL
SELECT 'indeks terpasang',
       IF(COUNT(DISTINCT index_name) = 10, 'OK', CONCAT('CACAT: ada ', COUNT(DISTINCT index_name), ' dari 10'))
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND index_name IN ('idx_orders_status','idx_orders_driver','idx_orders_rider',
                     'idx_chat_order','idx_users_role','idx_driver_apps_status',
                     'idx_partner_apps_status','idx_bookings_mobil',
                     'idx_schedules_mobil','idx_invoices_mitra')

UNION ALL
SELECT 'batasan CHECK',
       IF(COUNT(*) = 5, 'OK', CONCAT('CACAT: ada ', COUNT(*), ' dari 5'))
FROM information_schema.table_constraints
WHERE table_schema = DATABASE() AND constraint_type = 'CHECK'
  AND constraint_name IN ('chk_orders_status','chk_orders_payment','chk_users_role',
                          'chk_rating_bintang','chk_tarif_masuk_akal')

UNION ALL
-- Batasan hanya berlaku untuk baris baru. Kalau ada baris lama yang
-- melanggarnya, ia lolos dari CHECK tapi tetap salah — dan justru baris
-- seperti inilah yang hilang dari filter tanpa jejak.
SELECT 'status pesanan sah',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pesanan berstatus aneh — ', GROUP_CONCAT(DISTINCT status)))
FROM orders
WHERE status NOT IN ('pending','accepted','picked_up','completed','cancelled','expired')

UNION ALL
SELECT 'peran pengguna sah',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pengguna berperan aneh — ', GROUP_CONCAT(DISTINCT role)))
FROM users
WHERE role NOT IN ('rider','driver','admin','food_merchant','rental_partner')

UNION ALL
-- Indeks unik email mengizinkan banyak NULL tapi menolak string kosong
-- kedua. Satu baris beremail '' berarti pengguna berikutnya yang mendaftar
-- tanpa email akan ditolak.
SELECT 'email kosong jadi NULL',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pengguna beremail string kosong'))
FROM users
WHERE email = '';
