import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/screens/dashboard_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PetaPalsu extends GoogleMapsFlutterPlatform {
  @override
  Widget buildViewWithConfiguration(int creationId, PlatformViewCreatedCallback onPlatformViewCreated,
          {required MapWidgetConfiguration widgetConfiguration,
          MapConfiguration mapConfiguration = const MapConfiguration(),
          MapObjects mapObjects = const MapObjects()}) =>
      const SizedBox.expand();
}

// Keluhan driver 19 Nov 2026: sesudah MAKANAN SUDAH DIAMBIL tidak ada detail
// rute ke pelanggan. Patokan yang ditempel checkout di ujung alamat terpotong
// ellipsis, tidak ada navigasi, dan app masih minta foto makanan.
void main() {
  testWidgets('BohFood diambil: tanpa foto, patokan tampil, Navigasi ke pelanggan', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // Tanpa Inter tes memakai Ahem yang jauh lebih lebar: baris harga meluber palsu.
    final inter = FontLoader('Inter');
    for (final w in [400, 500, 600, 700, 900]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$w.ttf'));
    }
    await inter.load();
    GoogleMapsFlutterPlatform.instance = _PetaPalsu();
    final kanal = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    kanal.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    for (final nama in ['flutter.baseflow.com/geolocator', 'flutter.baseflow.com/geolocator_android']) {
      kanal.setMockMethodCallHandler(MethodChannel(nama), (c) async => switch (c.method) {
            'isLocationServiceEnabled' => true,
            'checkPermission' || 'requestPermission' => 2,
            _ => null,
          });
    }
    for (final nama in ['flutter.baseflow.com/geolocator_updates', 'flutter.baseflow.com/geolocator_updates_android']) {
      kanal.setMockStreamHandler(EventChannel(nama), MockStreamHandler.inline(onListen: (_, _) {}));
    }
    final dibuka = <String>[];
    kanal.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), (c) async {
      dibuka.add('${(c.arguments as Map)['url']}');
      return true;
    });
    await ApiService().setToken('palsu');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var status = 'accepted';
    Map<String, dynamic> pesanan() => {
          'id': 'o1', 'service': 'BohFood', 'status': status, 'driver_phone': '+6281300000001',
          'rider_name': 'Rina', 'rider_phone': '+6281255500011',
          'pickup': 'Warung Bu Yati', 'dropoff': 'Jalan Lintas Melawi, Baning Kota (Patokan: pagar hijau (depan musala))',
          'pickup_lat': 0.0823639, 'pickup_lng': 111.4843075, 'dropoff_lat': 0.0642123, 'dropoff_lng': 111.5135137,
          'fare': 22000, 'biaya_jasa': 1500, 'payment_method': 'cash', 'food_total': 43000, 'merchant_name': 'Warung Bu Yati',
          'items': [{'name': 'Nasi Goreng', 'qty': 2, 'price': 15000}],
        };
    final server = MockClient((req) async {
      final Object? jawab = switch (req.url.path) {
        '/api/users/profile' => {'status': 'success', 'user': {'name': 'Dede', 'role': 'driver'}, 'kendaraan': 'motor'},
        '/api/orders' => {'status': 'success', 'orders': [pesanan()]},
        '/api/orders/o1/status' => {'status': 'success', 'order': pesanan()},
        '/api/orders/o1/pickup' => () {
            status = 'picked_up';
            return {'status': 'success', 'order': pesanan()};
          }(),
        _ => null,
      };
      return jawab == null ? http.Response('{}', 404) : http.Response(jsonEncode(jawab), 200);
    });

    Future<void> tunggu(int kali) async {
      for (var i = 0; i < kali; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DashboardScreen(name: 'Dede', role: 'driver', phone: '+6281300000001'),
      ));
      await tunggu(6);
      expect(find.text('🏁 Antar ke: Jalan Lintas Melawi, Baning Kota'), findsOneWidget,
          reason: 'patokan dipisah dari alamat, termasuk yang berkurung di dalamnya');

      final tombol = find.text('MAKANAN SUDAH DIAMBIL');
      await tester.ensureVisible(tombol);
      await tester.tap(tombol);
      await tunggu(20);
      expect(find.text('Ambil foto'), findsNothing, reason: 'BohFood tidak minta foto saat diambil');
      expect(status, 'picked_up');
      expect(find.text('Patokan: pagar hijau (depan musala)'), findsOneWidget, reason: 'patokan utuh di bar yang menciut');

      await tester.tap(find.byTooltip('Navigasi Google Maps'));
      await tunggu(1);
      expect(dibuka, ['google.navigation:q=0.0642123,111.5135137&mode=l'], reason: 'navigasi motor ke pelanggan, bukan ke warung');

      await tester.pumpWidget(const SizedBox());
    }, () => server);
  });
}
