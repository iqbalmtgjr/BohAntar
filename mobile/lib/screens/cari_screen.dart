import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:mobile/models/food.dart';
import 'package:mobile/screens/food_menu_screen.dart';
import 'package:mobile/screens/order_ride_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';

/// Pencarian beranda: tempat tujuan (BohRide) dan warung/menu (BohFood)
/// sekaligus, dari dua pencarian yang sudah ada.
///
/// Memesan makanan dari sini mengembalikan id pesanan lewat Navigator.pop,
/// sama seperti FoodMerchantsScreen, supaya beranda yang membuka pelacakannya.
class CariScreen extends StatefulWidget {
  final String riderName;
  final String riderPhone;
  const CariScreen({super.key, required this.riderName, required this.riderPhone});

  @override
  State<CariScreen> createState() => _CariScreenState();
}

class _CariScreenState extends State<CariScreen> {
  final _kolom = TextEditingController();
  Timer? _jeda;
  String _kata = '';
  bool _memuat = false;
  List<PlaceSuggestion> _tempat = [];
  List<Warung> _warung = [];
  // Untuk mengurutkan saran tempat & jarak warung. Isian kota Sintang sampai
  // posisi terakhir HP terbaca; izin tidak diminta di sini.
  LatLng _dekat = const LatLng(-0.0784, 111.4933);
  bool _posisiAsli = false;

  static const _contoh = ['rsud', 'pasar', 'bakso', 'soto', 'terminal'];

  @override
  void initState() {
    super.initState();
    _bacaPosisi();
  }

  @override
  void dispose() {
    _jeda?.cancel();
    _kolom.dispose();
    super.dispose();
  }

  Future<void> _bacaPosisi() async {
    try {
      final izin = await Geolocator.checkPermission();
      if (izin != LocationPermission.whileInUse && izin != LocationPermission.always) return;
      final p = await Geolocator.getLastKnownPosition();
      if (p != null && mounted) {
        _dekat = LatLng(p.latitude, p.longitude);
        _posisiAsli = true;
      }
    } catch (_) {}
  }

  void _ketik(String v) {
    _jeda?.cancel();
    _jeda = Timer(const Duration(milliseconds: 450), () => _cari(v.trim()));
  }

  Future<void> _cari(String kata) async {
    setState(() => _kata = kata);
    if (kata.length < 2) {
      setState(() {
        _tempat = [];
        _warung = [];
        _memuat = false;
      });
      return;
    }
    setState(() => _memuat = true);
    // Satu yang gagal tidak menggagalkan yang lain: tempat tanpa warung pun
    // tetap berguna.
    final hasil = await Future.wait([
      MapsService().cariTempat(kata, dekat: _dekat).catchError((_) => <PlaceSuggestion>[]),
      ApiService()
          .getFoodMerchants(lat: _posisiAsli ? _dekat.latitude : null, lng: _posisiAsli ? _dekat.longitude : null, q: kata)
          .then((d) => [for (final j in d) Warung.dariJson(Map<String, dynamic>.from(j as Map))])
          .catchError((_) => <Warung>[]),
    ]);
    // Jawaban untuk kata yang sudah diganti jangan menimpa hasil yang baru.
    if (!mounted || kata != _kata) return;
    setState(() {
      _tempat = hasil[0] as List<PlaceSuggestion>;
      _warung = hasil[1] as List<Warung>;
      _memuat = false;
    });
  }

  void _pilihTempat(PlaceSuggestion t) {
    // Diganti, bukan ditumpuk: tombol kembali di layar pesan mendarat di beranda.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => OrderRideScreen(
          initialService: 'BohRide',
          initialTempat: t,
          riderName: widget.riderName,
          riderPhone: widget.riderPhone,
        ),
      ),
    );
  }

  Future<void> _bukaWarung(Warung w) async {
    final orderId = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FoodMenuScreen(warung: w, riderName: widget.riderName, riderPhone: widget.riderPhone)),
    );
    if (orderId != null && mounted) Navigator.pop(context, orderId);
  }

  void _pakaiContoh(String kata) {
    _kolom.text = kata;
    _kolom.selection = TextSelection.collapsed(offset: kata.length);
    _cari(kata);
  }

  @override
  Widget build(BuildContext context) {
    final redup = AppTheme.teksRedup(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _kolom,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (v) {
              setState(() {}); // tombol hapus
              _ketik(v);
            },
            onSubmitted: (v) => _cari(v.trim()),
            decoration: InputDecoration(
              hintText: 'Cari tujuan, warung, atau menu',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _kolom.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Hapus',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _kolom.clear();
                        _cari('');
                      },
                    ),
              isDense: true,
              filled: true,
              fillColor: isDark ? AppTheme.cardObsidianDark : const Color(0xFFF1F5F9),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: AppTheme.primaryBlue)),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_memuat) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _isi(redup)),
        ],
      ),
    );
  }

  Widget _isi(Color redup) {
    if (_kata.length < 2) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Coba cari', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final k in _contoh) ActionChip(label: Text(k), onPressed: () => _pakaiContoh(k))],
          ),
          const SizedBox(height: 20),
          Text(
            'Ketik nama tempat untuk diantar BohRide, atau nama warung dan menu untuk pesan BohFood.',
            style: TextStyle(fontSize: 13, height: 1.4, color: redup),
          ),
        ],
      );
    }
    if (!_memuat && _tempat.isEmpty && _warung.isEmpty) {
      return const SingleChildScrollView(
        padding: EdgeInsets.only(top: 60),
        child: PesanKosong(
          ikon: Icons.search_off,
          judul: 'Belum ketemu',
          teks: 'Coba kata lain. Untuk tujuan yang tidak ada di daftar, buka BohRide lalu pilih titiknya di peta.',
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_tempat.isNotEmpty) ...[
          _judulBagian('Antar ke tempat', 'BohRide'),
          for (final t in _tempat)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.primaryBlue.withValues(alpha: 0.10), shape: BoxShape.circle),
                child: const Icon(Icons.location_on, color: AppTheme.primaryBlue, size: 20),
              ),
              title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(t.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: redup)),
              trailing: Icon(Icons.chevron_right, color: redup),
              onTap: () => _pilihTempat(t),
            ),
          const SizedBox(height: 12),
        ],
        if (_warung.isNotEmpty) ...[
          _judulBagian('Warung & menu', 'BohFood'),
          for (final w in _warung)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(width: 44, height: 44, child: GambarJaringan(url: w.gambar)),
              ),
              title: Text(w.nama, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(
                [
                  if (!w.buka) 'Tutup',
                  if (w.cocokMenu.isNotEmpty) 'Ada ${w.cocokMenu}' else if (w.alamat.isNotEmpty) w.alamat,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: w.buka ? redup : Colors.orange.shade800),
              ),
              trailing: w.jarakKm >= 0
                  ? Text('${w.jarakKm.toStringAsFixed(1).replaceAll('.', ',')} km', style: TextStyle(fontSize: 12, color: redup))
                  : Icon(Icons.chevron_right, color: redup),
              onTap: () => _bukaWarung(w),
            ),
        ],
      ],
    );
  }

  Widget _judulBagian(String judul, String layanan) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Row(
          children: [
            Text(judul, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(width: 8),
            Pil(layanan, warna: AppTheme.warnaLayanan(layanan).withValues(alpha: 0.12), warnaTeks: AppTheme.teksBerwarna(context, AppTheme.warnaLayanan(layanan))),
          ],
        ),
      );
}
