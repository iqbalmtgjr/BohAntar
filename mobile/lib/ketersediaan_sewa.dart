// Ketersediaan kendaraan BohRental di aplikasi.
//
// Katalog (/api/rental/katalog) mengirim rentang yang sudah terpakai per
// kendaraan. Aturannya sama dengan bentrokDengan di backend, jadi yang
// dinyatakan bebas di sini tidak ditolak server — dan sebaliknya penyewa tahu
// sebelum mengajukan, bukan setelah ditolak "bertabrakan".

class RentangTerpakai {
  final DateTime mulai;
  final DateTime selesai;

  /// Sewa yang lewat jatuh tempo tapi kendaraannya belum dikembalikan: waktu
  /// bebasnya tidak diketahui, jadi semua tanggal ditolak.
  final bool belumKembali;

  const RentangTerpakai(this.mulai, this.selesai, {this.belumKembali = false});

  static List<RentangTerpakai> dariJson(Object? data) => [
        for (final r in (data as List?) ?? const [])
          if (r is Map && DateTime.tryParse('${r['mulai']}') != null && DateTime.tryParse('${r['selesai']}') != null)
            RentangTerpakai(
              DateTime.parse('${r['mulai']}'),
              DateTime.parse('${r['selesai']}'),
              belumKembali: r['belum_kembali'] == true,
            ),
      ];
}

/// Rentang pertama yang menghalangi sewa [mulai, selesai), atau null kalau bebas.
RentangTerpakai? bentrokSewa(List<RentangTerpakai> daftar, DateTime mulai, DateTime selesai) {
  for (final r in daftar) {
    if (r.belumKembali || (mulai.isBefore(r.selesai) && selesai.isAfter(r.mulai))) return r;
  }
  return null;
}

/// Yang membuat kendaraan tidak tersedia saat [sekarang]: sedang disewa atau
/// belum kembali. Null = tersedia sekarang.
RentangTerpakai? sedangDipakai(List<RentangTerpakai> daftar, DateTime sekarang) {
  for (final r in daftar) {
    if (r.belumKembali || (!sekarang.isBefore(r.mulai) && sekarang.isBefore(r.selesai))) return r;
  }
  return null;
}

/// Hari pertama sejak [dari] (jam ambil [jam]:[menit]) yang bebas untuk [lama]
/// hari, paling jauh [batasHari] ke depan — dipakai sebagai tanggal awal form
/// supaya penyewa tidak disuguhi tanggal yang pasti ditolak.
DateTime? tanggalBebasPertama(List<RentangTerpakai> daftar, DateTime dari, int jam, int menit, int lama, {int batasHari = 90}) {
  for (var i = 0; i <= batasHari; i++) {
    final hari = DateTime(dari.year, dari.month, dari.day + i);
    final mulai = DateTime(hari.year, hari.month, hari.day, jam, menit);
    if (bentrokSewa(daftar, mulai, mulai.add(Duration(days: lama))) == null) return hari;
  }
  return null;
}
