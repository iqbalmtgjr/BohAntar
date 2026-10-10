import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/screens/food_menu_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';

/// Pilih warung.
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
  List<Warung> _warung = [];
  bool _memuat = true;
  bool _mencari = false;
  String? _galat;
  String _cari = '';
  Timer? _jedaCari;
  LatLng? _posisi;
  _KendalaLokasi? _kendala;

  @override
  void initState() {
    super.initState();
    _muat(bacaPosisi: true);
  }

  @override
  void dispose() {
    _jedaCari?.cancel();
    super.dispose();
  }

  /// Posisi hanya untuk mengurutkan, menulis jarak, dan menghitung ongkir.
  /// Izin TIDAK diminta di sini: kotak izin yang muncul tiba-tiba tanpa alasan
  /// sering ditolak. Pemesan memintanya sendiri lewat spanduk di atas daftar.
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

  Future<void> _muat({bool bacaPosisi = false}) async {
    if (_warung.isEmpty) setState(() => _memuat = true);
    setState(() {
      _galat = null;
      _mencari = _warung.isNotEmpty;
    });
    try {
      if (bacaPosisi) await _bacaPosisi();
      final daftar = await ApiService().getFoodMerchants(lat: _posisi?.latitude, lng: _posisi?.longitude, q: _cari);
      if (!mounted) return;
      setState(() {
        _warung = daftar.map((j) => Warung.dariJson(Map<String, dynamic>.from(j as Map))).toList();
        _memuat = false;
        _mencari = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _galat = e.toString().replaceAll('Exception: ', '');
        _memuat = false;
        _mencari = false;
      });
    }
  }

  /// Pencarian di server, karena yang dicocokkan juga nama menu — "soto"
  /// menemukan warung yang menjual soto walau namanya bukan soto.
  void _ketikCari(String v) {
    _cari = v;
    _jedaCari?.cancel();
    _jedaCari = Timer(const Duration(milliseconds: 400), _muat);
  }

  Future<void> _buka(Warung w) async {
    final orderId = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FoodMenuScreen(warung: w, riderName: widget.riderName, riderPhone: widget.riderPhone)),
    );
    if (orderId != null && mounted) Navigator.pop(context, orderId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('BohFood', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: _ketikCari,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Cari warung atau menu, mis. soto',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: isDark ? AppTheme.cardObsidianDark : Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          if (_mencari) const LinearProgressIndicator(minHeight: 2),
          if (_kendala != null) _spandukLokasi(),
          Expanded(child: _isi(isDark)),
        ],
      ),
    );
  }

  Widget _spandukLokasi() {
    final teks = switch (_kendala!) {
      _KendalaLokasi.gpsMati => 'GPS mati. Nyalakan untuk melihat warung terdekat dan perkiraan ongkir.',
      _ => 'Izinkan lokasi untuk melihat warung terdekat dan perkiraan ongkir.',
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(color: AppTheme.primaryBlue.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          const Icon(Icons.my_location, size: 18, color: AppTheme.primaryBlue),
          const SizedBox(width: 10),
          Expanded(child: Text(teks, style: const TextStyle(fontSize: 12))),
          TextButton(onPressed: _aktifkanLokasi, child: Text(_kendala == _KendalaLokasi.izin ? 'Izinkan' : 'Buka pengaturan')),
        ],
      ),
    );
  }

  Widget _isi(bool isDark) {
    if (_memuat) return const Center(child: CircularProgressIndicator());
    if (_galat != null) {
      return PesanKosong(ikon: Icons.cloud_off, judul: 'Gagal memuat daftar warung', teks: _galat!, tombol: 'Coba lagi', saatTekan: () => _muat(bacaPosisi: true));
    }
    if (_warung.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _muat(bacaPosisi: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            _cari.trim().isEmpty
                ? const PesanKosong(
                    ikon: Icons.storefront_outlined,
                    judul: 'Belum ada warung yang bisa dipesan',
                    teks: 'Warung yang sudah mengatur lokasinya akan muncul di sini. Tarik ke bawah untuk memuat ulang.',
                  )
                : PesanKosong(ikon: Icons.search_off, judul: 'Tidak ketemu', teks: 'Tidak ada warung atau menu yang cocok dengan "${_cari.trim()}".'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _muat(bacaPosisi: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _warung.length,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (_, i) => _KartuWarung(_warung[i], isDark: isDark, saatTekan: () => _buka(_warung[i])),
      ),
    );
  }
}

class _KartuWarung extends StatelessWidget {
  final Warung w;
  final bool isDark;
  final VoidCallback saatTekan;
  const _KartuWarung(this.w, {required this.isDark, required this.saatTekan});

  @override
  Widget build(BuildContext context) {
    final redup = AppTheme.teksRedup(context);
    return Opacity(
      opacity: w.buka ? 1 : 0.62,
      child: Material(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        elevation: isDark ? 0 : 1.5,
        shadowColor: Colors.black.withValues(alpha: 0.15),
        child: InkWell(
          onTap: saatTekan,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  AspectRatio(aspectRatio: 16 / 9, child: GambarJaringan(url: w.gambar)),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Pil(w.buka ? 'Buka' : 'Tutup', warna: w.buka ? Colors.green.shade700 : Colors.grey.shade800),
                  ),
                  if (w.jarakKm >= 0)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Pil('${w.jarakKm.toStringAsFixed(1).replaceAll('.', ',')} km', warna: Colors.black.withValues(alpha: 0.6)),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(w.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.place_outlined, size: 14, color: redup),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(w.alamat, style: TextStyle(color: redup, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    // Yang menentukan pilihan: ongkir, kapan buka, dan menu yang dicari.
                    if ((!w.buka && w.infoBuka.isNotEmpty) || w.ongkir > 0 || w.cocokMenu.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (!w.buka && w.infoBuka.isNotEmpty) _info(Icons.schedule, w.infoBuka, Colors.orange.shade800),
                          if (w.ongkir > 0) _info(Icons.delivery_dining_outlined, 'Ongkir ${rupiah(w.ongkir)}', redup),
                          if (w.cocokMenu.isNotEmpty) _info(Icons.restaurant_menu, 'Ada ${w.cocokMenu}', AppTheme.primaryBlue),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _info(IconData ikon, String teks, Color warna) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ikon, size: 14, color: warna),
          const SizedBox(width: 4),
          Text(teks, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: warna)),
        ],
      );
}
