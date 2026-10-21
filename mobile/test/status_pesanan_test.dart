import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/status_pesanan.dart';

void main() {
  const layanan = ['BohRide', 'BohCar', 'BohFood', 'BohSend', 'BohAntar'];
  const status = ['pending', 'searching', 'accepted', 'picked_up', 'completed', 'cancelled', 'expired'];

  test('kabar yang diminta pemesan muncul di keadaan yang tepat', () {
    expect(kabarPesanan('BohRide', 'searching').judul, 'Tunggu sebentar ya, lagi cari driver');
    expect(kabarPesanan('BohRide', 'accepted').judul, 'Driver menuju ke tempatmu');
    expect(kabarPesanan('BohRide', 'picked_up').judul, 'Driver sedang antar kamu');
    expect(kabarPesanan('BohRide', 'picked_up', dekat: true).judul, 'Sebentar lagi sampai');
    expect(kabarPesanan('BohFood', 'picked_up', dekat: true).judul, 'Siap-siap ambil pesananmu ya!');
    expect(kabarPesanan('BohFood', 'accepted', warung: 'Soto Bu Ani').judul, contains('Soto Bu Ani'));
  });

  test('setiap layanan dan status punya kabar, dan "dekat" hanya mengubah yang sedang di jalan', () {
    for (final l in layanan) {
      for (final s in status) {
        final biasa = kabarPesanan(l, s);
        expect(biasa.judul, isNotEmpty, reason: '$l/$s');
        expect(biasa.keterangan, isNotEmpty, reason: '$l/$s');
        final dekat = kabarPesanan(l, s, dekat: true);
        expect(dekat.judul != biasa.judul, s == 'accepted' || s == 'picked_up', reason: '$l/$s');
      }
    }
  });

  test('tahap maju searah dengan status, dan selesai berarti semua tahap lewat', () {
    expect(tahapAktif('pending'), tahapAktif('searching'));
    expect(tahapAktif('pending') < tahapAktif('accepted'), isTrue);
    expect(tahapAktif('accepted') < tahapAktif('picked_up'), isTrue);
    for (final l in layanan) {
      expect(tahapAktif('completed'), tahapanPesanan(l).length, reason: l);
    }
  });

  test('lencana riwayat tidak pernah menampilkan status mentah dari server', () {
    for (final s in status) {
      expect(labelStatus(s), isNot(s), reason: s);
    }
    expect(jenisPesanan('BohAntar'), JenisPesanan.barang); // pesanan lama
  });
}
