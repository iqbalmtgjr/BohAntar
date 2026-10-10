import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/food.dart';

void main() {
  test('keranjang menjumlah porsi, subtotal, dan membuang baris yang habis dikurangi', () {
    final warung = Warung.dariJson({'id': 'w1', 'restaurant_name': 'Soto', 'lat': -0.07, 'lng': 111.49});
    final soto = MenuMakanan.dariJson({'id': 'soto', 'name': 'Soto Ayam', 'price': 18000, 'is_available': true});
    final teh = MenuMakanan.dariJson({'id': 'teh', 'name': 'Es Teh', 'price': 5000, 'is_available': true});

    final k = Keranjang(warung);
    expect(k.kosong, isTrue);

    k.tambah(soto);
    k.tambah(soto);
    k.tambah(teh);
    expect(k.totalPorsi, 3);
    expect(k.subtotal, 41000);
    expect(k.keJson(), [
      {'menu_id': 'soto', 'qty': 2},
      {'menu_id': 'teh', 'qty': 1},
    ]);

    k.kurangi(teh);
    expect(k.jumlah(teh), 0);
    expect(k.baris.length, 1);
    expect(k.kosong, isFalse);

    expect(rupiah(41000), 'Rp 41.000');
    expect(rupiah(8000), 'Rp 8.000');
  });

  final warungKopi = Warung.dariJson({'id': 'w1', 'restaurant_name': 'Kopi Uji'});
  final tehVarian = MenuMakanan.dariJson({
    'id': 'teh',
    'name': 'Es Teh',
    'price': 5000,
    'is_available': true,
    'option_groups': [
      {
        'id': '1', 'name': 'Rasa', 'type': 'single', 'required': true,
        'options': [{'id': 'manis', 'name': 'Manis', 'price': 0}, {'id': 'lemon', 'name': 'Lemon', 'price': 2000}],
      },
      {
        'id': '2', 'name': 'Ekstra', 'type': 'multiple', 'required': false, 'max': 2,
        'options': [{'id': 'jelly', 'name': 'Jelly', 'price': 1000}, {'id': 'es', 'name': 'Es banyak', 'price': 0}],
      },
    ],
  });
  OpsiMenu opsi(String id) => tehVarian.grup.expand((g) => g.opsi).firstWhere((o) => o.id == id);

  test('varian sama digabung apa pun urutannya, varian beda jadi baris sendiri', () {
    final k = Keranjang(warungKopi)
      ..tambah(tehVarian, [opsi('manis')])
      ..tambah(tehVarian, [opsi('lemon'), opsi('jelly')], 2)
      ..tambah(tehVarian, [opsi('jelly'), opsi('lemon')]);
    expect(k.baris.length, 2);
    expect(k.jumlah(tehVarian), 4);
    expect(k.subtotal, 5000 + 3 * 8000);
    expect(k.keJson()[1], {'menu_id': 'teh', 'qty': 3, 'options': ['lemon', 'jelly']});
  });

  test('kurangi memotong varian yang terakhir ditambahkan', () {
    final k = Keranjang(warungKopi)
      ..tambah(tehVarian, [opsi('manis')])
      ..tambah(tehVarian, [opsi('lemon')]);
    k.kurangi(tehVarian);
    expect(k.baris.single.teksOpsi, 'Manis');
  });

  test('aturan grup sama dengan server', () {
    expect(tehVarian.grup[0].minimal, 1);
    expect(tehVarian.grup[0].batas, 1);
    expect(tehVarian.grup[1].minimal, 0);
    expect(tehVarian.grup[1].batas, 2);
  });

  test('menu yang harganya di varian tidak tampil Rp 0', () {
    final kopi = MenuMakanan.dariJson({
      'id': 'kopi', 'name': 'Kopi', 'price': 0, 'is_available': true,
      'option_groups': [
        {
          'id': '1', 'name': 'Suhu', 'type': 'single', 'required': true,
          'options': [{'id': 'dingin', 'name': 'Dingin', 'price': 10000}, {'id': 'panas', 'name': 'Panas', 'price': 8000}],
        },
        {
          'id': '2', 'name': 'Topping', 'type': 'multiple', 'required': false,
          'options': [{'id': 'boba', 'name': 'Boba', 'price': 3000}],
        },
      ],
    });
    expect(kopi.hargaMulaiDari, 8000);
    expect(kopi.teksHarga, 'mulai Rp 8.000');
    expect(tehVarian.teksHarga, 'mulai Rp 5.000');
    expect(MenuMakanan.dariJson({'id': 's', 'name': 'Soto', 'price': 18000}).teksHarga, 'Rp 18.000');
  });

  test('ubah jumlah satu baris: nol menghapus, tidak lewat batas server', () {
    final k = Keranjang(warungKopi)
      ..tambah(tehVarian, [opsi('manis')])
      ..tambah(tehVarian, [opsi('lemon')], 49);
    final lemon = k.barisMenu(tehVarian).last;
    k.ubah(lemon, 5);
    expect(k.barisMenu(tehVarian).last.jumlah, 49);
    k.ubah(lemon, 1);
    expect(k.barisMenu(tehVarian).last.jumlah, Keranjang.maksPorsi);
    k.ubah(k.barisMenu(tehVarian).first, -1);
    expect(k.baris.single.teksOpsi, 'Lemon');
  });
}
