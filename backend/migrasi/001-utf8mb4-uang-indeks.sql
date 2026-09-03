-- =====================================================================
-- Migrasi 001 — charset, tipe uang, indeks, dan batasan nilai
--
-- Aman dijalankan pada database yang sedang melayani: tidak ada kolom yang
-- dihapus, tidak ada nama yang berubah, dan tidak satu pun baris kode Go
-- perlu ikut berubah. DECIMAL tetap terbaca sebagai float64 oleh
-- database/sql, jadi binary yang sedang berjalan pun tidak terganggu.
--
-- SEBELUM MENJALANKAN:
--   mysqldump -u bohantar -p bohantar > cadangan-sebelum-001.sql
--   mysql -u bohantar -p -e "SELECT VERSION();"   -- CHECK butuh MySQL 8.0.16+
--
-- MENJALANKAN:
--   mysql -u bohantar -p bohantar < 001-utf8mb4-uang-indeks.sql
--
-- Yang TIDAK dikerjakan di sini karena menuntut perubahan kode Go
-- bersamaan: kolom waktu masih VARCHAR(50) berisi RFC3339, dan foreign key
-- untuk tabel inti masih kosong. Keduanya menunggu migrasi 002.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. utf8mb3 -> utf8mb4
--
-- utf8mb3 tidak muat karakter 4 byte. Satu emoji di pesan chat atau di nama
-- merchant membuat INSERT-nya ditolak dengan "Incorrect string value" —
-- pesan penggunanya hilang, dan penyebabnya tidak kelihatan dari aplikasi.
--
-- Foreign key harus dilepas dulu, bukan sekadar dimatikan dengan
-- SET FOREIGN_KEY_CHECKS = 0: sebagian versi MySQL tetap menolak mengubah
-- charset kolom yang sedang dipakai foreign key, dengan atau tanpa saklar
-- itu (ERROR 1833). Nama yang dilepas dan dipasang kembali sama persis
-- dengan yang dibuat MySQL sendiri, supaya database hasil migrasi ini dan
-- database yang lahir baru dari initDB tetap kembar.
--
-- Kalau perintah DROP di bawah mengeluh namanya tidak ada, periksa dulu
-- nama sungguhan di servermu, lalu sesuaikan:
--   SELECT constraint_name, table_name, column_name, referenced_table_name
--   FROM information_schema.key_column_usage
--   WHERE table_schema = 'bohantar' AND referenced_table_name IS NOT NULL;
-- ---------------------------------------------------------------------
ALTER DATABASE bohantar CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE food_menus            DROP FOREIGN KEY food_menus_ibfk_1;
ALTER TABLE food_merchants        DROP FOREIGN KEY food_merchants_ibfk_1;
ALTER TABLE partner_subscriptions DROP FOREIGN KEY partner_subscriptions_ibfk_1;
ALTER TABLE rental_bookings       DROP FOREIGN KEY rental_bookings_ibfk_1;
ALTER TABLE rental_bookings       DROP FOREIGN KEY rental_bookings_ibfk_2;
ALTER TABLE rental_car_schedules  DROP FOREIGN KEY rental_car_schedules_ibfk_1;
ALTER TABLE rental_cars           DROP FOREIGN KEY rental_cars_ibfk_1;
ALTER TABLE rental_services       DROP FOREIGN KEY rental_services_ibfk_1;
ALTER TABLE rental_settings       DROP FOREIGN KEY rental_settings_ibfk_1;
ALTER TABLE subscription_invoices DROP FOREIGN KEY subscription_invoices_ibfk_1;

