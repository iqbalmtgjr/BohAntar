import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/screens/dashboard_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Bagian bawah beranda pelanggan (10 Nov 2026, dulu kosong): menu dari warung
// yang buka saja, lalu pesanan terakhir tanpa yang masih berjalan (pesanan
// berjalan sudah punya kartunya sendiri di atas grid).
void main() {
  testWidgets('beranda: menu warung tutup disaring, pesanan berjalan tidak dobel', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    await ApiService().setToken('palsu');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Map<String, dynamic> pesanan(String id, String status, String tujuan) =>
        {'id': id, 'service': 'BohRide', 'status': status, 'pickup': 'Rumah', 'dropoff': tujuan, 'fare': 12000};
    final server = MockClient((req) async {
      final jawab = switch (req.url.path) {
        '/api/users/profile' => {'status': 'success', 'user': {'name': 'Siti', 'role': 'rider'}},
        '/api/orders' => {
            'status': 'success',
            'orders': [
              pesanan('o1', 'accepted', 'Tujuan Berjalan'),
              for (var i = 2; i <= 5; i++) pesanan('o$i', 'completed', 'Tujuan Lama $i'),
            ],
          },
        '/api/food/merchants' => {
            'status': 'success',
            'merchants': [
              {'id': 'w1', 'restaurant_name': 'Warung Buka', 'is_open': true},
              {'id': 'w2', 'restaurant_name': 'Warung Tutup', 'is_open': false},
            ],
            'menus': [
              {'id': 'm1', 'merchant_id': 'w1', 'name': 'Soto Ayam', 'price': 18000, 'terjual': 4, 'is_available': true},
              {'id': 'm2', 'merchant_id': 'w2', 'name': 'Bakso Tutup', 'price': 15000, 'terjual': 9, 'is_available': true},
            ],
          },
        _ => null,
      };
      return jawab == null ? http.Response('{}', 404) : http.Response(jsonEncode(jawab), 200);
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: const DashboardScreen(name: 'Siti', role: 'rider', phone: '+6281200000002'),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.text('Lagi banyak dipesan'), findsOneWidget);
      expect(find.text('Soto Ayam'), findsOneWidget);
      expect(find.text('Bakso Tutup'), findsNothing, reason: 'warung tutup tidak dipajang di beranda');

      expect(find.text('Terakhir kamu pesan'), findsOneWidget);
      expect(find.text('Tujuan Berjalan'), findsNothing, reason: 'pesanan berjalan sudah ada kartunya di atas grid');
      expect(find.text('Tujuan Lama 2'), findsOneWidget);
      expect(find.text('Tujuan Lama 4'), findsOneWidget);
      expect(find.text('Tujuan Lama 5'), findsNothing, reason: 'cukup tiga pesanan terakhir');

      await tester.pumpWidget(const SizedBox());
    }, () => server);
  });
}
