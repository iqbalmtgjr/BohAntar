/// Estimasi ongkos yang datang dari server.
///
/// Dulu berkas ini menyimpan rumusnya sendiri lengkap dengan angka buka pintu
/// dan per km sebagai konstanta. Dua hal yang salah dengan itu: angkanya basi
/// begitu super admin mengubah tarif dari dashboard, dan rumusnya harus diubah
/// di dua tempat setiap kali cara menghitungnya berubah — yang sekali waktu
/// pasti lupa, lalu penumpang melihat satu harga dan ditagih harga lain.
///
/// Sekarang yang menghitung cuma `hitungOngkos()` di backend/tarif.go, termasuk
/// jaraknya: jarak versi Geolocator memakai model bumi yang berbeda dan bisa
/// menggeser harga satu langkah penuh di dekat batas jarak dasar.
class EstimasiTarif {
  /// Jarak yang dipakai server menghitung, bukan hasil hitungan di HP.
  final double km;

  /// Ongkos perjalanan saja — sama dengan kolom `fare` di server, dan inilah
  /// yang dibagi dengan driver.
  final double ongkos;

  /// Rupiah tetap yang masuk utuh ke bohAntar, ditambahkan di atas ongkos.
  final double biayaJasa;

  /// Yang benar-benar dibayar penumpang.
  final double total;

  const EstimasiTarif({
    required this.km,
    required this.ongkos,
    required this.biayaJasa,
    required this.total,
  });

  factory EstimasiTarif.dariJson(Map<String, dynamic> json) {
    final r = json['rincian'];
    final m = r is Map ? r : const {};
    double angka(String kunci) => (m[kunci] as num?)?.toDouble() ?? 0;
    return EstimasiTarif(
      km: angka('km'),
      ongkos: angka('ongkos'),
      biayaJasa: angka('biaya_jasa'),
      total: angka('total'),
    );
  }
}
