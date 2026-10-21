import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:mobile/models/food.dart';
import 'package:mobile/screens/food_menu_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/status_pesanan.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';

/// Layar depan BohFood, meniru GoFood (permintaan user 20 Okt 2026): kepala
/// oranye dengan lokasi dan kolom cari, menu yang lagi banyak dipesan, lalu
/// semua menu dari warung sekitar. Ubin kategori GoFood (New this week, Near
/// me, …) sengaja tidak ditiru — diganti langsung dengan menunya.
///
/// Mengembalikan id pesanan lewat Navigator.pop begitu pesanan jadi di layar
/// konfirmasi, supaya dashboard yang membuka pelacakannya — layar ini tidak
/// perlu tahu ada berapa rute di bawahnya.
class FoodMerchantsScreen extends StatefulWidget {
  final String riderName;
  final String riderPhone;
  const FoodMerchantsScreen({super.key, required this.riderName, required this.riderPhone});

  @override
  State<FoodMerchantsScreen> createState() => _FoodMerchantsScreenState();
}

/// Kenapa posisi pemesan tidak terbaca, supaya spanduknya bisa menawarkan
/// jalan keluar yang tepat.
enum _KendalaLokasi { izin, izinPermanen, gpsMati }

class _FoodMerchantsScreenState extends State<FoodMerchantsScreen> {
  // Menu dimuat per halaman sambil digulir (permintaan user 20 Okt 2026):
  // layar pertama cukup satu halaman, bukan seluruh menu semua warung.
  static const _perHalaman = 10;

  final Map<String, Warung> _warung = {}; // terkumpul dari tiap halaman
  List<MenuMakanan> _menu = [];
  List<MenuMakanan> _populer = [];
  int _halaman = 0;
  bool _adaLagi = false;
  bool _memuat = true;
  bool _memuatLagi = false;
  bool _galatLagi = false;
  String? _galat;
  // Naik tiap kali daftar dimuat dari awal, supaya balasan pencarian lama yang
  // datang belakangan tidak menimpa hasil pencarian baru.
  int _generasi = 0;
  final _cari = TextEditingController();
  String _qDimuat = ''; // kata cari milik daftar yang sedang tampil
  Timer? _jedaCari;
  LatLng? _posisi;
  String? _alamat;
  _KendalaLokasi? _kendala;

  @override
  void initState() {
    super.initState();
    _muat(bacaPosisi: true);
  }

  @override
  void dispose() {
    _jedaCari?.cancel();
    _cari.dispose();
    super.dispose();
  }

