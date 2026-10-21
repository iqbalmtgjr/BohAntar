import 'package:flutter/material.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/screens/food_checkout_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';

/// Pilih menu. Keranjang hidup di layar ini; batang di bawah selalu
/// memperlihatkan isinya dan satu ketukan membawa ke konfirmasi.
class FoodMenuScreen extends StatefulWidget {
  final Warung warung;
  /// Menu yang diketuk di etalase BohFood: lembar pesannya langsung dibuka
  /// begitu menu warung termuat.
  final String? menuAwal;
  final String riderName;
  final String riderPhone;
  const FoodMenuScreen({super.key, required this.warung, this.menuAwal, required this.riderName, required this.riderPhone});

  @override
  State<FoodMenuScreen> createState() => _FoodMenuScreenState();
}

class _FoodMenuScreenState extends State<FoodMenuScreen> {
  List<MenuMakanan> _menu = [];
  bool _memuat = true;
  String? _galat;
  String _kategori = 'Semua';
  final _cari = TextEditingController();
  late bool _menuAwalBelumDibuka = widget.menuAwal != null;
  late final Keranjang _keranjang = Keranjang(widget.warung);

  @override
  void initState() {
    super.initState();
    _muat();
  }

  @override
  void dispose() {
    _cari.dispose();
    super.dispose();
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
      // Sekali saja: tarik-untuk-muat-ulang tidak membuka lembarnya lagi.
      final awal = _menuAwalBelumDibuka ? _menu.where((m) => m.id == widget.menuAwal).firstOrNull : null;
      _menuAwalBelumDibuka = false;
      if (awal != null && widget.warung.buka && awal.tersedia) _lembarPesan(awal);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _galat = pesanGalat(e);
        _memuat = false;
      });
    }
  }

  List<String> get _kategoriTersedia => ['Semua', ...{for (final m in _menu) if (m.kategori.isNotEmpty) m.kategori}];

  /// Pencarian mengabaikan kategori yang sedang dipilih: yang mengetik "teh"
  /// mencari di seluruh warung, bukan cuma di tab Makanan yang kebetulan aktif.
  List<MenuMakanan> get _tersaring {
    final q = _cari.text.trim().toLowerCase();
    if (q.isNotEmpty) return _menu.where((m) => m.nama.toLowerCase().contains(q)).toList();
    return _kategori == 'Semua' ? _menu : _menu.where((m) => m.kategori == _kategori).toList();
  }

  /// Menu tanpa varian langsung masuk keranjang; yang bervarian memilih dulu
  /// lewat lembar bawah, seperti GoFood.
  Future<void> _tambah(MenuMakanan m) async {
    if (!m.punyaVarian) {
      setState(() => _keranjang.tambah(m));
      return;
    }
    await _lembarPesan(m);
  }

  /// Lembar foto + varian + jumlah. Menu tanpa varian juga bisa memakainya —
  /// dari etalase, pemesan perlu melihat menunya dulu sebelum masuk keranjang.
  Future<void> _lembarPesan(MenuMakanan m) async {
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

  /// Menu bervarian bisa ada di beberapa baris (es teh manis, es teh lemon).
  /// "−" tidak boleh menebak baris mana yang dikurangi, jadi pemesan memilih.
  Future<void> _kurangi(MenuMakanan m) async {
    final baris = _keranjang.barisMenu(m);
    if (baris.length <= 1) {
      setState(() => _keranjang.kurangi(m));
      return;
    }
    final tambahLain = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _LembarBarisMenu(_keranjang, m),
    );
    if (!mounted) return;
    setState(() {});
    if (tambahLain == true) _tambah(m);
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
    // Keranjang hanya hidup di layar ini. Kembali tanpa bertanya membuang
    // pilihan yang mungkin sudah lama disusun, termasuk variannya.
    return PopScope(
      canPop: _keranjang.kosong,
      onPopInvokedWithResult: (sudahKeluar, _) async {
        if (sudahKeluar) return;
        final keluar = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Kosongkan keranjang?'),
            content: Text('${_keranjang.totalPorsi} porsi dari ${widget.warung.nama} akan dihapus kalau kamu keluar.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Tetap di sini')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Keluar')),
            ],
          ),
        );
        if (keluar == true && context.mounted) Navigator.pop(context);
      },
      child: _halaman(context),
    );
  }

  Widget _halaman(BuildContext context) {
    final w = widget.warung;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _muat,
        child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
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
                      Icon(Icons.place_outlined, size: 15, color: AppTheme.teksRedup(context)),
                      const SizedBox(width: 4),
                      Expanded(child: Text(w.alamat, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis)),
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
                      child: Row(
                        children: [
                          Icon(Icons.schedule, size: 18, color: Colors.orange.shade800),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              [
                                'Warung sedang tutup.',
                                if (w.infoBuka.isNotEmpty) '${w.infoBuka}.',
                                'Kamu bisa lihat menunya, tapi belum bisa memesan.',
                              ].join(' '),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_menu.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _cari,
                      onChanged: (_) => setState(() {}),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Cari menu di ${w.nama}',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _cari.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Hapus pencarian',
                                onPressed: () => setState(_cari.clear),
                              ),
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                  ],
                  // Saat mencari, chip kategori disembunyikan: hasilnya dari
                  // seluruh warung, jadi chip yang terpilih hanya menyesatkan.
                  if (_kategoriTersedia.length > 2 && _cari.text.trim().isEmpty) ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _kategoriTersedia.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
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
          else if (_tersaring.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: PesanKosong(ikon: Icons.search_off, judul: 'Menu tidak ditemukan', teks: 'Tidak ada menu "${_cari.text.trim()}" di warung ini.'),
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
                      saatKurang: () => _kurangi(m),
                    );
                  },
                  childCount: _tersaring.length,
                ),
              ),
            ),
        ],
      ),
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
                    Text(m.deskripsi, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(m.teksHarga, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.primaryBlue)),
                      if (!m.tersedia) ...[
                        const SizedBox(width: 8),
                        Pil('Habis', warna: Colors.grey.shade600),
                      ],
                    ],
                  ),
                  if (m.punyaVarian) ...[
                    const SizedBox(height: 4),
                    Text('Bisa pilih varian', style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 11)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(width: 112, height: 112, child: GambarJaringan(url: m.gambar, pengganti: Icons.fastfood_outlined)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 112,
                  height: 44,
                  child: jumlah == 0
                      ? OutlinedButton(
                          onPressed: bisaPesan ? saatTambah : null,
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero,
                            foregroundColor: AppTheme.primaryBlue,
                            side: BorderSide(color: bisaPesan ? AppTheme.primaryBlue : Colors.grey.shade400),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          child: const Text('Tambah'),
                        )
                      : PengaturJumlah(jumlah: jumlah, saatTambah: bisaPesan ? saatTambah : null, saatKurang: saatKurang),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Baris-baris satu menu bervarian di keranjang, masing-masing dengan −/+.
/// Mengembalikan true kalau pemesan ingin menambah varian lain.
class _LembarBarisMenu extends StatefulWidget {
  final Keranjang keranjang;
  final MenuMakanan menu;
  const _LembarBarisMenu(this.keranjang, this.menu);

  @override
  State<_LembarBarisMenu> createState() => _LembarBarisMenuState();
}

class _LembarBarisMenuState extends State<_LembarBarisMenu> {
  @override
  Widget build(BuildContext context) {
    final baris = widget.keranjang.barisMenu(widget.menu);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.menu.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          const SizedBox(height: 4),
          Text('Pilih varian yang mau diubah', style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13)),
          const SizedBox(height: 12),
          for (final b in baris)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.teksOpsi.isEmpty ? 'Tanpa varian' : b.teksOpsi, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        Text(rupiah(b.subtotal), style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12)),
                      ],
                    ),
                  ),
                  PengaturJumlah(
                    jumlah: b.jumlah,
                    saatKurang: () => setState(() => widget.keranjang.ubah(b, -1)),
                    saatTambah: b.jumlah < Keranjang.maksPorsi ? () => setState(() => widget.keranjang.ubah(b, 1)) : null,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.add),
                label: const Text('Varian lain'),
              ),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Selesai')),
            ],
          ),
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
                      mainAxisSize: MainAxisSize.min,
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
                if (m.gambar.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: AspectRatio(aspectRatio: 16 / 9, child: GambarJaringan(url: m.gambar, pengganti: Icons.fastfood_outlined)),
                  ),
                  const SizedBox(height: 14),
                ],
                Text(m.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                if (m.deskripsi.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(m.deskripsi, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13, height: 1.35)),
                ],
                const SizedBox(height: 4),
                Text(m.teksHarga, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13)),
                for (final g in m.grup) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(child: Text(g.nama, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                      Pil(g.wajib ? 'Wajib' : 'Opsional', warna: g.wajib ? Colors.orange.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.15), warnaTeks: g.wajib ? Colors.orange.shade800 : Colors.grey.shade700),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(g.petunjuk, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 11)),
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
            Expanded(child: Text(o.nama, style: TextStyle(fontSize: 14, color: penuh && !dipilih ? AppTheme.teksRedup(context) : null))),
            if (o.harga > 0) Text('+${rupiah(o.harga)}', style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _tombolJumlah(IconData ikon, VoidCallback? aksi) => SizedBox(
        width: 44,
        height: 44,
        child: IconButton.outlined(onPressed: aksi, icon: Icon(ikon, size: 18), padding: EdgeInsets.zero),
      );
}
