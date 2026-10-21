import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/screens/food_merchants_screen.dart';
import 'package:mobile/services/api_service.dart';

// Layar depan BohFood memuat menu per halaman: satu halaman saat dibuka, sisanya
// hanya ketika digulir ke ujung, dan berhenti begitu server bilang habis.
// Pencarian menunggu jeda mengetik lalu mulai lagi dari halaman pertama.
void main() {
  testWidgets('menu BohFood dimuat per halaman sambil digulir', (tester) async {
    final kanal = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    kanal.setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    // GPS mati: layar langsung memuat menu tanpa posisi. Tanpa tiruan ini
    // panggilan plugin tidak pernah selesai di dalam tes.
    for (final nama in ['flutter.baseflow.com/geolocator', 'flutter.baseflow.com/geolocator_android']) {
      kanal.setMockMethodCallHandler(MethodChannel(nama), (_) async => false);
    }
    await ApiService().setToken('palsu');

    final diminta = <Map<String, String>>[];
    final server = MockClient((req) async {
      final q = req.url.queryParameters;
      diminta.add(q);
      final page = int.parse(q['page']!);
      final n = page < 3 ? 10 : 5; // 25 menu: 10 + 10 + 5
      return http.Response(
        jsonEncode({
          'status': 'success',
          'merchants': [
            {'id': 'w1', 'restaurant_name': 'Warung Uji', 'is_open': true, 'lat': -0.07, 'lng': 111.49},
          ],
          'menus': [
            for (var i = 0; i < n; i++)
              {'id': 'm$page-$i', 'merchant_id': 'w1', 'name': 'Menu $page-$i', 'price': 10000, 'is_available': true},
          ],
          'ada_lagi': page < 3,
        }),
        200,
      );
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodMerchantsScreen(riderName: 'Uji', riderPhone: '+620')));
      await tester.pumpAndSettle();
      expect(diminta.map((q) => q['page']), ['1'], reason: 'dibuka = satu halaman saja');
      expect(diminta.first['limit'], '10');

      for (var i = 0; i < 15; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
        await tester.pumpAndSettle();
      }
      expect(diminta.map((q) => q['page']), ['1', '2', '3'], reason: 'digulir sampai habis, tanpa halaman ganda');

      // Kembali ke atas tanpa menarik (menarik di puncak = muat ulang).
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'soto');
      await tester.pump(const Duration(milliseconds: 200));
      expect(diminta.length, 3, reason: 'belum ada permintaan sebelum jeda mengetik');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(diminta.last['q'], 'soto');
      expect(diminta.last['page'], '1');

      await tester.pumpWidget(const SizedBox());
    }, () => server);
  });
}