  /// Posisi hanya untuk mengurutkan, menulis jarak, dan menghitung ongkir.
  /// Izin TIDAK diminta di sini: kotak izin yang muncul tiba-tiba tanpa alasan
  /// sering ditolak. Pemesan memintanya sendiri lewat spanduk di bawah kolom cari.
  Future<void> _bacaPosisi() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _kendala = _KendalaLokasi.gpsMati;
        return;
      }
      final izin = await Geolocator.checkPermission();
      if (izin == LocationPermission.denied || izin == LocationPermission.deniedForever) {
        _kendala = izin == LocationPermission.denied ? _KendalaLokasi.izin : _KendalaLokasi.izinPermanen;
        return;
      }
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
      _posisi = LatLng(p.latitude, p.longitude);
      _kendala = null;
      _bacaAlamat();
    } catch (_) {}
  }

  /// Nama jalan untuk pil lokasi di kepala, seperti GoFood. Hiasan saja:
  /// gagal berarti pil tetap bertuliskan "Lokasimu".
  Future<void> _bacaAlamat() async {
    try {
      final a = await MapsService().alamatDariTitik(_posisi!);
      if (mounted && a != null && a.trim().isNotEmpty) setState(() => _alamat = a.split(',').first.trim());
    } catch (_) {}
  }

  Future<void> _aktifkanLokasi() async {
    switch (_kendala) {
      case _KendalaLokasi.gpsMati:
        await Geolocator.openLocationSettings();
      case _KendalaLokasi.izinPermanen:
        await Geolocator.openAppSettings();
      case _KendalaLokasi.izin:
        await Geolocator.requestPermission();
      case null:
        break;
    }
    await _muat(bacaPosisi: true);
  }

  /// Satu halaman etalase. Server yang mengurutkan (warung buka → terlaris →
  /// terdekat) dan mencari, jadi urutan antarhalaman tetap.
  Future<(List<MenuMakanan>, bool)> _ambil(int halaman, String q) async {
    final isi = await ApiService().getEtalaseFood(lat: _posisi?.latitude, lng: _posisi?.longitude, q: q, page: halaman, limit: _perHalaman);
    for (final j in (isi['merchants'] as List?) ?? const []) {
      final w = Warung.dariJson(Map<String, dynamic>.from(j as Map));
      _warung[w.id] = w;
    }
    final menu = [
      for (final j in (isi['menus'] as List?) ?? const []) MenuMakanan.dariJson(Map<String, dynamic>.from(j as Map)),
    ].where((m) => _warung.containsKey(m.idWarung)).toList();
    return (menu, isi['ada_lagi'] == true);
  }

  /// Dari halaman pertama: dibuka, ditarik ke bawah, atau kata carinya berubah.
  Future<void> _muat({bool bacaPosisi = false}) async {
    final generasi = ++_generasi;
    final q = _cari.text.trim();
    setState(() {
      _galat = null;
      _galatLagi = false;
      _memuatLagi = false; // halaman lanjutan daftar lama dibuang (lihat _generasi)
      _memuat = true; // daftar lama tetap tampil; lingkaran penuh hanya kalau kosong
    });
    try {
      if (bacaPosisi) await _bacaPosisi();
      final (menu, adaLagi) = await _ambil(1, q);
      if (!mounted || generasi != _generasi) return;
      setState(() {
        _menu = menu;
        _adaLagi = adaLagi;
        _qDimuat = q;
        _halaman = 1;
        // Halaman pertama sudah urut terlaris dari warung yang buka.
        if (q.isEmpty) _populer = menu.where((m) => m.terjual > 0).toList();
        _memuat = false;
      });
    } catch (e) {
      if (!mounted || generasi != _generasi) return;
      setState(() {
        _galat = pesanGalat(e);
        _memuat = false;
      });
    }
  }

  /// Halaman berikutnya, dipanggil saat daftar digulir mendekati ujung.
  Future<void> _muatLagi() async {
    if (_memuat || _memuatLagi || !_adaLagi || _galat != null) return;
    final generasi = _generasi;
    setState(() {
      _memuatLagi = true;
      _galatLagi = false;
    });
    try {
      final (baru, adaLagi) = await _ambil(_halaman + 1, _qDimuat);
      if (!mounted || generasi != _generasi) return;
      // Urutan bisa bergeser sedikit antarhalaman (warung baru buka/tutup),
      // jadi menu yang sudah tampil tidak digambar dua kali.
      final ada = {for (final m in _menu) '${m.idWarung}|${m.id}'};
      setState(() {
        _menu = [..._menu, ...baru.where((m) => !ada.contains('${m.idWarung}|${m.id}'))];
        _adaLagi = adaLagi;
        _halaman++;
        _memuatLagi = false;
      });
    } catch (_) {
      if (!mounted || generasi != _generasi) return;
      setState(() {
        _memuatLagi = false;
        _galatLagi = true;
      });
    }
  }

  void _saatMengetik(String _) {
    setState(() {}); // tombol hapus muncul/hilang
    _jedaCari?.cancel();
    // Menunggu jeda mengetik, bukan satu permintaan per huruf.
    _jedaCari = Timer(const Duration(milliseconds: 400), _muat);
  }

  void _hapusCari() {
    _jedaCari?.cancel();
    _cari.clear();
    _muat();
  }

  Future<void> _buka(MenuMakanan m) async {
    final orderId = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => FoodMenuScreen(warung: _warung[m.idWarung]!, menuAwal: m.id, riderName: widget.riderName, riderPhone: widget.riderPhone),
      ),
    );
    if (orderId != null && mounted) Navigator.pop(context, orderId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // ikon status bar putih di atas oranye
      child: Scaffold(
        body: RefreshIndicator(
          onRefresh: () => _muat(bacaPosisi: true),
          // Halaman berikutnya diminta selagi masih ±dua layar dari ujung,
          // supaya pemesan yang menggulir tidak sempat menunggu.
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 1200) _muatLagi();
              return false;
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _kepala(isDark)),
                if (_kendala != null) SliverToBoxAdapter(child: _spandukLokasi()),
                ..._isi(isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kepala(bool isDark) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 24), // separuh kolom cari menumpang di sini
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 10, 16, 44),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFF97316), AppTheme.warnaFood]),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Tutup',
                      icon: const Icon(Icons.close_rounded, color: AppTheme.textLight),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(child: _pilLokasi()),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Lagi lapar?', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
                        SizedBox(height: 4),
                        Text(
                          'Pesan dari warung sekitarmu, diantar sampai depan pintu.',
                          style: TextStyle(color: Colors.white, fontSize: 13, height: 1.35, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 96,
                    height: 96,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                    child: Image.asset(asetLayanan('BohFood')!, fit: BoxFit.contain),
                  ),
                ],
              ),
            ],
          ),
        ),
        Positioned(left: 16, right: 16, bottom: 0, child: _kolomCari(isDark)),
      ],
    );
  }

  Widget _pilLokasi() {
    final mati = _kendala != null;
    return Material(
      color: Colors.black.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: mati ? _aktifkanLokasi : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mati ? Icons.location_off_rounded : Icons.place_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  mati ? 'Aktifkan lokasi' : _alamat ?? (_memuat ? 'Mencari lokasi…' : 'Lokasimu'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kolomCari(bool isDark) {
    final tepi = OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide.none);
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: TextField(
        controller: _cari,
        onChanged: _saatMengetik,
        onSubmitted: (_) {
          _jedaCari?.cancel();
          _muat();
        },
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Lagi mau makan apa?',
          prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.warnaFood),
          suffixIcon: _cari.text.isEmpty
              ? null
              : IconButton(tooltip: 'Hapus pencarian', icon: const Icon(Icons.close, size: 18), onPressed: _hapusCari),
          filled: false,
          border: tepi,
          enabledBorder: tepi,
          focusedBorder: tepi,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _spandukLokasi() {
    final teks = switch (_kendala!) {
      _KendalaLokasi.gpsMati => 'GPS mati. Nyalakan untuk melihat warung terdekat dan perkiraan ongkir.',
      _ => 'Izinkan lokasi untuk melihat warung terdekat dan perkiraan ongkir.',
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(color: AppTheme.warnaFood.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          const Icon(Icons.my_location, size: 18, color: AppTheme.warnaFood),
          const SizedBox(width: 10),
          Expanded(child: Text(teks, style: const TextStyle(fontSize: 12))),
          TextButton(
            onPressed: _aktifkanLokasi,
            style: TextButton.styleFrom(foregroundColor: AppTheme.teksBerwarna(context, AppTheme.warnaFood)),
            child: Text(_kendala == _KendalaLokasi.izin ? 'Izinkan' : 'Buka pengaturan'),
          ),
        ],
      ),
    );
  }

  List<Widget> _isi(bool isDark) {
    Widget penuh(Widget anak) => SliverFillRemaining(hasScrollBody: false, child: Padding(padding: const EdgeInsets.only(top: 40), child: anak));
    if (_memuat && _menu.isEmpty) return [penuh(const Align(alignment: Alignment.topCenter, child: CircularProgressIndicator()))];
    if (_galat != null) {
      return [penuh(PesanKosong(ikon: Icons.cloud_off, judul: 'Gagal memuat BohFood', teks: _galat!, tombol: 'Coba lagi', saatTekan: () => _muat(bacaPosisi: true)))];
    }
    final q = _qDimuat;
    final menu = _menu;
    if (menu.isEmpty) {
      if (q.isNotEmpty) {
        return [penuh(PesanKosong(ikon: Icons.search_off, judul: 'Tidak ketemu', teks: 'Tidak ada menu atau warung yang cocok dengan "$q".'))];
      }
      return [
        penuh(const PesanKosong(
          ikon: Icons.storefront_outlined,
          judul: 'Belum ada menu yang bisa dipesan',
          teks: 'Menu dari warung yang sudah mengatur lokasinya akan muncul di sini. Tarik ke bawah untuk memuat ulang.',
        )),
      ];
    }
    final populer = q.isEmpty ? _populer : const <MenuMakanan>[];
    return [
      if (populer.isNotEmpty) ...[
        _judul('Lagi banyak dipesan', 'Paling laris 30 hari terakhir'),
        SliverToBoxAdapter(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, m) in populer.indexed) ...[
                    if (i > 0) const SizedBox(width: 12),
                    SizedBox(width: 160, child: _kartu(m, isDark)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
      _judul(q.isEmpty ? 'Semua menu' : 'Hasil untuk "$q"', q.isEmpty ? 'Dari warung di sekitarmu' : '${menu.length}${_adaLagi ? '+' : ''} menu'),
      // Dua kolom; IntrinsicHeight menyamakan tinggi kartu sebaris walau nama
      // menunya ada yang dua baris.
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        sliver: SliverList.separated(
          itemCount: (menu.length + 1) ~/ 2,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _kartu(menu[i * 2], isDark)),
                const SizedBox(width: 12),
                Expanded(child: i * 2 + 1 < menu.length ? _kartu(menu[i * 2 + 1], isDark) : const SizedBox()),
              ],
            ),
          ),
        ),
      ),
      if (_memuatLagi || _galatLagi)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: Center(
              child: _galatLagi
                  ? TextButton.icon(onPressed: _muatLagi, icon: const Icon(Icons.refresh), label: const Text('Gagal memuat menu lainnya. Coba lagi'))
                  : const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          ),
        ),
    ];
  }

  Widget _judul(String judul, String sub) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(judul, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 2),
              Text(sub, style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context))),
            ],
          ),
        ),
      );

  Widget _kartu(MenuMakanan m, bool isDark) => _KartuMenu(m, _warung[m.idWarung]!, isDark: isDark, saatTekan: () => _buka(m));
}