ALTER TABLE users                 CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE user_addresses        CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE orders                CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE order_ratings         CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE chat_messages         CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE driver_applications   CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE food_merchants        CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE food_menus            CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE rental_cars           CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE rental_bookings       CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE rental_car_schedules  CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE rental_settings       CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE rental_services       CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE partner_applications  CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE partner_subscriptions CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE subscription_invoices CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE tarif                 CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Dipasang kembali dengan nama, kolom, dan perilaku hapus yang sama persis
-- seperti sebelumnya. Kalau salah satu ditolak, berarti ada baris yatim yang
-- menunjuk pengguna atau mobil yang sudah tidak ada — cari dan bereskan dulu,
-- jangan dipaksa lewat SET FOREIGN_KEY_CHECKS = 0, karena itu cuma menyimpan
-- kerusakannya untuk ditemukan orang lain nanti.
ALTER TABLE food_merchants        ADD CONSTRAINT food_merchants_ibfk_1        FOREIGN KEY (owner_phone)    REFERENCES users(phone_number)   ON DELETE CASCADE;
ALTER TABLE food_menus            ADD CONSTRAINT food_menus_ibfk_1            FOREIGN KEY (merchant_id)    REFERENCES food_merchants(id)    ON DELETE CASCADE;
ALTER TABLE rental_cars           ADD CONSTRAINT rental_cars_ibfk_1           FOREIGN KEY (owner_phone)    REFERENCES users(phone_number)   ON DELETE CASCADE;
ALTER TABLE rental_bookings       ADD CONSTRAINT rental_bookings_ibfk_1       FOREIGN KEY (car_id)         REFERENCES rental_cars(id)       ON DELETE CASCADE;
ALTER TABLE rental_bookings       ADD CONSTRAINT rental_bookings_ibfk_2       FOREIGN KEY (customer_phone) REFERENCES users(phone_number)   ON DELETE CASCADE;
ALTER TABLE rental_car_schedules  ADD CONSTRAINT rental_car_schedules_ibfk_1  FOREIGN KEY (car_id)         REFERENCES rental_cars(id)       ON DELETE CASCADE;
ALTER TABLE rental_settings       ADD CONSTRAINT rental_settings_ibfk_1       FOREIGN KEY (owner_phone)    REFERENCES users(phone_number)   ON DELETE CASCADE;
ALTER TABLE rental_services       ADD CONSTRAINT rental_services_ibfk_1       FOREIGN KEY (owner_phone)    REFERENCES users(phone_number)   ON DELETE CASCADE;
ALTER TABLE partner_subscriptions ADD CONSTRAINT partner_subscriptions_ibfk_1 FOREIGN KEY (phone_number)   REFERENCES users(phone_number)   ON DELETE CASCADE;
ALTER TABLE subscription_invoices ADD CONSTRAINT subscription_invoices_ibfk_1 FOREIGN KEY (phone_number)   REFERENCES users(phone_number)   ON DELETE CASCADE;


-- ---------------------------------------------------------------------
-- 2. Uang: DOUBLE -> DECIMAL
--
-- DOUBLE tidak menyimpan pecahan desimal dengan tepat. Saldo dompet yang
-- ditambah dan dikurangi ratusan kali perlahan meleset, dan selisih yang
-- muncul di laporan keuangan tidak bisa dijelaskan ke siapa pun.
--
-- Kode Go tidak perlu diubah: driver MySQL mengirim DECIMAL sebagai teks
-- dan database/sql mengurainya ke float64 persis seperti sebelumnya.
-- ---------------------------------------------------------------------
ALTER TABLE users
  MODIFY COLUMN balance DECIMAL(14,2) NOT NULL DEFAULT 0,
  MODIFY COLUMN rating  DECIMAL(3,2)  NOT NULL DEFAULT 0;

ALTER TABLE orders
  MODIFY COLUMN fare   DECIMAL(12,2) NOT NULL DEFAULT 0,
  MODIFY COLUMN komisi DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE food_menus
  MODIFY COLUMN price DECIMAL(12,2) NOT NULL;

ALTER TABLE rental_cars
  MODIFY COLUMN price_per_day DECIMAL(12,2) NOT NULL;

ALTER TABLE rental_bookings
  MODIFY COLUMN total_price DECIMAL(12,2) NOT NULL,
  MODIFY COLUMN late_fee    DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE rental_car_schedules
  MODIFY COLUMN late_fee DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE rental_services
  MODIFY COLUMN price DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE rental_settings
  MODIFY COLUMN late_fee_value DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE subscription_invoices
  MODIFY COLUMN amount DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE tarif
  MODIFY COLUMN base          DECIMAL(12,2) NOT NULL,
  MODIFY COLUMN per_km        DECIMAL(12,2) NOT NULL,
  MODIFY COLUMN komisi_persen DECIMAL(5,2)  NOT NULL DEFAULT 20;


