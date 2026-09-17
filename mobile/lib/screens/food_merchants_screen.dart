import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/screens/food_menu_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';

/// Langkah 1 dari 3: pilih warung.
///
/// Mengembalikan id pesanan lewat Navigator.pop begitu pesanan jadi di langkah
/// 3, supaya dashboard yang membuka pelacakannya — layar ini tidak perlu tahu
/// ada berapa rute di bawahnya.
class FoodMerchantsScreen extends StatefulWidget {
  final String riderName;
  final String riderPhone;
  const FoodMerchantsScreen({super.key, required this.riderName, required this.riderPhone});

  @override
  State<FoodMerchantsScreen> createState() => _FoodMerchantsScreenState();
}

class _FoodMerchantsScreenState extends State<FoodMerchantsScreen> {
  List<Warung> _warung = [];
  bool _memuat = true;
  String? _galat;
  String _cari = '';

  @override
  void initState() {
    super.initState();
    _muat();
  }

  /// Posisi hanya untuk mengurutkan dan menulis jarak. Tanpa izin lokasi
  /// daftarnya tetap muncul, cuma tanpa angka km.
  Future<LatLng?> _posisiSaya() async {
    try {
      var izin = await Geolocator.checkPermission();
      if (izin == LocationPermission.denied) izin = await Geolocator.requestPermission();
      if (izin == LocationPermission.denied || izin == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 8));
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _muat() async {
    if (_warung.isEmpty) setState(() => _memuat = true);
    setState(() => _galat = null);
    try {
      final posisi = await _posisiSaya();
      final daftar = await ApiService().getFoodMerchants(lat: posisi?.latitude, lng: posisi?.longitude);
      if (!mounted) return;
      setState(() {
        _warung = daftar.map((j) => Warung.dariJson(Map<String, dynamic>.from(j as Map))).toList();
        _memuat = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _galat = e.toString().replaceAll('Exception: ', '');
        _memuat = false;
      });
    }
  }

  List<Warung> get _tersaring {
    final q = _cari.trim().toLowerCase();
    if (q.isEmpty) return _warung;
    return _warung.where((w) => w.nama.toLowerCase().contains(q) || w.alamat.toLowerCase().contains(q)).toList();
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LangkahPesan(aktif: 1),
                const SizedBox(height: 14),
                TextField(
                  onChanged: (v) => setState(() => _cari = v),
                  decoration: InputDecoration(
                    hintText: 'Cari warung atau alamat',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor: isDark ? AppTheme.cardObsidianDark : Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _isi(isDark)),
        ],
      ),
    );
  }

  Widget _isi(bool isDark) {
    if (_memuat) return const Center(child: CircularProgressIndicator());
    if (_galat != null) {
      return PesanKosong(ikon: Icons.cloud_off, judul: 'Gagal memuat daftar warung', teks: _galat!, tombol: 'Coba lagi', saatTekan: _muat);
    }
    final daftar = _tersaring;
    if (daftar.isEmpty) {
      return RefreshIndicator(
        onRefresh: _muat,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            _warung.isEmpty
                ? const PesanKosong(
                    ikon: Icons.storefront_outlined,
                    judul: 'Belum ada warung yang bisa dipesan',
                    teks: 'Warung yang sudah mengatur lokasinya akan muncul di sini. Tarik ke bawah untuk memuat ulang.',
                  )
                : PesanKosong(ikon: Icons.search_off, judul: 'Tidak ketemu', teks: 'Tidak ada warung yang cocok dengan "$_cari".'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _muat,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: daftar.length,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (_, i) => _KartuWarung(daftar[i], isDark: isDark, saatTekan: () => _buka(daftar[i])),
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
    return Opacity(
      opacity: w.buka ? 1 : 0.62,
      child: Material(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        elevation: isDark ? 0 : 1.5,
        shadowColor: Colors.black.withOpacity(0.15),
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
                    child: Pil(w.buka ? 'Buka' : 'Tutup', warna: w.buka ? Colors.green.shade600 : Colors.grey.shade700),
                  ),
                  if (w.jarakKm >= 0)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Pil('${w.jarakKm.toStringAsFixed(1).replaceAll('.', ',')} km', warna: Colors.black.withOpacity(0.55)),
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
                        const Icon(Icons.place_outlined, size: 14, color: Colors.grey),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(w.alamat, style: const TextStyle(color: Colors.grey, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
