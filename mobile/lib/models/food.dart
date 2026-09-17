import 'package:latlong2/latlong.dart';
import 'package:mobile/services/api_service.dart';

/// "Rp 48.000" — dipakai semua layar BohFood.
String rupiah(num nilai) =>
    'Rp ${nilai.toStringAsFixed(0).replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (m) => "${m[1]}.")}';

/// URL gambar dari server bisa absolut (tautan luar) atau relatif (/uploads/...).
String urlGambar(String s) => s.startsWith('http') ? s : '${ApiService().baseUrl}$s';

class Warung {
  final String id, nama, alamat, gambar;
  final bool buka;
  final LatLng posisi;
  final double jarakKm; // -1 kalau posisi pemesan tidak diketahui

  Warung.dariJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        nama = (j['restaurant_name'] ?? '').toString(),
        alamat = (j['address'] ?? '').toString(),
        gambar = (j['image_url'] ?? '').toString(),
        buka = j['is_open'] == true,
        posisi = LatLng((j['lat'] as num?)?.toDouble() ?? 0, (j['lng'] as num?)?.toDouble() ?? 0),
        jarakKm = (j['jarak_km'] as num?)?.toDouble() ?? -1;
}

class MenuMakanan {
  final String id, nama, deskripsi, kategori, gambar;
  final double harga;
  final bool tersedia;

  MenuMakanan.dariJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        nama = (j['name'] ?? '').toString(),
        deskripsi = (j['description'] ?? '').toString(),
        kategori = (j['category'] ?? '').toString(),
        gambar = (j['image_url'] ?? '').toString(),
        harga = (j['price'] as num?)?.toDouble() ?? 0,
        tersedia = j['is_available'] == true;
}

class BarisKeranjang {
  final MenuMakanan menu;
  final int jumlah;
  const BarisKeranjang(this.menu, this.jumlah);
  double get subtotal => menu.harga * jumlah;
}

/// Keranjang untuk satu warung. Pindah warung berarti keranjang baru —
/// backend memang tidak menerima dua warung dalam satu pesanan.
class Keranjang {
  final Warung warung;
  final Map<String, BarisKeranjang> _isi = {};

  Keranjang(this.warung);

  int jumlah(MenuMakanan m) => _isi[m.id]?.jumlah ?? 0;

  void tambah(MenuMakanan m) => _isi[m.id] = BarisKeranjang(m, jumlah(m) + 1);

  void kurangi(MenuMakanan m) {
    final n = jumlah(m) - 1;
    if (n <= 0) {
      _isi.remove(m.id);
    } else {
      _isi[m.id] = BarisKeranjang(m, n);
    }
  }

  bool get kosong => _isi.isEmpty;
  int get totalPorsi => _isi.values.fold(0, (a, b) => a + b.jumlah);
  double get subtotal => _isi.values.fold(0.0, (a, b) => a + b.subtotal);
  List<BarisKeranjang> get baris => _isi.values.toList();

  /// Bentuk yang dikirim ke server: id dan jumlah saja. Harga dihitung server
  /// dari menu warung, bukan dari sini.
  List<Map<String, dynamic>> keJson() => [
        for (final b in _isi.values) {'menu_id': b.menu.id, 'qty': b.jumlah},
      ];
}
