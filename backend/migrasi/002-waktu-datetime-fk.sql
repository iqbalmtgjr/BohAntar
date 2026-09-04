-- =====================================================================
-- Migrasi 002 — kolom waktu jadi DATETIME, foreign key untuk tabel inti
--
-- Menyelesaikan dua hal yang sengaja ditunda migrasi 001 karena menuntut
-- binary Go yang baru bersamaan: H1 (waktu masih VARCHAR) dan H4 (foreign
-- key tabel inti belum ada).
--
-- BERBEDA DARI 001: skrip ini TIDAK aman dijalankan sambil server melayani.
-- Binary lama menulis "2026-09-04T14:21:12+07:00" — teks beroffset yang
-- ditolak kolom DATETIME. Binary baru menyerahkan time.Time, yang tersimpan
-- salah bentuk kalau kolomnya masih VARCHAR. Keduanya tidak boleh bertemu
-- skema yang salah, jadi urutannya wajib begini:
--
--   1. cd /www/wwwroot/bohantar-backend
--   2. mysqldump -u bohantar -p bohantar > cadangan-sebelum-002.sql
--   3. mysql -u bohantar -p bohantar < migrasi/periksa-002.sql    -- pra-terbang
--   4. pkill -f bohantar-backend                                  -- server berhenti
--   5. mysql -u bohantar -p bohantar < migrasi/002-waktu-datetime-fk.sql
--   6. unggah binary baru; daemon.sh menyalakannya dalam semenit
--   7. mysql -u bohantar -p bohantar < migrasi/periksa-002.sql    -- semua OK
--
-- Layanan mati sekitar semenit antara langkah 4 dan 6. Kerjakan saat tidak
-- ada pesanan berjalan:
--   SELECT COUNT(*) FROM orders WHERE status IN ('pending','accepted','picked_up');
-- harus 0.
--
-- KENAPA TIDAK ADA PENGAMAN TAMBAHAN DI SINI: MySQL sendiri pengamannya.
-- ALTER ke DATETIME menolak nilai yang tidak bisa diubah, dan ADD FOREIGN KEY
-- menolak baris yatim — keduanya menghentikan skrip seketika, sebelum
-- kerusakan sempat terjadi. Kalau satu perintah berhenti di tengah,
-- kembalikan dari cadangan langkah 2; jangan diakali dengan
-- SET FOREIGN_KEY_CHECKS = 0, karena itu cuma menyimpan kerusakannya untuk
-- ditemukan orang lain nanti.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Cap waktu dinormalkan sebelum tipenya diubah
--
-- Isinya sekarang RFC3339: "2026-09-04T14:21:12+07:00". DATETIME tidak
-- menyimpan offset, jadi yang disimpan adalah waktu setempatnya — dan itu
-- tepat justru karena SELURUH baris beroffset +07:00, sezona dengan server.
-- Baris beroffset lain sengaja TIDAK disentuh: biar ALTER di bagian 2 yang
-- menolaknya dengan berisik, daripada waktunya digeser diam-diam.
--
-- String kosong jadi NULL: "belum pernah" bukan tanggal, dan 0000-00-00
-- hanya menyamarkannya jadi tahun nol.
-- ---------------------------------------------------------------------
UPDATE users                 SET created_at    = NULL WHERE created_at    = '';
UPDATE users                 SET driver_loc_at = NULL WHERE driver_loc_at = '';
UPDATE orders                SET created_at    = NULL WHERE created_at    = '';
UPDATE orders                SET updated_at    = NULL WHERE updated_at    = '';
UPDATE order_ratings         SET created_at    = NULL WHERE created_at    = '';
UPDATE driver_applications   SET created_at    = NULL WHERE created_at    = '';
UPDATE chat_messages         SET `timestamp`   = NULL WHERE `timestamp`   = '';
UPDATE food_merchants        SET created_at    = NULL WHERE created_at    = '';
UPDATE rental_cars           SET created_at    = NULL WHERE created_at    = '';
UPDATE rental_bookings       SET created_at    = NULL WHERE created_at    = '';
UPDATE rental_bookings       SET updated_at    = NULL WHERE updated_at    = '';
UPDATE rental_car_schedules  SET created_at    = NULL WHERE created_at    = '';
UPDATE rental_settings       SET updated_at    = NULL WHERE updated_at    = '';
UPDATE rental_services       SET created_at    = NULL WHERE created_at    = '';
UPDATE partner_applications  SET created_at    = NULL WHERE created_at    = '';
UPDATE partner_subscriptions SET updated_at    = NULL WHERE updated_at    = '';
UPDATE subscription_invoices SET created_at    = NULL WHERE created_at    = '';
UPDATE tarif                 SET updated_at    = NULL WHERE updated_at    = '';

