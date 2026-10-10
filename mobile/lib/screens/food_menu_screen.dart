import 'package:flutter/material.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/screens/food_checkout_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';

/// Langkah 2 dari 3: pilih menu. Keranjang hidup di layar ini; batang di bawah
/// selalu memperlihatkan isinya dan satu ketukan membawa ke konfirmasi.
class FoodMenuScreen extends StatefulWidget {
  final Warung warung;
  final String riderName;
  final String riderPhone;
  const FoodMenuScreen({super.key, required this.warung, required this.riderName, required this.riderPhone});

  @override
  State<FoodMenuScreen> createState() => _FoodMenuScreenState();
}

class _FoodMenuScreenState extends State<FoodMenuScreen> {
  List<MenuMakanan> _menu = [];
  bool _memuat = true;
  String? _galat;
  String _kategori = 'Semua';
  late final Keranjang _keranjang = Keranjang(widget.warung);

  @override
  void initState() {
    super.initState();
    _muat();
  }

  Future<void> _muat() async {
    setState(() {
      _memuat = true;
      _galat = null;
    });
    try {
      final daftar = await ApiService().getFoodMenus(widget.warung.id);
      if (!mounted) return;
      setState(() {
        _menu = daftar.map((j) => MenuMakanan.dariJson(Map<String, dynamic>.from(j as Map))).toList();
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

  List<String> get _kategoriTersedia => ['Semua', ...{for (final m in _menu) if (m.kategori.isNotEmpty) m.kategori}];

  List<MenuMakanan> get _tersaring => _kategori == 'Semua' ? _menu : _menu.where((m) => m.kategori == _kategori).toList();

  /// Menu tanpa varian langsung masuk keranjang; yang bervarian memilih dulu
  /// lewat lembar bawah, seperti GoFood.
  Future<void> _tambah(MenuMakanan m) async {
    if (!m.punyaVarian) {
      setState(() => _keranjang.tambah(m));
      return;
    }
    final pilihan = await showModalBottomSheet<BarisKeranjang>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _LembarVarian(m),
    );
    if (pilihan != null && mounted) {
      setState(() => _keranjang.tambah(m, pilihan.opsi, pilihan.jumlah));
    }
  }

  Future<void> _lanjut() async {
    final orderId = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FoodCheckoutScreen(keranjang: _keranjang, riderName: widget.riderName, riderPhone: widget.riderPhone)),
    );
    if (!mounted) return;
    if (orderId != null) {
      Navigator.pop(context, orderId);
    } else {
      setState(() {}); // keranjang mungkin diubah dari layar konfirmasi
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.warung;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 210,
            pinned: true,
            backgroundColor: AppTheme.bgObsidianDark,
            foregroundColor: Colors.white,
            title: Text(w.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17), maxLines: 1, overflow: TextOverflow.ellipsis),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  GambarJaringan(url: w.gambar),
                  // Gelap di atas supaya judul terbaca di atas foto apa pun.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black54, Colors.transparent, Colors.black38],
                        stops: [0, 0.45, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.place_outlined, size: 15, color: Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(child: Text(w.alamat, style: const TextStyle(color: Colors.grey, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis)),
                      if (w.jarakKm >= 0) ...[
                        const SizedBox(width: 8),
                        Pil('${w.jarakKm.toStringAsFixed(1).replaceAll('.', ',')} km', warna: AppTheme.primaryBlue.withOpacity(0.12), warnaTeks: AppTheme.primaryBlue),
                      ],
                    ],
                  ),
                  if (!w.buka) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                      child: const Row(
                        children: [
                          Icon(Icons.schedule, size: 18, color: Colors.orange),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text('Warung sedang tutup. Kamu bisa lihat menunya, tapi belum bisa memesan.', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  const LangkahPesan(aktif: 2),
                  if (_kategoriTersedia.length > 2) ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _kategoriTersedia.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final k = _kategoriTersedia[i];
                          return ChoiceChip(
                            label: Text(k),
                            selected: _kategori == k,
                            onSelected: (_) => setState(() => _kategori = k),
                            visualDensity: VisualDensity.compact,
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
          if (_memuat)
            const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
          else if (_galat != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: PesanKosong(ikon: Icons.cloud_off, judul: 'Gagal memuat menu', teks: _galat!, tombol: 'Coba lagi', saatTekan: _muat),
            )
          else if (_menu.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: PesanKosong(ikon: Icons.menu_book_outlined, judul: 'Belum ada menu', teks: 'Warung ini belum mengisi daftar menunya.'),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) {
                    final m = _tersaring[i];
                    return _BarisMenu(
                      m,
                      jumlah: _keranjang.jumlah(m),
                      bisaPesan: w.buka && m.tersedia,
                      isDark: isDark,
                      saatTambah: () => _tambah(m),
                      saatKurang: () => setState(() => _keranjang.kurangi(m)),
                    );
                  },
                  childCount: _tersaring.length,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _keranjang.kosong ? null : _BarKeranjang(_keranjang, saatLanjut: _lanjut),
    );
  }
}

class _BarisMenu extends StatelessWidget {
  final MenuMakanan m;
  final int jumlah;
  final bool bisaPesan;
  final bool isDark;
  final VoidCallback saatTambah;
  final VoidCallback saatKurang;
  const _BarisMenu(this.m, {required this.jumlah, required this.bisaPesan, required this.isDark, required this.saatTambah, required this.saatKurang});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: m.tersedia ? 1 : 0.5,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.15)))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  if (m.deskripsi.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(m.deskripsi, style: const TextStyle(color: Colors.grey, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(rupiah(m.harga), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.primaryBlue)),
                      if (!m.tersedia) ...[
                        const SizedBox(width: 8),
                        Pil('Habis', warna: Colors.grey.shade600),
                      ],
                    ],
                  ),
                  if (m.punyaVarian) ...[
                    const SizedBox(height: 4),
                    const Text('Bisa pilih varian', style: TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(width: 84, height: 84, child: GambarJaringan(url: m.gambar, pengganti: Icons.fastfood_outlined)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 84,
                  height: 32,
                  child: jumlah == 0
                      ? OutlinedButton(
                          onPressed: bisaPesan ? saatTambah : null,
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            foregroundColor: AppTheme.primaryBlue,
                            side: BorderSide(color: bisaPesan ? AppTheme.primaryBlue : Colors.grey.shade400),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          child: const Text('Tambah'),
                        )
                      : _Stepper(jumlah: jumlah, saatTambah: saatTambah, saatKurang: saatKurang),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int jumlah;
  final VoidCallback saatTambah;
  final VoidCallback saatKurang;
  const _Stepper({required this.jumlah, required this.saatTambah, required this.saatKurang});

  @override
  Widget build(BuildContext context) {
    Widget tombol(IconData ikon, VoidCallback aksi) => InkWell(
          onTap: aksi,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 28, height: 32, child: Icon(ikon, size: 16, color: Colors.white)),
        );
    return Container(
      decoration: BoxDecoration(color: AppTheme.primaryBlue, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          tombol(Icons.remove, saatKurang),
          Text('$jumlah', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
          tombol(Icons.add, saatTambah),
        ],
      ),
    );
  }
}

class _BarKeranjang extends StatelessWidget {
  final Keranjang k;
  final VoidCallback saatLanjut;
  const _BarKeranjang(this.k, {required this.saatLanjut});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Material(
          color: AppTheme.primaryBlue,
          borderRadius: BorderRadius.circular(18),
          elevation: 8,
          shadowColor: AppTheme.primaryBlue.withOpacity(0.4),
          child: InkWell(
            onTap: saatLanjut,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: Text('${k.totalPorsi}', style: const TextStyle(color: AppTheme.primaryBlue, fontWeight: FontWeight.w900, fontSize: 13)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rupiah(k.subtotal), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                        const Text('Belum termasuk ongkir', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                  const Text('Lanjut', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lembar pilih varian satu menu. Mengembalikan BarisKeranjang (varian +
/// jumlah porsi), atau null kalau ditutup tanpa memilih.
class _LembarVarian extends StatefulWidget {
  final MenuMakanan menu;
  const _LembarVarian(this.menu);

  @override
  State<_LembarVarian> createState() => _LembarVarianState();
}

class _LembarVarianState extends State<_LembarVarian> {
  // id grup → id varian yang dipilih, urut sesuai ketukan.
  final Map<String, List<String>> _pilih = {};
  int _jumlah = 1;

  List<OpsiMenu> get _terpilih => [
        for (final g in widget.menu.grup)
          for (final o in g.opsi)
            if (_pilih[g.id]?.contains(o.id) ?? false) o,
      ];

  bool get _sah => widget.menu.grup.every((g) => (_pilih[g.id]?.length ?? 0) >= g.minimal);

  double get _total => (widget.menu.harga + _terpilih.fold(0.0, (a, o) => a + o.harga)) * _jumlah;

  void _ketuk(GrupOpsi g, OpsiMenu o) {
    setState(() {
      final daftar = _pilih.putIfAbsent(g.id, () => []);
      if (daftar.contains(o.id)) {
        daftar.remove(o.id);
      } else if (g.tunggal) {
        daftar
          ..clear()
          ..add(o.id);
      } else if (g.batas == null || daftar.length < g.batas!) {
        daftar.add(o.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.menu;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              children: [
                Text(m.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                const SizedBox(height: 4),
                Text(rupiah(m.harga), style: const TextStyle(color: Colors.grey, fontSize: 13)),
                for (final g in m.grup) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(child: Text(g.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                      Pil(g.wajib ? 'Wajib' : 'Opsional', warna: g.wajib ? Colors.orange.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.15), warnaTeks: g.wajib ? Colors.orange.shade800 : Colors.grey.shade700),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(g.petunjuk, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  const SizedBox(height: 6),
                  for (final o in g.opsi) _barisOpsi(g, o),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  _tombolJumlah(Icons.remove, _jumlah > 1 ? () => setState(() => _jumlah--) : null),
                  SizedBox(width: 36, child: Text('$_jumlah', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                  _tombolJumlah(Icons.add, _jumlah < 50 ? () => setState(() => _jumlah++) : null),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _sah ? () => Navigator.pop(context, BarisKeranjang(m, _terpilih, _jumlah)) : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text(_sah ? 'Tambah · ${rupiah(_total)}' : 'Lengkapi pilihan wajib', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barisOpsi(GrupOpsi g, OpsiMenu o) {
    final dipilih = _pilih[g.id]?.contains(o.id) ?? false;
    final penuh = !g.tunggal && g.batas != null && (_pilih[g.id]?.length ?? 0) >= g.batas!;
    return InkWell(
      onTap: dipilih || !penuh ? () => _ketuk(g, o) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              g.tunggal
                  ? (dipilih ? Icons.radio_button_checked : Icons.radio_button_unchecked)
                  : (dipilih ? Icons.check_box : Icons.check_box_outline_blank),
              size: 22,
              color: dipilih ? AppTheme.primaryBlue : (penuh ? Colors.grey.shade300 : Colors.grey),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(o.nama, style: TextStyle(fontSize: 14, color: penuh && !dipilih ? Colors.grey : null))),
            Text(o.harga > 0 ? '+${rupiah(o.harga)}' : 'Gratis', style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _tombolJumlah(IconData ikon, VoidCallback? aksi) => SizedBox(
        width: 36,
        height: 36,
        child: IconButton.outlined(onPressed: aksi, icon: Icon(ikon, size: 18), padding: EdgeInsets.zero),
      );
}
