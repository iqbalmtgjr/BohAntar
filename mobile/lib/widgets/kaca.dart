import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:mobile/theme.dart';

// Gaya kaca ala iPhone: menu bawah mengambang, ikon kaca timbul, dan ubin
// layanan kaca berwarna.

/// Satu tombol di [NavKaca]. [ikon] versi isi (bukan garis): gradasi dan
/// kilaunya butuh bidang. [lencana] 0 = tanpa angka.
typedef ItemNavKaca = ({IconData ikon, String label, int lencana});

/// Menu bawah kaca buram: pil yang mengambang, isi halaman lewat di
/// belakangnya dan terlihat samar. Pasang di `Scaffold.bottomNavigationBar`
/// bersama `extendBody: true`, lalu beri tiap daftar bergulir ruang bawah
/// [ruang] supaya baris terakhirnya tidak tertutup.
///
/// Gelembung tab aktif meluncur ke tab yang dipilih dengan pegas, memanjang
/// sedikit selama bergerak seperti cairan.
class NavKaca extends StatefulWidget {
  const NavKaca({super.key, required this.item, required this.aktif, required this.saatPilih});

  final List<ItemNavKaca> item;
  final int aktif;
  final ValueChanged<int> saatPilih;

  static const _tinggi = 64.0;
  static const _jarakBawah = 10.0;

  /// Tinggi layar yang ditutupi menu. [context] harus dari LUAR Scaffold,
  /// supaya inset bawah yang terbaca milik sistem, bukan yang sudah ditambah menu.
  static double ruang(BuildContext context) => _tinggi + _jarakBawah + MediaQuery.paddingOf(context).bottom;

  @override
  State<NavKaca> createState() => _NavKacaState();
}

class _NavKacaState extends State<NavKaca> with SingleTickerProviderStateMixin {
  static const _tinggi = NavKaca._tinggi;
  static const _durasi = Duration(milliseconds: 420);

  late final _gerak = AnimationController(vsync: this, duration: _durasi, value: 1);
  // Gelembung bergerak dari _dari ke _ke (indeks tab, boleh pecahan).
  late double _dari = widget.aktif.toDouble(), _ke = _dari;

  /// Posisi gelembung sekarang, dalam satuan tab. easeOutBack: sedikit
  /// melewati tujuan lalu kembali, rasa pegas ala iPhone.
  double get _posisi => lerpDouble(_dari, _ke, Curves.easeOutBack.transform(_gerak.value))!;

  @override
  void didUpdateWidget(NavKaca lama) {
    super.didUpdateWidget(lama);
    if (lama.aktif != widget.aktif) {
      // Dari posisi saat ini, bukan dari tab lama: ketukan beruntun di tengah
      // gerakan tidak membuat gelembung melompat.
      _dari = _posisi;
      _ke = widget.aktif.toDouble();
      _gerak.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _gerak.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final gelap = Theme.of(context).brightness == Brightness.dark;
    final bentuk = BorderRadius.circular(_tinggi / 2);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, NavKaca._jarakBawah),
        child: DecoratedBox(
          // Sengaja samar: bayangan pekat ikut terlihat menembus kaca dan
          // membuatnya kusam.
          decoration: BoxDecoration(
            borderRadius: bentuk,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: gelap ? 0.30 : 0.08), blurRadius: 18, offset: const Offset(0, 3))],
          ),
          child: ClipRRect(
            borderRadius: bentuk,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                height: _tinggi,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  borderRadius: bentuk,
                  // Tembus pandang, sedikit lebih terang di atas (kilau kaca),
                  // dengan garis tepi terang tipis.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: gelap
                        ? [const Color(0xFF334155).withValues(alpha: 0.60), const Color(0xFF1E293B).withValues(alpha: 0.50)]
                        : [Colors.white.withValues(alpha: 0.80), Colors.white.withValues(alpha: 0.58)],
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: gelap ? 0.14 : 0.75)),
                ),
                child: LayoutBuilder(
                  builder: (context, ruang) => Stack(
                    children: [
                      AnimatedBuilder(animation: _gerak, builder: (_, _) => _gelembung(ruang.maxWidth / item.length, gelap)),
                      Row(
                        children: [for (var i = 0; i < item.length; i++) Expanded(child: _tombol(context, i))],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Gelembung biru muda di bawah tab aktif. Selama bergerak ia memanjang
  /// (sampai 35%) dan memipih sedikit, lalu kembali bulat saat tiba.
  Widget _gelembung(double lebarTab, bool gelap) {
    final regang = math.sin(math.pi * _gerak.value);
    final lebar = lebarTab * (1 + 0.35 * regang);
    return Positioned(
      key: const ValueKey('gelembung-nav'),
      left: _posisi * lebarTab - (lebar - lebarTab) / 2,
      width: lebar,
      top: 0,
      bottom: 0,
      child: Transform.scale(
        scaleY: 1 - 0.08 * regang,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_tinggi / 2),
            color: AppTheme.primaryBlue.withValues(alpha: gelap ? 0.28 : 0.12),
            border: Border.all(color: Colors.white.withValues(alpha: gelap ? 0.10 : 0.6)),
          ),
        ),
      ),
    );
  }

  Widget _tombol(BuildContext context, int i) {
    final it = widget.item[i];
    final dipilih = i == widget.aktif;
    final warna = dipilih ? AppTheme.teksBerwarna(context, AppTheme.primaryBlue) : AppTheme.teksRedup(context);
    return Semantics(
      button: true,
      selected: dipilih,
      // GestureDetector, bukan InkWell: riak InkWell tergambar di Material di
      // bawah kaca sehingga tak terlihat — iPhone pun tanpa riak.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!dipilih) HapticFeedback.selectionClick();
          widget.saatPilih(i);
        },
        // Warna berpindah halus mengikuti gelembung, bukan berganti seketika.
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: warna),
          duration: _durasi ~/ 2,
          builder: (_, w, _) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Badge(
                isLabelVisible: it.lencana > 0,
                label: Text(it.lencana > 99 ? '99+' : '${it.lencana}'),
                child: AnimatedScale(
                  scale: dipilih ? 1.12 : 1,
                  duration: _durasi,
                  curve: Curves.easeOutBack,
                  child: IkonKaca(it.ikon, warna: w ?? warna, ukuran: 22),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                it.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: w ?? warna, fontSize: 11, fontWeight: dipilih ? FontWeight.w700 : FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ikon kaca timbul: isi bergradasi (terang di atas, pekat di bawah), kilau
/// putih di separuh atas, dan bayangan lembut yang jatuh sedikit ke bawah.
class IkonKaca extends StatelessWidget {
  const IkonKaca(this.ikon, {super.key, required this.warna, this.ukuran = 24});

  final IconData ikon;
  final Color warna;
  final double ukuran;

  Widget _isi(Gradient g) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: g.createShader,
        child: Icon(ikon, size: ukuran, color: Colors.white),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Transform.translate(
          offset: Offset(0, ukuran * 0.08),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
            child: Icon(ikon, size: ukuran, color: Color.lerp(warna, Colors.black, 0.3)!.withValues(alpha: 0.35)),
          ),
        ),
        _isi(LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(warna, Colors.white, 0.40)!, Color.lerp(warna, Colors.black, 0.20)!],
        )),
        _isi(LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)],
        )),
      ],
    );
  }
}