/// Kartu menu: foto, nama, warung + jarak, harga. Seluruh kartu bisa diketuk;
/// tombol + hanya penanda bahwa menu ini bisa langsung dipesan.
class _KartuMenu extends StatelessWidget {
  final MenuMakanan m;
  final Warung w;
  final bool isDark;
  final VoidCallback saatTekan;
  const _KartuMenu(this.m, this.w, {required this.isDark, required this.saatTekan});

  @override
  Widget build(BuildContext context) {
    final redup = AppTheme.teksRedup(context);
    return Opacity(
      opacity: w.buka ? 1 : 0.55,
      child: Material(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
        ),
        child: InkWell(
          onTap: saatTekan,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  AspectRatio(aspectRatio: 4 / 3, child: GambarJaringan(url: m.gambar, pengganti: Icons.fastfood_outlined)),
                  if (!w.buka)
                    Positioned(top: 8, left: 8, child: Pil('Tutup', warna: Colors.grey.shade800))
                  else if (m.terjual > 0)
                    Positioned(top: 8, left: 8, child: Pil('${m.terjual} terjual', warna: AppTheme.warnaFood)),
                  if (w.jarakKm >= 0)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Pil('${w.jarakKm.toStringAsFixed(1).replaceAll('.', ',')} km', warna: Colors.black.withValues(alpha: 0.6)),
                    ),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.nama, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, height: 1.25)),
                      const SizedBox(height: 3),
                      Text(w.nama, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: redup)),
                      const Spacer(),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(m.teksHarga, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                          ),
                          if (w.buka)
                            Container(
                              width: 26,
                              height: 26,
                              decoration: const BoxDecoration(color: AppTheme.warnaFood, shape: BoxShape.circle),
                              child: const Icon(Icons.add_rounded, color: Colors.white, size: 18),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
