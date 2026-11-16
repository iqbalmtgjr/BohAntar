import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:mobile/theme.dart';

// Gaya kaca ala iPhone: menu bawah mengambang, ikon kaca timbul, dan ubin
// layanan kaca berwarna.

/// Satu tombol di [NavKaca]. [ikon] versi isi (bukan garis): gradasi dan
/// kilaunya butuh bidang. [gambar] = aset ikon 3D, menggantikan [ikon] bila
/// diisi. [lencana] 0 = tanpa angka.
typedef ItemNavKaca = ({IconData ikon, String? gambar, String label, int lencana});

/// Menu bawah ala dashboard admin web (17 Nov 2026; dulu pil kaca mengambang):
/// bar putih menempel di bawah, tab aktif = kotak membulat biru muda, dan
/// opsional satu tombol bulat besar di [tengah] yang menonjol di atas bar.
/// Pasang di `Scaffold.bottomNavigationBar` bersama `extendBody: true`, lalu
/// beri tiap daftar bergulir ruang bawah [ruang] supaya baris terakhirnya
/// tidak tertutup.
///
/// Penanda tab aktif meluncur ke tab yang dipilih dengan pegas, memanjang
/// sedikit selama bergerak seperti cairan.
class NavKaca extends StatefulWidget {
  const NavKaca({super.key, required this.item, required this.aktif, required this.saatPilih, this.tengah});

  final List<ItemNavKaca> item;
  final int aktif;
  final ValueChanged<int> saatPilih;

  /// Indeks tombol bulat besar di tengah (ikonnya [ItemNavKaca.ikon] putih
  /// di lingkaran biru); null = semua tombol sama.
  final int? tengah;

  static const _tinggi = 64.0;
  static const _tonjol = 22.0; // tinggi tombol tengah di atas bar

  /// Tinggi layar yang ditutupi menu (+10 untuk tombol tengah yang menonjol).
  /// [context] harus dari LUAR Scaffold, supaya inset bawah yang terbaca milik
  /// sistem, bukan yang sudah ditambah menu.
  static double ruang(BuildContext context) => _tinggi + 10 + MediaQuery.paddingOf(context).bottom;

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
    final warnaBar = gelap ? AppTheme.cardObsidianDark : Colors.white;
    final bawah = MediaQuery.paddingOf(context).bottom;
    final t = widget.tengah;
    // Area tonjolan di atas bar bening dan tidak menangkap ketukan (tak ada
    // apa pun di sana selain tombol tengah), jadi isi halaman di baliknya
    // tetap bisa diketuk.
    return SizedBox(
      height: NavKaca._tonjol + _tinggi + bawah,
      child: LayoutBuilder(
        builder: (context, ruang) {
          final lebarTab = ruang.maxWidth / item.length;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                top: NavKaca._tonjol,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: warnaBar,
                    border: Border(top: BorderSide(color: gelap ? Colors.white10 : const Color(0xFFF1F5F9))),
                    boxShadow: [BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: gelap ? 0.30 : 0.06), blurRadius: 16, offset: const Offset(0, -4))],
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bawah),
                    child: Stack(
                      children: [
                        AnimatedBuilder(animation: _gerak, builder: (_, _) => _gelembung(lebarTab, gelap)),
                        Row(children: [for (var i = 0; i < item.length; i++) Expanded(child: _tombol(context, i))]),
                      ],
                    ),
                  ),
                ),
              ),
              if (t != null)
                Positioned(top: 0, left: (t + 0.5) * lebarTab - 30, width: 60, height: 60, child: _bulatTengah(t, warnaBar)),
            ],
          );
        },
      ),
    );
  }

  /// Penanda tab aktif: kotak membulat biru muda ala admin web. Selama
  /// bergerak ia memanjang (sampai 35%) dan memipih sedikit. Disembunyikan
  /// saat yang aktif tombol tengah — lingkarannya sendiri sudah menonjol.
  Widget _gelembung(double lebarTab, bool gelap) {
    final regang = math.sin(math.pi * _gerak.value);
    final lebar = lebarTab * (1 + 0.35 * regang);
    return Positioned(
      key: const ValueKey('gelembung-nav'),
      left: _posisi * lebarTab - (lebar - lebarTab) / 2,
      width: lebar,
      top: 0,
      bottom: 0,
      child: AnimatedOpacity(
        opacity: widget.aktif == widget.tengah ? 0 : 1,
        duration: _durasi ~/ 2,
        child: Transform.scale(
          scaleY: 1 - 0.08 * regang,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: AppTheme.primaryDarkBlue.withValues(alpha: gelap ? 0.28 : 0.10),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Tombol bulat besar di tengah: lingkaran biru bergradasi, ikon putih,
  /// cincin warna bar supaya tampak "memotong" garis atas bar.
  Widget _bulatTengah(int i, Color cincin) {
    final it = widget.item[i];
    final dipilih = i == widget.aktif;
    return Semantics(
      button: true,
      selected: dipilih,
      label: it.label,
      child: GestureDetector(
        onTap: () {
          if (!dipilih) HapticFeedback.selectionClick();
          widget.saatPilih(i);
        },
        child: AnimatedScale(
          scale: dipilih ? 1.06 : 1,
          duration: _durasi,
          curve: Curves.easeOutBack,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3B8BFF), AppTheme.primaryDarkBlue]),
              border: Border.all(color: cincin, width: 4),
              boxShadow: [BoxShadow(color: AppTheme.primaryDarkBlue.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))],
            ),
            child: Center(
              child: Badge(
                isLabelVisible: it.lencana > 0,
                label: Text(it.lencana > 99 ? '99+' : '${it.lencana}'),
                child: Icon(it.ikon, color: Colors.white, size: 26),
              ),
            ),
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
              // Posisi tengah: lingkarannya digambar _bulatTengah di atas bar,
              // di sini cukup ruang kosong setinggi ikon supaya labelnya sejajar.
              if (i == widget.tengah)
                const SizedBox(height: 28)
              else
                Badge(
                  isLabelVisible: it.lencana > 0,
                  label: Text(it.lencana > 99 ? '99+' : '${it.lencana}'),
                  child: AnimatedScale(
                    scale: dipilih ? 1.12 : 1,
                    duration: _durasi,
                    curve: Curves.easeOutBack,
                    child: it.gambar == null
                        ? IkonKaca(it.ikon, warna: w ?? warna, ukuran: 22)
                        : Image.asset(it.gambar!, width: 28, height: 28, cacheWidth: 96),
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
