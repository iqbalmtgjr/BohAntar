-- =====================================================================
-- Pemeriksaan migrasi 002 — jalankan SEBELUM dan SESUDAH, tidak menulis
--
--   mysql -u bohantar -p bohantar < periksa-002.sql
--
-- Dipakai dua kali dengan arti berbeda:
--
--   SEBELUM migrasi — yang penting baris 1 sampai 4. Semuanya harus OK,
--   karena itulah hal-hal yang akan menghentikan migrasi di tengah jalan:
--   zona waktu server, cap waktu beroffset aneh, dan baris yatim. Baris 5
--   dan 6 wajar berbunyi CACAT — memang belum dikerjakan.
--
--   SESUDAH migrasi — semuanya harus OK.
--
-- Aman diulang, aman dijalankan saat server melayani: tidak ada satu pun
-- perintah yang menulis.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Zona waktu server
--
-- DATETIME menyimpan waktu tanpa offset, dan migrasi 002 menyimpan bagian
-- setempat dari "…+07:00" apa adanya. Itu benar hanya kalau jam sistem
-- server memang berjalan di WIB — karena Go membaca kembali kolom itu
-- dengan loc=Local, yaitu zona sistem yang sama. Kalau servernya UTC,
-- setiap cap waktu akan terbaca tujuh jam meleset.
--
-- Kalau CACAT: setel dulu zona server (timedatectl set-timezone
-- Asia/Jakarta), restart MySQL, baru migrasi.
-- ---------------------------------------------------------------------
SELECT 'zona waktu server' AS pemeriksaan,
       IF(@@system_time_zone IN ('WIB','+07','+07:00') OR NOW() = CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', '+07:00'),
          'OK', CONCAT('CACAT: server di ', @@system_time_zone, ', bukan WIB')) AS hasil

UNION ALL
-- ---------------------------------------------------------------------
-- 2. Cap waktu beroffset selain +07:00
--
-- Migrasi 002 hanya memotong offset "+07:00" karena servernya sezona.
-- Baris beroffset lain sengaja tidak disentuh, dan ALTER akan menolaknya —
-- migrasi berhenti di tengah. Cari dan betulkan dulu di sini.
--
-- Setelah migrasi kolomnya DATETIME dan tidak mungkin memuat "+" lagi,
-- jadi baris ini otomatis jadi OK.
-- ---------------------------------------------------------------------
SELECT 'cap waktu beroffset selain +07:00',
       IF((SELECT SUM(n) FROM (
             SELECT COUNT(*) n FROM users                 WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM users                 WHERE driver_loc_at LIKE '%+%' AND driver_loc_at NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM orders                WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM orders                WHERE updated_at    LIKE '%+%' AND updated_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM order_ratings         WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM driver_applications   WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM chat_messages         WHERE `timestamp`   LIKE '%+%' AND `timestamp`   NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM food_merchants        WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM rental_cars           WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM rental_bookings       WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM rental_bookings       WHERE updated_at    LIKE '%+%' AND updated_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM rental_car_schedules  WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM rental_settings       WHERE updated_at    LIKE '%+%' AND updated_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM rental_services       WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM partner_applications  WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM partner_subscriptions WHERE updated_at    LIKE '%+%' AND updated_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM subscription_invoices WHERE created_at    LIKE '%+%' AND created_at    NOT LIKE '%+07:00'
   UNION ALL SELECT COUNT(*)   FROM tarif                 WHERE updated_at    LIKE '%+%' AND updated_at    NOT LIKE '%+07:00'
          ) t) = 0, 'OK', 'CACAT: ada cap waktu beroffset lain — ALTER akan menolaknya')

UNION ALL
-- ---------------------------------------------------------------------
-- 3. Baris yatim
--
-- Foreign key menolak dipasang selama masih ada anak yang menunjuk induk
-- yang tidak ada. Ini yang paling sering menghentikan migrasi di langkah 4.
-- ---------------------------------------------------------------------
SELECT 'pesanan menunjuk penumpang yang tidak ada',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pesanan — ', GROUP_CONCAT(o.id)))
FROM orders o LEFT JOIN users u ON u.phone_number = o.rider_phone
WHERE o.rider_phone IS NOT NULL AND o.rider_phone <> '' AND u.phone_number IS NULL

