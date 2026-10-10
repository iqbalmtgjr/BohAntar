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
  final List<GrupOpsi> grup;

  MenuMakanan.dariJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        nama = (j['name'] ?? '').toString(),
        deskripsi = (j['description'] ?? '').toString(),
        kategori = (j['category'] ?? '').toString(),
        gambar = (j['image_url'] ?? '').toString(),
        harga = (j['price'] as num?)?.toDouble() ?? 0,
        tersedia = j['is_available'] == true,
        grup = [
          for (final g in (j['option_groups'] as List?) ?? const [])
            GrupOpsi.dariJson(Map<String, dynamic>.from(g as Map)),
        ];

  bool get punyaVarian => grup.isNotEmpty;
}

/// Satu kelompok varian ("Suhu", "Topping"). Aturannya sama dengan server
/// (pilihOpsi di backend/food_order.go) — server tetap yang memutuskan.
class GrupOpsi {
  final String id, nama;
  final bool tunggal, wajib;
  final int min, maks;
  final List<OpsiMenu> opsi;

  GrupOpsi.dariJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        nama = (j['name'] ?? '').toString(),
        tunggal = j['type'] == 'single',
        wajib = j['required'] == true,
        min = (j['min'] as num?)?.toInt() ?? 0,
        maks = (j['max'] as num?)?.toInt() ?? 0,
        opsi = [
          for (final o in (j['options'] as List?) ?? const [])
            OpsiMenu.dariJson(Map<String, dynamic>.from(o as Map)),
        ];

  int get minimal => !wajib ? 0 : (tunggal || min < 1 ? 1 : min);

  /// Null berarti tanpa batas.
  int? get batas => tunggal ? 1 : (maks > 1 ? maks : null);

  String get petunjuk {
    if (tunggal) return wajib ? 'Pilih 1' : 'Boleh pilih 1';
    if (batas != null) return minimal > 0 ? 'Pilih $minimal–$batas' : 'Pilih hingga $batas';
    return minimal > 0 ? 'Pilih minimal $minimal' : 'Boleh pilih beberapa';
  }
}

class OpsiMenu {
  final String id, nama;
  final double harga;

  OpsiMenu.dariJson(Map<String, dynamic> j)
      : id = (j['id'] ?? '').toString(),
        nama = (j['name'] ?? '').toString(),
        harga = (j['price'] as num?)?.toDouble() ?? 0;
}

class BarisKeranjang {
  final MenuMakanan menu;
  final List<OpsiMenu> opsi;
  final int jumlah;
  const BarisKeranjang(this.menu, this.opsi, this.jumlah);
  double get hargaSatuan => menu.harga + opsi.fold(0.0, (a, o) => a + o.harga);
  double get subtotal => hargaSatuan * jumlah;
  String get teksOpsi => opsi.map((o) => o.nama).join(', ');
}

/// Keranjang untuk satu warung. Pindah warung berarti keranjang baru —
/// backend memang tidak menerima dua warung dalam satu pesanan.
///
/// Satu baris per kombinasi menu + varian: es teh manis dan es teh lemon dua
/// baris, sama seperti yang dicatat server.
class Keranjang {
  final Warung warung;
  final Map<String, BarisKeranjang> _isi = {};

  Keranjang(this.warung);

  static String _kunci(MenuMakanan m, List<OpsiMenu> opsi) => '${m.id}|${(opsi.map((o) => o.id).toList()..sort()).join(',')}';

  /// Total porsi menu ini, semua varian dijumlah.
  int jumlah(MenuMakanan m) => _isi.values.where((b) => b.menu.id == m.id).fold(0, (a, b) => a + b.jumlah);

  void tambah(MenuMakanan m, [List<OpsiMenu> opsi = const [], int n = 1]) {
    final k = _kunci(m, opsi);
    _isi[k] = BarisKeranjang(m, _isi[k]?.opsi ?? opsi, (_isi[k]?.jumlah ?? 0) + n);
  }

  /// Kurangi satu porsi. Untuk menu bervarian yang berkurang adalah varian
  /// yang paling akhir ditambahkan.
  void kurangi(MenuMakanan m) {
    final kunci = _isi.keys.where((k) => _isi[k]!.menu.id == m.id).toList();
    if (kunci.isEmpty) return;
    final b = _isi[kunci.last]!;
    if (b.jumlah <= 1) {
      _isi.remove(kunci.last);
    } else {
      _isi[kunci.last] = BarisKeranjang(m, b.opsi, b.jumlah - 1);
    }
  }

  bool get kosong => _isi.isEmpty;
  int get totalPorsi => _isi.values.fold(0, (a, b) => a + b.jumlah);
  double get subtotal => _isi.values.fold(0.0, (a, b) => a + b.subtotal);
  List<BarisKeranjang> get baris => _isi.values.toList();

  /// Bentuk yang dikirim ke server: id, jumlah, dan id varian. Harga dihitung
  /// server dari menu warung, bukan dari sini.
  List<Map<String, dynamic>> keJson() => [
        for (final b in _isi.values)
          {
            'menu_id': b.menu.id,
            'qty': b.jumlah,
            if (b.opsi.isNotEmpty) 'options': [for (final o in b.opsi) o.id],
          },
      ];
}
