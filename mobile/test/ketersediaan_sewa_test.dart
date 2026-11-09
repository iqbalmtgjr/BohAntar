import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ketersediaan_sewa.dart';

void main() {
  final terpakai = RentangTerpakai.dariJson([
    {'mulai': '2026-11-12 08:00:00', 'selesai': '2026-11-14 08:00:00'},
    {'mulai': 'rusak', 'selesai': '2026-11-14 08:00:00'}, // dibuang, bukan bikin galat
  ]);
  DateTime t(int hari, int jam) => DateTime(2026, 11, hari, jam);

  test('bentrok hanya bila beririsan; bersentuhan di ujung boleh (sama dengan backend)', () {
    expect(terpakai, hasLength(1));
    expect(bentrokSewa(terpakai, t(13, 8), t(15, 8)), isNotNull);
    expect(bentrokSewa(terpakai, t(10, 8), t(20, 8)), isNotNull);
    expect(bentrokSewa(terpakai, t(14, 8), t(15, 8)), isNull);
    expect(bentrokSewa(terpakai, t(11, 8), t(12, 8)), isNull);
  });

  test('kendaraan yang belum kembali menolak tanggal berapa pun', () {
    final belum = RentangTerpakai.dariJson([
      {'mulai': '2026-11-01 08:00:00', 'selesai': '2026-11-03 08:00:00', 'belum_kembali': true},
    ]);
    expect(bentrokSewa(belum, t(25, 8), t(26, 8)), isNotNull);
    expect(sedangDipakai(belum, t(25, 8))?.belumKembali, isTrue);
    expect(tanggalBebasPertama(belum, t(10, 0), 8, 0, 1), isNull);
  });

  test('status sekarang dan tanggal bebas pertama untuk form', () {
    expect(sedangDipakai(terpakai, t(13, 9)), isNotNull);
    expect(sedangDipakai(terpakai, t(14, 9)), isNull);
    // Mulai 11 Nov jam 08.00 selama 1 hari: bersentuhan, jadi 11 Nov masih bebas.
    expect(tanggalBebasPertama(terpakai, t(11, 0), 8, 0, 1), DateTime(2026, 11, 11));
    // Dua hari dari 11 Nov bentrok; 12 dan 13 juga; 14 Nov jam 08.00 bebas.
    expect(tanggalBebasPertama(terpakai, t(11, 0), 8, 0, 2), DateTime(2026, 11, 14));
  });
}