UNION ALL
SELECT 'pesanan menunjuk driver yang tidak ada',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pesanan — ', GROUP_CONCAT(o.id)))
FROM orders o LEFT JOIN users u ON u.phone_number = o.driver_phone
WHERE o.driver_phone IS NOT NULL AND o.driver_phone <> '' AND u.phone_number IS NULL

UNION ALL
SELECT 'percakapan menunjuk pesanan yang tidak ada',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pesan'))
FROM chat_messages c LEFT JOIN orders o ON o.id = c.order_id
WHERE c.order_id IS NOT NULL AND o.id IS NULL

UNION ALL
SELECT 'penilaian menunjuk pesanan yang tidak ada',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' penilaian'))
FROM order_ratings r LEFT JOIN orders o ON o.id = r.order_id
WHERE o.id IS NULL

UNION ALL
SELECT 'pengajuan driver menunjuk pengguna yang tidak ada',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pengajuan'))
FROM driver_applications a LEFT JOIN users u ON u.phone_number = a.phone_number
WHERE a.phone_number IS NOT NULL AND a.phone_number <> '' AND u.phone_number IS NULL

UNION ALL
SELECT 'alamat menunjuk pengguna yang tidak ada',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' alamat'))
FROM user_addresses a LEFT JOIN users u ON u.phone_number = a.phone_number
WHERE u.phone_number IS NULL

UNION ALL
-- ---------------------------------------------------------------------
-- 4. Tidak ada pesanan yang sedang berjalan
--
-- Bukan syarat teknis, tapi syarat sopan: layanan mati sekitar semenit saat
-- migrasi, dan pesanan yang sedang jalan berarti ada orang di pinggir jalan.
-- ---------------------------------------------------------------------
SELECT 'tidak ada pesanan berjalan',
       IF(COUNT(*) = 0, 'OK', CONCAT('TUNGGU: ', COUNT(*), ' pesanan masih berjalan'))
FROM orders WHERE status IN ('pending','accepted','picked_up')

UNION ALL
-- ---------------------------------------------------------------------
-- 5. Hasil migrasi — tipe kolom
--
-- Sembilan belas kolom waktu, semuanya harus DATETIME. Sebelum migrasi
-- baris ini memang CACAT.
-- ---------------------------------------------------------------------
SELECT 'kolom waktu DATETIME',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' masih teks — ', GROUP_CONCAT(CONCAT(table_name, '.', column_name))))
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND data_type <> 'datetime'
  AND ((column_name IN ('created_at','updated_at','driver_loc_at','valid_until'))
       OR (table_name = 'chat_messages' AND column_name = 'timestamp'))

UNION ALL
SELECT 'nomor kosong sudah jadi NULL',
       IF(COUNT(*) = 0, 'OK', CONCAT('CACAT: ', COUNT(*), ' pesanan bernomor kosong'))
FROM orders WHERE rider_phone = '' OR driver_phone = ''

UNION ALL
-- ---------------------------------------------------------------------
-- 6. Hasil migrasi — foreign key
--
-- Enam untuk tabel inti, di luar sepuluh yang sudah ada sejak migrasi 001.
-- ---------------------------------------------------------------------
SELECT 'foreign key tabel inti',
       IF(COUNT(*) = 6, 'OK', CONCAT('CACAT: baru ', COUNT(*), ' dari 6 — ', COALESCE(GROUP_CONCAT(constraint_name), 'belum ada')))
FROM information_schema.referential_constraints
WHERE constraint_schema = DATABASE()
  AND constraint_name IN ('orders_ibfk_1','orders_ibfk_2','order_ratings_ibfk_1',
                          'chat_messages_ibfk_1','driver_applications_ibfk_1','user_addresses_ibfk_1')

UNION ALL
SELECT 'pesanan tidak ikut terhapus bersama akun',
       IF(COUNT(*) = 2, 'OK', CONCAT('CACAT: orders memakai ', COALESCE(GROUP_CONCAT(DISTINCT delete_rule), 'entah apa'), ', seharusnya RESTRICT'))
FROM information_schema.referential_constraints
WHERE constraint_schema = DATABASE()
  AND constraint_name IN ('orders_ibfk_1','orders_ibfk_2')
  AND delete_rule = 'RESTRICT';
