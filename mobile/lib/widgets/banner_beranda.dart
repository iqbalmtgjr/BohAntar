import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile/models/food.dart' show urlGambar;
import 'package:mobile/status_pesanan.dart' show asetLayanan;

/// Spanduk geser selebar layar, seperti beranda Gojek. Isinya diatur super admin (dashboard → Banner Beranda).
///
/// Banner tanpa gambar digambar di sini dari judul, keterangan, dan warna;
/// banner bergambar dipasang apa adanya.

/// [sisi teks (gelap), sisi ilustrasi (terang)]. Sisi teks dipilih yang gelap
/// supaya tulisan putih kecil tetap ≥4,5:1. WAJIB sama dengan WARNA di
/// admin/src/pages/BannerPage.jsx.
const bannerWarna = <String, List<Color>>{
  'biru': [Color(0xFF0B5CD5), Color(0xFF3B8BFF)],
  'oranye': [Color(0xFFC2410C), Color(0xFFF97316)],
  'hijau': [Color(0xFF047857), Color(0xFF10B981)],
  'ungu': [Color(0xFF5B21B6), Color(0xFF8B5CF6)],
  'merah': [Color(0xFFB91C1C), Color(0xFFEF4444)],
  'gelap': [Color(0xFF0F172A), Color(0xFF334155)],
};

/// Dipakai selama server belum menjawab, gagal, atau tidak punya banner aktif.
/// Isinya sama dengan banner bawaan yang ditanam backend (banner.go).
const bannerBawaan = <Map<String, dynamic>>[
  {
    'id': 'bawaan',
    'judul': 'Tanpa tarif tambahan di BohFood',
    'keterangan': 'Harga menu sama dengan harga di warung.',
    'label_tombol': 'Pesan makanan',
    'tujuan': 'BohFood',
    'warna': 'oranye',
    'gambar_url': '',
  },
];

class BannerBeranda extends StatefulWidget {
  final List<Map<String, dynamic>> banner;
  final double tinggi;
  final void Function(Map<String, dynamic>) saatTekan;

  const BannerBeranda({super.key, required this.banner, required this.tinggi, required this.saatTekan});

  @override
  State<BannerBeranda> createState() => _BannerBerandaState();
}

class _BannerBerandaState extends State<BannerBeranda> {
  final _halaman = PageController();
  Timer? _geser;
  int _aktif = 0;

  @override
  void initState() {
    super.initState();
    _mulaiGeser();
  }

  @override
  void didUpdateWidget(BannerBeranda lama) {
    super.didUpdateWidget(lama);
    if (lama.banner.length != widget.banner.length) {
      _aktif = 0;
      if (_halaman.hasClients) _halaman.jumpToPage(0);
      _mulaiGeser();
    }
  }

  // Bergeser sendiri tiap 5 detik, seperti spanduk promo aplikasi lain.
  void _mulaiGeser() {
    _geser?.cancel();
    if (widget.banner.length < 2) return;
    _geser = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_halaman.hasClients) return;
      _halaman.animateToPage((_aktif + 1) % widget.banner.length, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  @override
  void dispose() {
    _geser?.cancel();
    _halaman.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jumlah = widget.banner.length;
    return SizedBox(
      height: widget.tinggi,
      child: Stack(
        children: [
          PageView.builder(
            controller: _halaman,
            itemCount: jumlah,
            onPageChanged: (i) => setState(() => _aktif = i),
            itemBuilder: (_, i) => _satu(widget.banner[i]),
          ),
          if (jumlah > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < jumlah; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _aktif ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: i == _aktif ? 0.95 : 0.5),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _satu(Map<String, dynamic> b) {
    final judul = (b['judul'] ?? '').toString();
    final gambar = (b['gambar_url'] ?? '').toString();
    final tujuan = (b['tujuan'] ?? '').toString();
    final isi = gambar.isEmpty
        ? _bannerTeks(b)
        : Image.network(
            urlGambar(gambar),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            // Seukuran layar, bukan seukuran berkas unggahannya.
            cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round(),
            // Gambar mati jatuh ke versi teks, bukan kotak kosong.
            errorBuilder: (_, _, _) => _bannerTeks(b),
          );
    return Semantics(
      label: judul,
      button: tujuan.isNotEmpty,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tujuan.isEmpty ? null : () => widget.saatTekan(b),
        child: isi,
      ),
    );
  }

  Widget _bannerTeks(Map<String, dynamic> b) {
    final warna = bannerWarna[b['warna']] ?? bannerWarna['biru']!;
    final tujuan = (b['tujuan'] ?? '').toString();
    final keterangan = (b['keterangan'] ?? '').toString();
    final label = (b['label_tombol'] ?? '').toString();
    final aset = asetLayanan(tujuan);
    return LayoutBuilder(
      builder: (context, ukuran) => DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(colors: warna, begin: Alignment.centerLeft, end: Alignment.centerRight)),
        child: Stack(
          children: [
            // Dua lingkaran samar supaya bidang warnanya tidak datar.
            Positioned(right: -40, top: -50, child: _lingkaran(170, 0.12)),
            Positioned(left: ukuran.maxWidth * 0.35, bottom: -70, child: _lingkaran(150, 0.07)),
            if (aset != null)
              Positioned(
                right: 10,
                top: 12,
                bottom: 2,
                child: AspectRatio(aspectRatio: 1, child: Image.asset(aset, fit: BoxFit.contain)),
              ),
            Positioned(
              left: 20,
              top: 16,
              right: aset != null ? ukuran.maxWidth * 0.40 : 20,
              bottom: 6,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (b['judul'] ?? '').toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900, height: 1.15),
                  ),
                  if (keterangan.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      keterangan,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w500, height: 1.3),
                    ),
                  ],
                  if (label.isNotEmpty && tujuan.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(label, style: TextStyle(color: warna.first, fontSize: 12, fontWeight: FontWeight.w800)),
                          Icon(Icons.chevron_right, size: 16, color: warna.first),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lingkaran(double ukuran, double alfa) => IgnorePointer(
        child: Container(
          width: ukuran,
          height: ukuran,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: alfa)),
        ),
      );
}
