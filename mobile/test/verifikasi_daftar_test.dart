import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/verifikasi_wa.dart';

// Verifikasi daftar (19 Nov 2026): nomor lewat WhatsApp ATAU kode di email.
void main() {
  // klienHttp aplikasi global dan dibuat sekali (di tes pertama), jadi kedua
  // tes berbagi satu server palsu; saklarnya waWajib.
  var waWajib = false;
  final server = MockClient((req) async {
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    final jawab = switch (req.url.path) {
      '/api/auth/verifikasi-wa' when req.method == 'POST' =>
        waWajib
            ? {'status': 'success', 'wajib': true, 'kode': '424242', 'wa': '6281100000000', 'teks': 'Kode daftar BohAntar: 424242', 'bisa_email': true}
            : {'status': 'success', 'wajib': false},
      '/api/auth/verifikasi-wa' => {'status': 'success', 'terverifikasi': false},
      '/api/auth/verifikasi-email' when body['kode'] == null => {'status': 'success', 'wajib': true},
      '/api/auth/verifikasi-email' when body['kode'] == '123456' => {'status': 'success', 'terverifikasi': true},
      '/api/auth/verifikasi-email' => {'error': 'Kodenya belum cocok. Cek lagi email dari BohAntar.'},
      _ => null,
    };
    final gagal = jawab == null || jawab.containsKey('error');
    return http.Response(jsonEncode(jawab ?? {}), gagal ? 400 : 200);
  });

  Future<({String wa, String email})?> jalankan(WidgetTester tester) async {
    ({String wa, String email})? hasil;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async => hasil = await verifikasiPendaftaran(context, '+6281234567890', 'budi@contoh.id'),
                  child: const Text('Daftar'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Daftar'));
      await tester.pumpAndSettle();

      if (waWajib) {
        expect(find.text('Verifikasi nomor WhatsApp'), findsOneWidget);
        await tester.tap(find.text('Tidak bisa WhatsApp? Pakai email saja'));
        await tester.pumpAndSettle();
      }

      expect(find.text('Verifikasi email'), findsOneWidget);
      expect(find.textContaining('budi@contoh.id'), findsOneWidget);
      expect(find.text('Kirim ulang kode dalam 60 detik'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '999999');
      await tester.pumpAndSettle();
      expect(find.textContaining('belum cocok'), findsOneWidget);
      expect(hasil, isNull);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
    }, () => server);
    return hasil;
  }

  testWidgets('WA mati, email menyala: kode email diketik lalu dikembalikan', (tester) async {
    waWajib = false;
    expect(await jalankan(tester), (wa: '', email: '123456'));
  });

  testWidgets('WA menyala: pendaftar bisa pindah ke email', (tester) async {
    waWajib = true;
    expect(await jalankan(tester), (wa: '', email: '123456'));
  });
}
