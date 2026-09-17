-- Migrasi 006 — Top up dompet lewat QRIS Xendit
--
-- TIDAK WAJIB. initDB() membuat tabel yang sama lewat CREATE TABLE IF NOT
-- EXISTS, dan tabel yang sudah ada dilewati diam-diam. Berkas ini ada supaya
-- DDL-nya bisa dicoba di MariaDB produksi lebih dulu, terpisah dari restart
-- backend.
--
-- Jalankan:  mysql -u USER -p bohantar < 006-topup-qris.sql

-- Baris PENDING lahir saat pengguna minta QR, dan baru jadi PAID lewat webhook
-- Xendit. Tabel ini yang membuat webhook bisa ditolak kalau datang dua kali:
-- tanpa dia, satu pembayaran akan menambah saldo berkali-kali karena Xendit
-- mengulang kiriman yang tidak dibalas 200.
--
-- Tanpa foreign key ke users, mengikuti setoran_komisi: catatan pembayaran
-- tetap sah dibaca walau akunnya kelak dihapus.
CREATE TABLE IF NOT EXISTS topup_invoices (
  id VARCHAR(64) PRIMARY KEY,
  phone_number VARCHAR(20) NOT NULL,
  amount DECIMAL(12,2) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  payment_url TEXT,
  created_at DATETIME NOT NULL,
  paid_at DATETIME NULL,
  INDEX idx_topup_phone (phone_number, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Pemeriksaan: 7 kolom, charset utf8mb4, 1 indeks sekunder.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'topup_invoices'
ORDER BY ORDINAL_POSITION;

SELECT TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'topup_invoices';

SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'topup_invoices' AND INDEX_NAME = 'idx_topup_phone'
ORDER BY SEQ_IN_INDEX;
