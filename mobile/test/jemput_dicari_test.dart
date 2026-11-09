import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/screens/order_ride_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';

class _PetaPalsu extends GoogleMapsFlutterPlatform {
  @override
  Widget buildViewWithConfiguration(int creationId, PlatformViewCreatedCallback onPlatformViewCreated,
          {required MapWidgetConfiguration widgetConfiguration,
          MapConfiguration mapConfiguration = const MapConfiguration(),
          MapObjects mapObjects = const MapObjects()}) =>
      const SizedBox.expand();
}

// Orang tua memesan ojek untuk anaknya: titik jemput dicari ("SD Negeri"),
// bukan GPS orang tuanya. Koordinat sekolah itulah yang harus sampai ke server,
// dan selama tulisan jemput belum dipilih dari daftar, pesanan ditahan.
void main() {
  testWidgets('titik jemput dicari seperti tujuan dan dipakai saat memesan', (tester) async {
    // Tanpa Inter, teks digambar dengan font tes yang hurufnya lebar dan baris ongkos luber.
    final inter = FontLoader('Inter');
    for (final w in [400, 500, 600, 700, 900]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$w.ttf'));
    }
    await inter.load();
    GoogleMapsFlutterPlatform.instance = _PetaPalsu();
    final kanal = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    kanal.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    // GPS menyala tapi izin ditolak: tidak ada dialog, titik jemput belum pasti.
    for (final nama in ['flutter.baseflow.com/geolocator', 'flutter.baseflow.com/geolocator_android']) {
      kanal.setMockMethodCallHandler(MethodChannel(nama), (c) async => switch (c.method) {
            'isLocationServiceEnabled' => true,
            'checkPermission' || 'requestPermission' => 0, // denied
            _ => null,
          });
    }
    await ApiService().setToken('palsu');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? pesananTerkirim;
    final server = MockClient((req) async {
      final p = req.url.path, q = req.url.queryParameters;
      Object? jawab;
      if (p == '/api/maps/autocomplete') {
        jawab = {
          'suggestions': q['q']!.startsWith('SD')
              ? [{'place_id': 'sekolah', 'name': 'SD Negeri 1 Sintang', 'address': 'Jl. Pattimura'}]
              : [{'place_id': 'rumah', 'name': 'Perumahan Kapuas Indah', 'address': 'Jl. Lintas Melawi'}],
        };
      } else if (p == '/api/maps/place') {
        jawab = q['place_id'] == 'sekolah'
            ? {'lat': 0.0712, 'lng': 111.4988, 'name': 'SD Negeri 1 Sintang'}
            : {'lat': 0.0601, 'lng': 111.5105, 'name': 'Perumahan Kapuas Indah'};
      } else if (p == '/api/tarif/estimasi') {
        jawab = {'status': 'success', 'rincian': {'km': 2.1, 'ongkos': 10000, 'biaya_jasa': 1000, 'total': 11000}};
      } else if (p == '/api/orders' && req.method == 'POST') {
        pesananTerkirim = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"status":"error","error":"cukup sampai di sini"}', 400);
      }
      return jawab == null ? http.Response('{}', 404) : http.Response(jsonEncode(jawab), 200);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: const OrderRideScreen(initialService: 'BohRide', riderName: 'Ibu Ani', riderPhone: '+620'),
      ));
      await tester.pump(const Duration(seconds: 1));

      final kolomJemput = find.byType(TextFormField).at(0);
      final kolomTujuan = find.byType(TextFormField).at(1);
      final lihatOngkos = find.widgetWithText(ElevatedButton, 'Lihat ongkos');

      await tester.enterText(kolomJemput, 'SD Negeri');
      await tester.pump(const Duration(milliseconds: 600)); // jeda pencarian
      await tester.pump();
      expect(find.text('SD Negeri 1 Sintang'), findsOneWidget, reason: 'saran untuk kolom jemput');

      await tester.tap(find.text('SD Negeri 1 Sintang'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(kolomTujuan, 'Perumahan');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.tap(find.text('Perumahan Kapuas Indah'));
      await tester.pump(const Duration(milliseconds: 800)); // estimasi ditunda 500 ms
      expect(tester.widget<ElevatedButton>(lihatOngkos).onPressed, isNotNull);

      // Jemput diketik ulang tanpa memilih: tombol mati lagi, petunjuk muncul.
      await tester.enterText(kolomJemput, 'xy');
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.widget<ElevatedButton>(lihatOngkos).onPressed, isNull);
      expect(find.textContaining('Pilih titik jemput dari daftar saran'), findsOneWidget);

      // Dipilih lagi dari daftar, lalu pesan.
      await tester.enterText(kolomJemput, 'SD Negeri');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.tap(find.text('SD Negeri 1 Sintang'));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(lihatOngkos);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.textContaining('Pesan BohRide'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(pesananTerkirim, isNotNull, reason: 'pesanan terkirim');
      expect(pesananTerkirim!['pickup'], 'SD Negeri 1 Sintang');
      expect(pesananTerkirim!['pickup_lat'], 0.0712);
      expect(pesananTerkirim!['pickup_lng'], 111.4988);
      expect(pesananTerkirim!['dropoff_lat'], 0.0601);

      await tester.pumpWidget(const SizedBox());
    }, () => server);
  });
}
