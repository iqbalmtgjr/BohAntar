/// Taksiran ongkos di sisi aplikasi.
///
/// Server yang menentukan angka final (lihat `hitungTarif()` di
/// backend/tarif.go). Rumus di sini cuma cermin, supaya penumpang melihat harga
/// yang sama sebelum memesan dengan yang ditagih setelah selesai. Kalau keduanya
/// melenceng, penumpang melihat satu angka lalu dipotong angka lain — jadi
/// rumusnya ditaruh terpisah begini supaya bisa diuji, bukan terkubur di dalam
/// State sebuah layar.
///
/// Angka tarifnya sendiri sekarang tinggal di tabel `tarif` dan bisa diubah
/// super admin. Nilai di bawah adalah cerminan isi awal tabel itu.
///
/// ponytail: nilainya masih tetap di sini. Kalau super admin mengubah tarif,
/// taksiran di aplikasi ikut basi sampai versi berikutnya dirilis — angkanya
/// tetap dikoreksi server saat pesanan dibuat, jadi tidak ada yang tertagih
/// salah, hanya taksirannya yang meleset. Ambil dari endpoint tarif publik kalau
/// perubahan harga sudah sering terjadi.
class Tarif {
  final double base;
  final double perKM;

  const Tarif({required this.base, required this.perKM});

  static const _mobil = Tarif(base: 16000, perKM: 3500);
  static const _motor = Tarif(base: 8000, perKM: 2000);

  /// Tarif yang berlaku untuk sebuah layanan. Layanan tak dikenal jatuh ke
  /// tarif motor, bukan ke nol.
  factory Tarif.untuk(String layanan) => layanan == 'BohCar' ? _mobil : _motor;

  /// Ongkos untuk jarak tertentu, dibulatkan ke ratusan terdekat.
  double hitung(double km) {
    if (km < 0) km = 0;
    return ((base + km * perKM) / 100.0).round() * 100.0;
  }
}