-- ---------------------------------------------------------------------
-- 3. Indeks
--
-- Diturunkan dari query yang benar-benar ada di kode, bukan dari tebakan.
-- Empat indeks pertama sudah dipasang tangan di produksi 3 September 2026,
-- tapi tetap ditulis di sini supaya berkas ini utuh sendiri: mesin baru
-- cukup menjalankan satu berkas. Indeks yang sudah ada ditolak dengan
-- "Duplicate key name" — abaikan, lanjutkan.
-- ---------------------------------------------------------------------

-- orders tabel terpanas: driver menariknya tiap tiga detik, penumpang
-- membuka riwayatnya, dan goroutine kedaluwarsa menyapu yang pending.
CREATE INDEX idx_orders_status ON orders (status, created_at);
CREATE INDEX idx_orders_driver ON orders (driver_phone);
CREATE INDEX idx_orders_rider  ON orders (rider_phone);

-- Seluruh percakapan satu pesanan, dibaca setiap kali ruang chat dibuka.
CREATE INDEX idx_chat_order ON chat_messages (order_id);

-- fcm.go menyiarkan orderan hanya ke driver yang siaga, dan dashboard
-- menghitung pengguna per peran. Keduanya menyaring lewat role.
CREATE INDEX idx_users_role ON users (role, is_driver_active);

-- Dashboard membuka daftar pengajuan yang menunggu, terbaru lebih dulu.
CREATE INDEX idx_driver_apps_status  ON driver_applications  (status, created_at);
CREATE INDEX idx_partner_apps_status ON partner_applications (status, created_at);

-- Pemeriksaan bentrok sewa: satu mobil, satu rentang waktu.
CREATE INDEX idx_bookings_mobil  ON rental_bookings      (car_id, start_time, end_time);
CREATE INDEX idx_schedules_mobil ON rental_car_schedules (car_id, start_time, end_time);

-- Riwayat tagihan langganan satu mitra.
CREATE INDEX idx_invoices_mitra ON subscription_invoices (phone_number, created_at);


-- ---------------------------------------------------------------------
-- 4. Batasan nilai
--
-- Sebelum ini, 'cancelled' yang salah ketik jadi 'canceled' diterima tanpa
-- keluhan, lalu pesanannya lenyap dari setiap filter dan tidak ada yang
-- tahu ke mana ia hilang. Daftar di bawah persis yang ditulis kode hari
-- ini — tidak ada nilai lain yang pernah masuk.
--
-- Butuh MySQL 8.0.16 ke atas. Versi lama menerima perintahnya lalu
-- mengabaikannya diam-diam; tidak merusak apa pun.
-- ---------------------------------------------------------------------
ALTER TABLE orders
  ADD CONSTRAINT chk_orders_status CHECK (
    status IN ('pending','accepted','picked_up','completed','cancelled','expired')),
  ADD CONSTRAINT chk_orders_payment CHECK (
    payment_method IN ('wallet','cash'));

ALTER TABLE users
  ADD CONSTRAINT chk_users_role CHECK (
    role IN ('rider','driver','admin','food_merchant','rental_partner'));

ALTER TABLE order_ratings
  ADD CONSTRAINT chk_rating_bintang CHECK (stars BETWEEN 1 AND 5);

ALTER TABLE tarif
  ADD CONSTRAINT chk_tarif_masuk_akal CHECK (
    base >= 0 AND per_km >= 0 AND komisi_persen BETWEEN 0 AND 100);


-- ---------------------------------------------------------------------
-- 5. Periksa hasilnya
-- ---------------------------------------------------------------------
-- SELECT @@character_set_database, @@collation_database;
-- SHOW INDEX FROM orders;
-- SHOW CREATE TABLE orders\G
