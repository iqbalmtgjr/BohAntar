import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/widgets/kaca.dart';

// Gelembung menu bawah meluncur ke tab yang dipilih, memanjang di tengah
// jalan, lalu tiba tepat di tab itu dengan lebar normal. Ketukan di tengah
// gerakan melanjutkan dari posisi saat itu, tidak melompat ke tab lama.
void main() {
  testWidgets('gelembung meluncur halus ke tab yang dipilih', (tester) async {
    tester.view.physicalSize = const Size(1200, 400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var aktif = 0;
    late StateSetter ubah;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (_, setState) {
        ubah = setState;
        return Scaffold(
          bottomNavigationBar: NavKaca(
            aktif: aktif,
            saatPilih: (i) => setState(() => aktif = i),
            item: const [
              (ikon: Icons.home, label: 'A', lencana: 0),
              (ikon: Icons.receipt_long, label: 'B', lencana: 0),
              (ikon: Icons.chat_bubble, label: 'C', lencana: 0),
              (ikon: Icons.person, label: 'D', lencana: 0),
            ],
          ),
        );
      }),
    ));
    final gelembung = find.byKey(const ValueKey('gelembung-nav'));
    final lebarTab = tester.getSize(gelembung).width;
    final awal = tester.getCenter(gelembung).dx;

    await tester.tap(find.text('C'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final tengah = tester.getRect(gelembung);
    expect(tengah.center.dx, greaterThan(awal), reason: 'sedang menuju C');
    expect(tengah.width, greaterThan(lebarTab * 1.1), reason: 'memanjang selama bergerak');

    await tester.pumpAndSettle();
    final tiba = tester.getRect(gelembung);
    expect(tiba.center.dx, moreOrLessEquals(awal + 2 * lebarTab, epsilon: 0.5));
    expect(tiba.width, moreOrLessEquals(lebarTab, epsilon: 0.5));

    // Ketukan beruntun: dari C ke A, lalu ke D sebelum sampai.
    ubah(() => aktif = 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final sela = tester.getCenter(gelembung).dx;
    ubah(() => aktif = 3);
    await tester.pump();
    expect(tester.getCenter(gelembung).dx, moreOrLessEquals(sela, epsilon: 2), reason: 'tidak melompat');
    await tester.pumpAndSettle();
    expect(tester.getCenter(gelembung).dx, moreOrLessEquals(awal + 3 * lebarTab, epsilon: 0.5));
  });
}
