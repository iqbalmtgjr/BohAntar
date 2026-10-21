import 'package:flutter/material.dart';
import 'package:mobile/models/food.dart' show rupiah;
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart' show GambarJaringan, PesanKosong;
import 'package:url_launcher/url_launcher.dart';

/// BohRental untuk penyewa: pilih kendaraan dari armada mitra, ajukan sewa,
/// lalu pantau di "Sewa saya". Mitra menyetujui dari dashboard web-nya;
/// pembayaran langsung ke mitra saat kendaraan diambil.
class RentalScreen extends StatefulWidget {
  final String myPhone;
  const RentalScreen({super.key, required this.myPhone});

  @override
  State<RentalScreen> createState() => _RentalScreenState();
}

class _RentalScreenState extends State<RentalScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  List<Map<String, dynamic>>? _katalog;
  List<Map<String, dynamic>>? _sewa;
  String? _galatKatalog;
  String? _galatSewa;
  String _jenis = 'semua'; // semua | car | motorcycle

  static const _hari = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
  static const _bulan = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

  @override
  void initState() {
    super.initState();
    _muatKatalog();
    _muatSewa();
    // Status sewa diubah mitra dari dashboard-nya; baca ulang tiap tab dibuka.
    _tab.addListener(() {
      if (_tab.index == 1 && !_tab.indexIsChanging) _muatSewa();
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _galat(Object e) => pesanGalat(e);

  Future<void> _muatKatalog() async {
    try {
      final k = await ApiService().getKatalogRental();
      if (mounted) {
        setState(() {
          _katalog = k;
          _galatKatalog = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _galatKatalog = _galat(e));
    }
  }

  Future<void> _muatSewa() async {
    try {
      final s = await ApiService().getSewaSaya(widget.myPhone);
      if (mounted) {
        setState(() {
          _sewa = s;
          _galatSewa = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _galatSewa = _galat(e));
    }
  }

  String _dua(int n) => n.toString().padLeft(2, '0');
  String _tanggal(DateTime t) => '${_hari[t.weekday - 1]}, ${t.day} ${_bulan[t.month - 1]} ${t.year}';
  String _waktu(DateTime t) => '${_tanggal(t)} · ${_dua(t.hour)}.${_dua(t.minute)}';
  String _keServer(DateTime t) => '${t.year}-${_dua(t.month)}-${_dua(t.day)} ${_dua(t.hour)}:${_dua(t.minute)}:00';
  String _nama(Map<String, dynamic> k) => '${k['brand'] ?? ''} ${k['model'] ?? ''}'.trim();
  IconData _ikonJenis(Object? jenis) => jenis == 'motorcycle' ? Icons.two_wheeler : Icons.directions_car;

  Color _kartu(bool isDark) => isDark ? AppTheme.cardObsidianDark : Colors.white;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BohRental'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: 'Sewa kendaraan'), Tab(text: 'Sewa saya')],
        ),
      ),
      body: TabBarView(controller: _tab, children: [_tabKatalog(), _tabSewa()]),
    );
  }

  // ---------- Katalog ----------

  Widget _chipJenis(String label, String jenis) {
    final aktif = _jenis == jenis;
    return ChoiceChip(
      label: Text(label),
      selected: aktif,
      showCheckmark: false,
      onSelected: (_) => setState(() => _jenis = jenis),
      selectedColor: AppTheme.warnaRental.withValues(alpha: 0.12),
      side: BorderSide(color: aktif ? AppTheme.warnaRental : Colors.grey.withValues(alpha: 0.3)),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: aktif ? FontWeight.w700 : FontWeight.w500,
        color: aktif ? AppTheme.teksBerwarna(context, AppTheme.warnaRental) : AppTheme.teksRedup(context),
      ),
    );
  }

  Widget _tabKatalog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tampil = [
      for (final k in _katalog ?? const <Map<String, dynamic>>[])
        if (_jenis == 'semua' || (k['vehicle_type'] ?? 'car') == _jenis) k,
    ];
    return RefreshIndicator(
      onRefresh: _muatKatalog,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Row(
            children: [
              _chipJenis('Semua', 'semua'),
              const SizedBox(width: 8),
              _chipJenis('Mobil', 'car'),
              const SizedBox(width: 8),
              _chipJenis('Motor', 'motorcycle'),
            ],
          ),
          const SizedBox(height: 14),
          if (_katalog == null && _galatKatalog == null)
            const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CircularProgressIndicator()))
          else if (_katalog == null)
            PesanKosong(ikon: Icons.wifi_off, judul: 'Kendaraan belum bisa dimuat', teks: _galatKatalog!, tombol: 'Coba lagi', saatTekan: _muatKatalog)
          else if (tampil.isEmpty)
            const PesanKosong(
              ikon: Icons.car_rental,
              judul: 'Belum ada kendaraan',
              teks: 'Mitra rental belum memasang armada untuk disewa. Cek lagi nanti, ya.',
            )
          else
            for (final k in tampil) _kartuKendaraan(k, isDark),
        ],
      ),
    );
  }

  Widget _kartuKendaraan(Map<String, dynamic> k, bool isDark) {
    final redup = AppTheme.teksRedup(context);
    final motor = k['vehicle_type'] == 'motorcycle';
    final alamat = (k['mitra_alamat'] ?? '').toString().trim();
    Widget info(IconData ikon, String teks) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ikon, size: 14, color: redup),
            const SizedBox(width: 4),
            Text(teks, style: TextStyle(fontSize: 12.5, color: redup)),
          ],
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _kartu(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.16)),
      ),
      child: InkWell(
        onTap: () => _bukaFormSewa(k),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: GambarJaringan(url: (k['image_url'] ?? '').toString(), pengganti: _ikonJenis(k['vehicle_type']), warna: AppTheme.primaryBlue),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_nama(k), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      info(_ikonJenis(k['vehicle_type']), motor ? 'Motor' : 'Mobil'),
                      if ((k['transmission'] ?? '').toString().isNotEmpty) info(Icons.settings_outlined, k['transmission'].toString()),
                      if (!motor && (k['seats'] as num? ?? 0) > 0) info(Icons.event_seat_outlined, '${k['seats']} kursi'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.storefront_outlined, size: 15, color: AppTheme.teksBerwarna(context, AppTheme.warnaRental)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          [k['mitra_nama'], if (alamat.isNotEmpty) alamat].where((s) => '${s ?? ''}'.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(rupiah(k['price_per_day'] as num? ?? 0),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppTheme.primaryBlue)),
                      Text(' /hari', style: TextStyle(fontSize: 12.5, color: redup)),
                      const Spacer(),
                      ElevatedButton(
                        onPressed: () => _bukaFormSewa(k),
                        style: ElevatedButton.styleFrom(minimumSize: const Size(96, 40), padding: const EdgeInsets.symmetric(horizontal: 18)),
                        child: const Text('Sewa'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Formulir sewa ----------

  Future<void> _bukaFormSewa(Map<String, dynamic> k) async {
    final besok = DateTime.now().add(const Duration(days: 1));
    var tanggal = DateTime(besok.year, besok.month, besok.day);
    var jam = const TimeOfDay(hour: 8, minute: 0);
    var lama = 1;
    var mengirim = false;
    String? galat;
    final harga = (k['price_per_day'] as num? ?? 0).toDouble();

    final jadi = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final mulai = DateTime(tanggal.year, tanggal.month, tanggal.day, jam.hour, jam.minute);
          final selesai = mulai.add(Duration(days: lama));
          final redup = AppTheme.teksRedup(ctx);

          Future<void> ajukan() async {
            if (!mulai.isAfter(DateTime.now())) {
              setSheet(() => galat = 'Jam ambilnya sudah lewat. Pilih waktu yang akan datang, ya.');
              return;
            }
            setSheet(() => (mengirim, galat) = (true, null));
            try {
              await ApiService().ajukanSewa(k['id'].toString(), _keServer(mulai), _keServer(selesai));
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              setSheet(() => (mengirim, galat) = (false, _galat(e)));
            }
          }

          Widget baris(IconData ikon, String label, String nilai, VoidCallback? ketuk) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(ikon, color: AppTheme.teksBerwarna(ctx, AppTheme.warnaRental)),
                title: Text(label, style: TextStyle(fontSize: 12.5, color: redup)),
                subtitle: Text(nilai, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                trailing: ketuk == null ? null : const Icon(Icons.chevron_right),
                onTap: ketuk,
              );

          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_nama(k), style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  Text('${k['mitra_nama'] ?? ''} · ${rupiah(harga)}/hari', style: TextStyle(color: redup, fontSize: 13)),
                  const SizedBox(height: 8),
                  baris(Icons.calendar_today_outlined, 'Tanggal ambil', _tanggal(tanggal), () async {
                    final hariIni = DateTime.now();
                    final pilih = await showDatePicker(
                      context: ctx,
                      initialDate: tanggal,
                      firstDate: DateTime(hariIni.year, hariIni.month, hariIni.day),
                      lastDate: hariIni.add(const Duration(days: 90)),
                    );
                    if (pilih != null) setSheet(() => tanggal = pilih);
                  }),
                  baris(Icons.schedule, 'Jam ambil', '${_dua(jam.hour)}.${_dua(jam.minute)}', () async {
                    final pilih = await showTimePicker(context: ctx, initialTime: jam);
                    if (pilih != null) setSheet(() => jam = pilih);
                  }),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.date_range_outlined, color: AppTheme.teksBerwarna(ctx, AppTheme.warnaRental)),
                    title: Text('Lama sewa', style: TextStyle(fontSize: 12.5, color: redup)),
                    subtitle: Text('$lama hari', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.outlined(
                          tooltip: 'Kurangi',
                          onPressed: lama > 1 ? () => setSheet(() => lama--) : null,
                          icon: const Icon(Icons.remove),
                        ),
                        const SizedBox(width: 6),
                        IconButton.outlined(
                          tooltip: 'Tambah',
                          onPressed: lama < 30 ? () => setSheet(() => lama++) : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                  baris(Icons.keyboard_return, 'Kembalikan paling lambat', _waktu(selesai), null),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Expanded(child: Text('Total ($lama hari × ${rupiah(harga)})', style: TextStyle(color: redup, fontSize: 13))),
                      Text(rupiah(harga * lama), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppTheme.primaryBlue)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warnaRental.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 18, color: AppTheme.teksBerwarna(ctx, AppTheme.warnaRental)),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Mitra akan mengonfirmasi sewamu dulu. Bayar langsung ke mitra saat mengambil kendaraan, dan bawa KTP serta SIM-mu.',
                            style: TextStyle(fontSize: 12.5, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (galat != null) ...[
                    const SizedBox(height: 10),
                    Text(galat!, style: const TextStyle(color: AppTheme.errorColor, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                  const SizedBox(height: 14),
                  ElevatedButton(
                    onPressed: mengirim ? null : ajukan,
                    child: mengirim
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('Ajukan sewa'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (jadi == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permintaan sewa terkirim. Tunggu konfirmasi mitra, ya.')),
      );
      _tab.animateTo(1);
      _muatSewa();
    }
  }

  // ---------- Sewa saya ----------

  static ({String label, Color warna}) _status(String s) => switch (s) {
        'pending' => (label: 'Menunggu konfirmasi', warna: const Color(0xFFB45309)),
        'confirmed' => (label: 'Dikonfirmasi', warna: AppTheme.primaryDarkBlue),
        'ongoing' => (label: 'Sedang disewa', warna: const Color(0xFF4F46E5)),
        'completed' => (label: 'Selesai', warna: const Color(0xFF047857)),
        'rejected' => (label: 'Ditolak', warna: const Color(0xFFDC2626)),
        'cancelled' => (label: 'Dibatalkan', warna: const Color(0xFFDC2626)),
        _ => (label: s, warna: AppTheme.textSecondary),
      };

  Widget _tabSewa() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RefreshIndicator(
      onRefresh: _muatSewa,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (_sewa == null && _galatSewa == null)
            const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CircularProgressIndicator()))
          else if (_sewa == null)
            PesanKosong(ikon: Icons.wifi_off, judul: 'Sewa belum bisa dimuat', teks: _galatSewa!, tombol: 'Coba lagi', saatTekan: _muatSewa)
          else if (_sewa!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: PesanKosong(
                ikon: Icons.car_rental,
                judul: 'Belum ada sewa',
                teks: 'Sewa mobil atau motor dari mitra BohRental, lalu pantau statusnya di sini.',
                tombol: 'Lihat kendaraan',
                saatTekan: () => _tab.animateTo(0),
              ),
            )
          else
            for (final b in _sewa!) _kartuSewa(b, isDark),
        ],
      ),
    );
  }

  Widget _kartuSewa(Map<String, dynamic> b, bool isDark) {
    final redup = AppTheme.teksRedup(context);
    final status = (b['status'] ?? '').toString();
    final st = _status(status);
    final mulai = DateTime.tryParse('${b['start_time']}');
    final selesai = DateTime.tryParse('${b['end_time']}');
    final denda = (b['late_fee'] as num? ?? 0).toDouble();
    final catatan = (b['notes'] ?? '').toString().trim();
    final plat = (b['plate_number'] ?? '').toString();
    final bisaBatal = status == 'pending' || status == 'confirmed';
    final adaMitra = (b['owner_phone'] ?? '').toString().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kartu(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: GambarJaringan(url: (b['image_url'] ?? '').toString(), pengganti: _ikonJenis(b['vehicle_type']), warna: AppTheme.primaryBlue),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${b['car_name'] ?? 'Kendaraan'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    Text('${b['owner_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: redup)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: st.warna.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                child: Text(st.label, style: TextStyle(color: AppTheme.teksBerwarna(context, st.warna), fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (mulai != null) Text('Ambil: ${_waktu(mulai)}', style: const TextStyle(fontSize: 13)),
          if (selesai != null) Text('Kembali: ${_waktu(selesai)}', style: const TextStyle(fontSize: 13)),
          if (plat.isNotEmpty && (status == 'confirmed' || status == 'ongoing'))
            Text('Plat: $plat', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(rupiah((b['total_price'] as num? ?? 0) + denda), style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primaryBlue, fontSize: 15)),
              if (denda > 0) Text('  termasuk denda telat ${rupiah(denda)}', style: TextStyle(fontSize: 12, color: redup)),
            ],
          ),
          if (catatan.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
              child: Text('Catatan mitra: $catatan', style: const TextStyle(fontSize: 12.5, height: 1.4)),
            ),
          ],
          if (adaMitra || bisaBatal) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (adaMitra)
                  OutlinedButton.icon(
                    onPressed: () => _hubungiMitra(b),
                    icon: const Icon(Icons.chat_outlined, size: 18),
                    label: const Text('Hubungi mitra'),
                  ),
                const Spacer(),
                if (bisaBatal)
                  TextButton(
                    onPressed: () => _batalkan(b),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
                    child: const Text('Batalkan'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Lewat WhatsApp, seperti chat driver: wa.me menuntut 62…, bukan 08….
  Future<void> _hubungiMitra(Map<String, dynamic> b) async {
    var nomor = (b['owner_phone'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
    if (nomor.startsWith('0')) nomor = '62${nomor.substring(1)}';
    final mulai = DateTime.tryParse('${b['start_time']}');
    final teks = 'Halo, saya penyewa ${b['car_name'] ?? 'kendaraan'} lewat BohRental'
        '${mulai == null ? '' : ' untuk ${_waktu(mulai)}'}.';
    final bisa = await launchUrl(Uri.parse('https://wa.me/$nomor?text=${Uri.encodeComponent(teks)}'), mode: LaunchMode.externalApplication);
    if (!bisa && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WhatsApp tidak bisa dibuka')));
    }
  }

  Future<void> _batalkan(Map<String, dynamic> b) async {
    final setuju = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Batalkan sewa?'),
        content: Text('Sewa ${b['car_name'] ?? 'kendaraan'} ini dibatalkan dan mitra akan melihatnya.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Tidak')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ya, batalkan')),
        ],
      ),
    );
    if (setuju != true) return;
    try {
      await ApiService().batalkanSewa(b['id'].toString());
      await _muatSewa();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_galat(e))));
    }
  }
}
