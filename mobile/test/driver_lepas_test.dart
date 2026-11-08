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

// Driver melepas pesanan sebelum menjemput, lalu driver lain menerimanya.
// Dulu layar penumpang tetap "Driver menuju" dan, setelah driver baru masuk,
// nama serta nomor untuk Chat/Telepon masih milik driver lama.
void main() {
  testWidgets('pesanan yang dilepas driver kembali mencari, lalu driver baru tampil', (tester) async {
    final inter = FontLoader('Inter');
    for (final w in [400, 500, 600, 700, 900]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$w.ttf'));
    }
    await inter.load();
    GoogleMapsFlutterPlatform.instance = _PetaPalsu();
    final kanal = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    kanal.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    for (final nama in ['flutter.baseflow.com/geolocator', 'flutter.baseflow.com/geolocator_android']) {
      kanal.setMockMethodCallHandler(MethodChannel(nama), (_) async => false);
    }
    await ApiService().setToken('palsu');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Status yang dijawab server: diterima Budi → dilepas → diterima Andi.
    var tahap = 'budi';
    Map<String, dynamic> pesanan() => {
          'id': 'o1', 'service': 'BohRide', 'fare': 15000, 'biaya_jasa': 1000, 'payment_method': 'cash',
          'pickup': 'Jemput', 'dropoff': 'Tujuan',
          'pickup_lat': -0.0784, 'pickup_lng': 111.4933, 'dropoff_lat': -0.07, 'dropoff_lng': 111.498,
          ...switch (tahap) {
            'budi' => {'status': 'accepted', 'driver_name': 'Budi Santoso', 'driver_phone': '+6281'},
            'lepas' => {'status': 'pending', 'driver_name': '', 'driver_phone': ''},
            _ => {'status': 'accepted', 'driver_name': 'Andi Wijaya', 'driver_phone': '+6282'},
          },
        };
    final server = MockClient((req) async {
      if (req.url.path.endsWith('/status')) {
        return http.Response(
            jsonEncode({
              'status': 'success',
              'order': pesanan(),
              if (tahap != 'lepas') 'driver_location': {'lat': -0.085, 'lng': 111.489},
            }),
            200);
      }
      if (req.url.path.endsWith('/drivers/sekitar')) {
        return http.Response(jsonEncode({'status': 'success', 'drivers': []}), 200);
      }
      return http.Response('{}', 404);
    });

    Future<void> tunggu(int detik) async {
      for (var i = 0; i < detik * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: const OrderRideScreen(initialService: 'BohRide', riderName: 'Uji', riderPhone: '+620', initialOrderId: 'o1'),
      ));
      await tunggu(1);
      expect(find.text('Budi Santoso'), findsOneWidget);

      tahap = 'lepas';
      await tunggu(3);
      expect(find.text('Mencari driver'), findsOneWidget, reason: 'judul layar kembali ke pencarian');
      expect(find.text('Budi Santoso'), findsNothing);

      tahap = 'andi';
      await tunggu(3);
      expect(find.text('Andi Wijaya'), findsOneWidget, reason: 'driver baru yang tampil, bukan driver lama');
      expect(find.text('Budi Santoso'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    }, () => server);
  });
}