/// Ubin kaca berwarna untuk ilustrasi layanan: kaca tembus pandang bergradasi,
/// kilau di separuh atas, tepi terang, bayangan berwarna di bawahnya, dan
/// ilustrasi yang tampak melayang di atas bayangannya sendiri. Dengan [onTap]
/// ubinnya sedikit mengecil saat ditekan; dengan [label] namanya ditulis di
/// bawah ubin dan ikut bisa diketuk.
// ponytail: tanpa BackdropFilter — latar di belakang ubin polos, dan blur
// untuk enam ubin cuma membebani HP murah tanpa terlihat bedanya.
class UbinKaca extends StatefulWidget {
  const UbinKaca({super.key, required this.warna, required this.child, this.label, this.onTap, this.radius = 20, this.padding = 8});

  final Color warna;
  final Widget child;
  final String? label;
  final VoidCallback? onTap;
  final double radius;
  final double padding;

  @override
  State<UbinKaca> createState() => _UbinKacaState();
}

class _UbinKacaState extends State<UbinKaca> {
  bool _ditekan = false;

  void _tekan(bool v) {
    if (widget.onTap != null && _ditekan != v) setState(() => _ditekan = v);
  }

  @override
  Widget build(BuildContext context) {
    final gelap = Theme.of(context).brightness == Brightness.dark;
    final w = widget.warna;
    final r = BorderRadius.circular(widget.radius);
    final ubin = AnimatedScale(
      scale: _ditekan ? 0.93 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [w.withValues(alpha: gelap ? 0.34 : 0.20), w.withValues(alpha: gelap ? 0.14 : 0.06)],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: gelap ? 0.16 : 0.85), width: 1.2),
          // Bayangan berwarna yang menipis saat ditekan: ubinnya terasa turun.
          boxShadow: [
            BoxShadow(
              color: w.withValues(alpha: gelap ? 0.30 : 0.22),
              blurRadius: _ditekan ? 6 : 14,
              offset: Offset(0, _ditekan ? 2 : 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: r,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Kilau kaca di separuh atas.
              FractionallySizedBox(
                alignment: Alignment.topCenter,
                heightFactor: 0.5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white.withValues(alpha: gelap ? 0.14 : 0.65), Colors.white.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
              // Bayangan jatuh di bawah ilustrasi: ilustrasinya tampak melayang.
              FractionallySizedBox(
                alignment: const Alignment(0, 0.86),
                widthFactor: 0.58,
                heightFactor: 0.10,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 3),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(shape: const OvalBorder(), color: Colors.black.withValues(alpha: gelap ? 0.35 : 0.16)),
                  ),
                ),
              ),
              Padding(padding: EdgeInsets.all(widget.padding), child: widget.child),
            ],
          ),
        ),
      ),
    );
    final label = widget.label;
    final isi = label == null
        ? ubin
        : Column(
            children: [
              AspectRatio(aspectRatio: 1, child: ubin),
              const SizedBox(height: 6),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          );
    if (widget.onTap == null) return isi;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _tekan(true),
        onTapUp: (_) => _tekan(false),
        onTapCancel: () => _tekan(false),
        onTap: widget.onTap,
        child: isi,
      ),
    );
  }
}
