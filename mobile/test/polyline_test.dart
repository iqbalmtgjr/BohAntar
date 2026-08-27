import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/maps_service.dart';

/// Decoder polyline ditulis sendiri ketimbang menambah paket, jadi harus ada
/// yang membuktikan hasilnya benar. Rute yang salah dibongkar berarti garis
/// perjalanan di peta melenceng, dan penumpang tidak punya cara tahu.
void main() {
  test('membongkar contoh baku Google', () {
    // Contoh resmi dari dokumentasi encoded polyline algorithm.
    final titik = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');

    expect(titik.length, 3);
    expect(titik[0].latitude, closeTo(38.5, 0.00001));
    expect(titik[0].longitude, closeTo(-120.2, 0.00001));
    expect(titik[1].latitude, closeTo(40.7, 0.00001));
    expect(titik[1].longitude, closeTo(-120.95, 0.00001));
    expect(titik[2].latitude, closeTo(43.252, 0.00001));
    expect(titik[2].longitude, closeTo(-126.453, 0.00001));
  });

  test('string kosong menghasilkan daftar kosong, bukan galat', () {
    expect(decodePolyline(''), isEmpty);
  });

  test('koordinat belahan selatan dan timur seperti Sintang terbaca benar', () {
    // Sintang ada di lintang negatif dan bujur positif — kombinasi yang paling
    // mudah salah tanda kalau pergeseran bit-nya keliru.
    final titik = decodePolyline('bxo@_zjeS');
    expect(titik.length, 1);
    expect(titik[0].latitude, lessThan(0));
    expect(titik[0].longitude, greaterThan(100));
  });
}
