import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/widgets/dialog_alasan.dart';

void main() {
  // Membuka dialog dan mengembalikan Future hasilnya.
  Future<Future<String?>> buka(WidgetTester tester) async {
    late Future<String?> hasil;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => hasil = pilihAlasan(ctx,
              judul: 'Batalkan?', isi: 'Kenapa?', pilihan: const ['Berubah pikiran', alasanLainnya], tombol: 'Ya, batalkan'),
          child: const Text('buka'),
        ),
      ),
    ));
    await tester.tap(find.text('buka'));
    await tester.pumpAndSettle();
    return hasil;
  }

  TextButton tombolYa(WidgetTester tester) =>
      tester.widget<TextButton>(find.ancestor(of: find.text('Ya, batalkan'), matching: find.byType(TextButton)));

  testWidgets('tombol mati sampai alasan dipilih; pilihan jadi hasil', (tester) async {
    final hasil = await buka(tester);
    expect(tombolYa(tester).onPressed, isNull);
    await tester.tap(find.text('Berubah pikiran'));
    await tester.pump();
    expect(tombolYa(tester).onPressed, isNotNull);
    await tester.tap(find.text('Ya, batalkan'));
    await tester.pumpAndSettle();
    expect(await hasil, 'Berubah pikiran');
  });

  testWidgets('Lainnya: ketikan jadi alasan, kosong tetap "Lainnya"', (tester) async {
    var hasil = await buka(tester);
    await tester.tap(find.text(alasanLainnya));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  Hujan deras ');
    await tester.tap(find.text('Ya, batalkan'));
    await tester.pumpAndSettle();
    expect(await hasil, 'Hujan deras');

    hasil = await buka(tester);
    await tester.tap(find.text(alasanLainnya));
    await tester.pump();
    await tester.tap(find.text('Ya, batalkan'));
    await tester.pumpAndSettle();
    expect(await hasil, alasanLainnya);
  });

  testWidgets('ditutup tanpa memilih = null (tidak jadi)', (tester) async {
    final hasil = await buka(tester);
    await tester.tap(find.text('Jangan'));
    await tester.pumpAndSettle();
    expect(await hasil, isNull);
  });
}
