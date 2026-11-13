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

// BohCar sedang dan besar beda harga: kedua kelas ditaksir, kartu yang dipilih
// menentukan total, dan kelasnya ikut terkirim supaya server menagih baris
// tarif yang sama dengan yang dilihat penumpang.
void main() {
  testWidgets('memilih mobil besar mengganti harga dan terkirim ke server', (tester) async {
    final inter = FontLoader('Inter');
    for (final w in [400, 500, 600, 700, 900]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$w.ttf'));
    }
    await inter.load();
    GoogleMapsFlutterPlatform.instance = _PetaPalsu();
    final kanal = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    kanal.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    // GPS terbaca di Sintang, jadi titik jemput sudah pasti.
    for (final nama in ['flutter.baseflow.com/geolocator', 'flutter.baseflow.com/geolocator_android']) {
      kanal.setMockMethodCallHandler(MethodChannel(nama), (c) async => switch (c.method) {
            'isLocationServiceEnabled' => true,
            'checkPermission' || 'requestPermission' => 2,
            'getCurrentPosition' || 'getLastKnownPosition' => {
                'latitude': 0.0785, 'longitude': 111.494, 'timestamp': 0, 'accuracy': 5.0, 'altitude': 0.0,
                'heading': 0.0, 'speed': 0.0, 'speed_accuracy': 0.0, 'altitude_accuracy': 0.0, 'heading_accuracy': 0.0,
              },
            _ => null,
          });
    }
    await ApiService().setToken('palsu');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? terkirim;
    final server = MockClient((req) async {
      final p = req.url.path;
      Object? jawab;
      if (p == '/api/maps/autocomplete') {
        jawab = {'suggestions': [{'place_id': 'rsud', 'name': 'RSUD Ade M. Djoen', 'address': 'Jl. Pattimura'}]};
      } else if (p == '/api/maps/place') {
        jawab = {'lat': 0.0601, 'lng': 111.5105, 'name': 'RSUD Ade M. Djoen'};
      } else if (p == '/api/tarif/estimasi') {
        final besar = req.url.queryParameters['kelas'] == 'besar';
        jawab = {'status': 'success', 'rincian': {'km': 4.2, 'ongkos': besar ? 38900 : 30700, 'biaya_jasa': 1000, 'total': besar ? 39900 : 31700}};
      } else if (p == '/api/orders' && req.method == 'POST') {
        terkirim = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"status":"error","error":"cukup sampai di sini"}', 400);
      }
      return jawab == null ? http.Response('{}', 404) : http.Response(jsonEncode(jawab), 200);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: const OrderRideScreen(initialService: 'BohCar', riderName: 'Uji', riderPhone: '+620'),
      ));
      await tester.pump(const Duration(seconds: 1));
      await tester.enterText(find.byType(TextFormField).at(1), 'RSUD');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.tap(find.text('RSUD Ade M. Djoen'));
      await tester.pump(const Duration(milliseconds: 800)); // estimasi ditunda 500 ms
      await tester.tap(find.widgetWithText(ElevatedButton, 'Lihat ongkos'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Maks 4 orang'), findsOneWidget);
      expect(find.text('Maks 6 orang'), findsOneWidget);
      expect(find.textContaining('Pesan BohCar · Rp 31.700'), findsOneWidget, reason: 'bawaan mobil sedang');

      await tester.tap(find.text('Mobil besar'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Pesan BohCar · Rp 39.900'), findsOneWidget, reason: 'harga ikut kelas');

      await tester.tap(find.textContaining('Pesan BohCar'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(terkirim?['kelas'], 'besar');

      await tester.pumpWidget(const SizedBox());
    }, () => server);
  });
}
