import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
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

  test('estimasi menyusut sebanding sisa jarak, dan "Hampir tiba" di ujung', () {
    // ±1,1 km lurus ke timur di khatulistiwa, 10 menit, 1,5 km lewat jalan.
    const awal = LatLng(0, 0), ujung = LatLng(0, 0.01);
    const rute = Rute(titik: [awal, ujung], meter: 1500, detik: 600);

    expect(teksEstimasi(rute, awal), '± 10 menit · 1,5 km');
    expect(teksEstimasi(rute, const LatLng(0, 0.004)), '± 6 menit · 0,9 km');
    expect(teksEstimasi(rute, const LatLng(0, 0.0095)), 'Hampir tiba');
    expect(teksEstimasi(null, awal), isNull);
    expect(teksEstimasi(const Rute(titik: [awal, ujung], meter: 1500), awal), isNull);
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
