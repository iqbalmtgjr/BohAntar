import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/services/api_service.dart';

// Galat yang sampai ke layar harus kalimat yang dimengerti pemakai, bukan
// "ClientException with SocketException … port = 49356, uri=…".
void main() {
  test('galat jaringan, server mati, dan galat bawaan jadi kalimat ramah', () async {
    late http.Response Function() balasan;
    final server = MockClient((_) async => balasan());

    await http.runWithClient(() async {
      Future<String> coba() => ApiService().getBanner().then((_) => 'tidak galat', onError: (Object e) => pesanGalat(e));

      // Persis kasus di HP: koneksi ditolak.
      balasan = () => throw http.ClientException(
          'SocketException: Connection refused (OS Error: Connection refused, errno = 111), address = bohantar.indotechconsulting.com, port = 49356');
      expect(await coba(), 'Tidak bisa terhubung ke server. Cek koneksi internet, lalu coba lagi.');

      // Backend mati: nginx/Cloudflare membalas halaman HTML 502.
      balasan = () => http.Response('<html><body>502 Bad Gateway</body></html>', 502);
      expect(await coba(), 'Server sedang gangguan. Coba lagi beberapa saat lagi.');

      // Pesan dari server diteruskan apa adanya.
      balasan = () => http.Response('{"error":"Warung sedang tutup"}', 400);
      expect(await coba(), 'Warung sedang tutup');

      balasan = () => http.Response('{"error":"Token otorisasi diperlukan"}', 401);
      expect(await coba(), 'Sesi sudah berakhir. Silakan keluar, lalu masuk lagi.');
    }, () => server);

    expect(pesanGalat(TimeoutException('lambat')), 'Server tidak menjawab. Cek koneksi internet, lalu coba lagi.');
    expect(pesanGalat(const SocketException('Failed host lookup')), contains('Cek koneksi internet'));
    expect(pesanGalat(const FormatException('Unexpected character')), 'Terjadi kesalahan. Coba lagi sebentar, ya.');
  });
}