UPDATE users                 SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE users                 SET driver_loc_at = REPLACE(LEFT(driver_loc_at, 19), 'T', ' ') WHERE driver_loc_at LIKE '%+07:00';
UPDATE orders                SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE orders                SET updated_at    = REPLACE(LEFT(updated_at, 19), 'T', ' ')    WHERE updated_at    LIKE '%+07:00';
UPDATE order_ratings         SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE driver_applications   SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE chat_messages         SET `timestamp`   = REPLACE(LEFT(`timestamp`, 19), 'T', ' ')   WHERE `timestamp`   LIKE '%+07:00';
UPDATE food_merchants        SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE rental_cars           SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE rental_bookings       SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE rental_bookings       SET updated_at    = REPLACE(LEFT(updated_at, 19), 'T', ' ')    WHERE updated_at    LIKE '%+07:00';
UPDATE rental_car_schedules  SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE rental_settings       SET updated_at    = REPLACE(LEFT(updated_at, 19), 'T', ' ')    WHERE updated_at    LIKE '%+07:00';
UPDATE rental_services       SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE partner_applications  SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE partner_subscriptions SET updated_at    = REPLACE(LEFT(updated_at, 19), 'T', ' ')    WHERE updated_at    LIKE '%+07:00';
UPDATE subscription_invoices SET created_at    = REPLACE(LEFT(created_at, 19), 'T', ' ')    WHERE created_at    LIKE '%+07:00';
UPDATE tarif                 SET updated_at    = REPLACE(LEFT(updated_at, 19), 'T', ' ')    WHERE updated_at    LIKE '%+07:00';


-- ---------------------------------------------------------------------
-- 2. VARCHAR(50) -> DATETIME
--
-- Semuanya boleh NULL. Kolom waktu yang wajib terisi dijaga kode, bukan
-- skema: baris lama yang lahir tanpa cap waktu tidak boleh menghentikan
-- migrasi ini, sementara memaksa NOT NULL menuntut tanggal karangan.
--
-- Kalau salah satu gagal dengan "Incorrect datetime value", masih ada baris
-- berformat lain. Cari dengan:
--   SELECT id, created_at FROM orders WHERE created_at NOT LIKE '____-__-__ __:__:__';
-- ---------------------------------------------------------------------
ALTER TABLE users                 MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE users                 MODIFY COLUMN driver_loc_at DATETIME NULL;
ALTER TABLE orders                MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE orders                MODIFY COLUMN updated_at    DATETIME NULL;
ALTER TABLE order_ratings         MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE driver_applications   MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE chat_messages         MODIFY COLUMN `timestamp`   DATETIME NULL;
ALTER TABLE food_merchants        MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE rental_cars           MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE rental_bookings       MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE rental_bookings       MODIFY COLUMN updated_at    DATETIME NULL;
ALTER TABLE rental_car_schedules  MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE rental_settings       MODIFY COLUMN updated_at    DATETIME NULL;
ALTER TABLE rental_services       MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE partner_applications  MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE partner_subscriptions MODIFY COLUMN updated_at    DATETIME NULL;
ALTER TABLE subscription_invoices MODIFY COLUMN created_at    DATETIME NULL;
ALTER TABLE tarif                 MODIFY COLUMN updated_at    DATETIME NULL;


-- ---------------------------------------------------------------------
-- 3. Nomor kosong jadi NULL
--
-- Foreign key tidak bisa menerima "": tidak ada pengguna bernomor kosong.
-- Satu-satunya cara jujur menulis "belum ada driver" adalah NULL. Kodenya
-- membaca kembali lewat COALESCE(driver_phone, ''), jadi bentuk JSON yang
-- diterima aplikasi tidak berubah sedikit pun.
-- ---------------------------------------------------------------------
UPDATE orders SET driver_phone = NULL WHERE driver_phone = '';
UPDATE orders SET rider_phone  = NULL WHERE rider_phone  = '';


-- ---------------------------------------------------------------------
-- 4. Foreign key untuk tabel inti
--
-- orders memakai RESTRICT, sisanya CASCADE. Pesanan adalah catatan
-- keuangan: menghapus akun tidak boleh ikut menghapus riwayat uangnya. Yang
-- menghapus akun wajib menganonimkan pesanannya lebih dulu —
-- deleteAccountHandler sudah melakukannya (rider_phone dan driver_phone jadi
-- NULL, namanya jadi 'Pengguna dihapus') — dan RESTRICT inilah yang membuat
-- langkah itu tidak bisa dilewati diam-diam.
--
-- Nama constraint sama persis dengan yang dibuat MySQL sendiri dari initDB,
-- supaya database hasil migrasi dan database yang lahir baru tetap kembar.
--
-- Kalau salah satu ditolak dengan errno 1452, ada baris yatim. Cari dulu:
--   SELECT o.id, o.rider_phone FROM orders o
--     LEFT JOIN users u ON u.phone_number = o.rider_phone
--    WHERE o.rider_phone IS NOT NULL AND u.phone_number IS NULL;
-- ---------------------------------------------------------------------
ALTER TABLE orders              ADD CONSTRAINT orders_ibfk_1              FOREIGN KEY (rider_phone)  REFERENCES users(phone_number) ON DELETE RESTRICT;
ALTER TABLE orders              ADD CONSTRAINT orders_ibfk_2              FOREIGN KEY (driver_phone) REFERENCES users(phone_number) ON DELETE RESTRICT;
ALTER TABLE order_ratings       ADD CONSTRAINT order_ratings_ibfk_1       FOREIGN KEY (order_id)     REFERENCES orders(id)          ON DELETE CASCADE;
ALTER TABLE chat_messages       ADD CONSTRAINT chat_messages_ibfk_1       FOREIGN KEY (order_id)     REFERENCES orders(id)          ON DELETE CASCADE;
ALTER TABLE driver_applications ADD CONSTRAINT driver_applications_ibfk_1 FOREIGN KEY (phone_number) REFERENCES users(phone_number) ON DELETE CASCADE;
ALTER TABLE user_addresses      ADD CONSTRAINT user_addresses_ibfk_1      FOREIGN KEY (phone_number) REFERENCES users(phone_number) ON DELETE CASCADE;
