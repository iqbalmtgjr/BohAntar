import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/tarif.dart';

/// Taksiran di aplikasi harus menghasilkan angka yang sama dengan
/// `hitungTarif()` di backend/tarif.go. Kalau salah satunya diubah tanpa yang
/// lain, penumpang melihat satu harga lalu dipotong harga yang berbeda — test
/// ini yang seharusnya gagal duluan.
void main() {
  test('rumusnya sama dengan server: base + km x perKM, bulat ke ratusan', () {
    // BohRide 8.000 + 2.000/km
    expect(Tarif.untuk('BohRide').hitung(0), 8000);
    expect(Tarif.untuk('BohRide').hitung(5), 18000);
    expect(Tarif.untuk('BohRide').hitung(3.3), 14600);

    // BohCar 16.000 + 3.500/km
    expect(Tarif.untuk('BohCar').hitung(0), 16000);
    expect(Tarif.untuk('BohCar').hitung(5), 33500);
  });

  test('selalu bulat ke ratusan', () {
    for (final km in [0.7, 1.234, 3.3, 8.88, 12.345]) {
      for (final layanan in ['BohRide', 'BohCar', 'BohAntar', 'BohSend']) {
        final hasil = Tarif.untuk(layanan).hitung(km);
        expect(hasil % 100, 0, reason: '$layanan $km km menghasilkan $hasil');
      }
    }
  });

  test('mobil selalu lebih mahal dari motor pada jarak yang sama', () {
    for (final km in [0.0, 1.0, 5.0, 20.0]) {
      expect(
        Tarif.untuk('BohCar').hitung(km),
        greaterThan(Tarif.untuk('BohRide').hitung(km)),
      );
    }
  });

  test('layanan tak dikenal jatuh ke tarif motor, bukan ke nol', () {
    expect(Tarif.untuk('LayananKarangan').hitung(5), Tarif.untuk('BohRide').hitung(5));
    expect(Tarif.untuk('').hitung(0), greaterThan(0));
  });

  test('jarak negatif tidak pernah menghasilkan ongkos di bawah tarif dasar', () {
    expect(Tarif.untuk('BohRide').hitung(-5), 8000);
  });

  test('ongkos naik seiring jarak', () {
    var sebelumnya = 0.0;
    for (final km in [0.0, 1.0, 2.0, 10.0, 50.0]) {
      final sekarang = Tarif.untuk('BohRide').hitung(km);
      expect(sekarang, greaterThan(sebelumnya));
      sebelumnya = sekarang;
    }
  });
}
