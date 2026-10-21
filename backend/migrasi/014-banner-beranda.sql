-- Migrasi 014 — banner beranda aplikasi (diatur dari dashboard: Banner Beranda)
--
-- TIDAK WAJIB. initDB() → siapkanBanner() membuat tabel yang sama dan menanam
-- banner bawaan BohFood, tapi HANYA saat tabelnya baru lahir — banner yang
-- dihapus admin tidak hidup lagi di restart berikutnya. Kalau berkas ini
-- dijalankan lebih dulu, banner bawaannya ikut ditanam di sini.
--
-- Urutannya bebas, sebelum atau sesudah binary baru: banner bawaan hanya
-- ditanam kalau tabelnya masih kosong. (Versi pertama memakai INSERT IGNORE;
-- dijalankan sesudah backend menanam bannernya sendiri — id-nya beda — hasilnya
-- banner BohFood dobel. Terbukti di MySQL lokal 18 Okt 2026.)
--
-- Jalankan:  mysql -u USER -p bohantar < 014-banner-beranda.sql

CREATE TABLE IF NOT EXISTS banner_beranda (
	id VARCHAR(64) PRIMARY KEY,
	judul VARCHAR(80) NOT NULL,
	keterangan VARCHAR(160) NOT NULL DEFAULT '',
	label_tombol VARCHAR(30) NOT NULL DEFAULT '',
	tujuan VARCHAR(10) NOT NULL DEFAULT '',
	url VARCHAR(300) NOT NULL DEFAULT '',
	warna VARCHAR(10) NOT NULL DEFAULT 'biru',
	gambar_url VARCHAR(300) NOT NULL DEFAULT '',
	aktif TINYINT(1) NOT NULL DEFAULT 1,
	urutan INT NOT NULL DEFAULT 0,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	INDEX idx_banner_aktif (aktif, urutan)
) DEFAULT CHARSET=utf8mb4;

INSERT INTO banner_beranda (id, judul, keterangan, label_tombol, tujuan, warna, aktif, urutan)
SELECT 'bn-bawaan-bohfood', 'Tanpa tarif tambahan di BohFood', 'Harga menu sama dengan harga di warung.',
       'Pesan makanan', 'BohFood', 'oranye', 1, 1
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM banner_beranda);

-- Pemeriksaan: satu baris banner bawaan.
SELECT id, judul, aktif FROM banner_beranda;
