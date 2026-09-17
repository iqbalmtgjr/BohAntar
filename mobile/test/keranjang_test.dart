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
}
