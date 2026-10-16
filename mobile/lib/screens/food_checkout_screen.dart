import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/tarif.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart';
import 'package:mobile/widgets/peta.dart';

/// Konfirmasi pesanan: ke mana diantar, bayar bagaimana, berapa totalnya.
///
/// Mengembalikan id pesanan lewat Navigator.pop saat berhasil; layar di bawahnya
/// yang meneruskannya sampai ke dashboard.
class FoodCheckoutScreen extends StatefulWidget {
  final Keranjang keranjang;
  final String riderName;
  final String riderPhone;
  const FoodCheckoutScreen({super.key, required this.keranjang, required this.riderName, required this.riderPhone});

  @override
  State<FoodCheckoutScreen> createState() => _FoodCheckoutScreenState();
}

class _FoodCheckoutScreenState extends State<FoodCheckoutScreen> {
  LatLng? _tujuan;
  EstimasiTarif? _estimasi;
  String _alamatTujuan = '';
  bool _mencariLokasi = true;
  String _metode = 'Tunai'; // "Tunai" | "PayAntar"
  final _catatan = TextEditingController();
  // Patokan untuk driver, ditempel ke alamat antar. Titik GPS dan nama jalan
  // sering tidak cukup untuk menemukan rumah di gang.
  final _patokan = TextEditingController();
  bool _mengirim = false;
  // Hitungan ongkir gagal: tanpa penanda ini barisnya tertulis "sedang
  // dihitung" selamanya dan tombol Pesan mati tanpa jalan keluar.
  bool _estimasiGagal = false;
  // Null = belum terbaca. Hanya untuk memberi tahu lebih awal; server tetap
  // yang menolak kalau saldo kurang.
  double? _saldo;

  Warung get _warung => widget.keranjang.warung;

  @override
  void initState() {
    super.initState();
    _pakaiLokasiSaya();
    _muatSaldo();
  }

  @override
  void dispose() {
    _catatan.dispose();
    _patokan.dispose();
    super.dispose();
  }

  /// Baris terakhir yang dikurangi sampai habis mengosongkan keranjang; tidak
  /// ada lagi yang bisa dipesan dari sini, jadi kembali ke menu.
  void _ubahBaris(BarisKeranjang b, int selisih) {
    setState(() => widget.keranjang.ubah(b, selisih));
    if (widget.keranjang.kosong) Navigator.pop(context);
  }

  Future<void> _muatSaldo() async {
    try {
      final res = await ApiService().getProfile();
      final saldo = (res['user']?['balance'] as num?)?.toDouble();
      if (mounted && saldo != null) setState(() => _saldo = saldo);
    } catch (_) {}
  }

  Future<void> _pakaiLokasiSaya() async {
    setState(() => _mencariLokasi = true);
    try {
      var izin = await Geolocator.checkPermission();
      if (izin == LocationPermission.denied) izin = await Geolocator.requestPermission();
      if (izin == LocationPermission.denied || izin == LocationPermission.deniedForever) {
        throw Exception('Izin lokasi ditolak');
      }
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
      await _pasangTujuan(LatLng(p.latitude, p.longitude));
    } catch (_) {
      if (!mounted) return;
      setState(() => _mencariLokasi = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lokasimu tidak terbaca. Pilih titik antar di peta.')),
      );
    }
  }

  Future<void> _pasangTujuan(LatLng titik) async {
    setState(() {
      _tujuan = titik;
      _estimasi = null;
      _alamatTujuan = '';
      _mencariLokasi = true;
    });
    _ambilEstimasi(titik);
    String? alamat;
    try {
      alamat = await MapsService().alamatDariTitik(titik);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _alamatTujuan = alamat ?? 'Titik yang dipilih di peta';
      _mencariLokasi = false;
    });
  }

  Future<void> _pilihDiPeta() async {
    final titik = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => _PetaPilihTitik(awal: _tujuan ?? _warung.posisi)),
    );
    if (titik != null) await _pasangTujuan(titik);
  }

  void _ubahAlamat() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.my_location, color: AppTheme.primaryBlue),
              title: const Text('Gunakan lokasi saya sekarang'),
              onTap: () {
                Navigator.pop(ctx);
                _pakaiLokasiSaya();
              },
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined, color: AppTheme.primaryBlue),
              title: const Text('Pilih titik di peta'),
              onTap: () {
                Navigator.pop(ctx);
                _pilihDiPeta();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Ongkir dan biaya jasa dihitung server, bukan di sini: jaraknya pun harus
  /// jarak versi server, karena itu yang nanti ditagih. Biaya jasa ditagih
  /// sekali per pesanan, bukan per porsi.
  Future<void> _ambilEstimasi(LatLng tujuan) async {
    setState(() => _estimasiGagal = false);
    try {
      final hasil = await ApiService().estimasiTarif(
        layanan: 'BohFood',
        dariLat: _warung.posisi.latitude,
        dariLng: _warung.posisi.longitude,
        keLat: tujuan.latitude,
        keLng: tujuan.longitude,
      );
      if (!mounted || _tujuan != tujuan) return;
      setState(() => _estimasi = hasil);
    } catch (e) {
      debugPrint('Estimasi ongkir gagal: $e');
      if (!mounted || _tujuan != tujuan) return;
      setState(() {
        _estimasi = null;
        _estimasiGagal = true;
      });
    }
  }

  Future<void> _pesan() async {
    final tujuan = _tujuan;
    if (tujuan == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tentukan dulu ke mana makanannya diantar.')));
      return;
    }
    setState(() => _mengirim = true);
    final alamat = _alamatTujuan.isEmpty ? 'Titik yang dipilih di peta' : _alamatTujuan;
    final patokan = _patokan.text.trim();
    try {
      final res = await ApiService().createOrder(
        pickup: _warung.nama,
        // Driver membaca alamat tujuan, jadi patokannya ikut di situ.
        dropoff: patokan.isEmpty ? alamat : '$alamat (Patokan: $patokan)',
        service: 'BohFood',
        paymentMethod: _metode == 'PayAntar' ? 'wallet' : 'cash',
        pickupLat: _warung.posisi.latitude,
        pickupLng: _warung.posisi.longitude,
        dropoffLat: tujuan.latitude,
        dropoffLng: tujuan.longitude,
        packageNotes: _catatan.text.trim(),
        merchantId: _warung.id,
        items: widget.keranjang.keJson(),
      );
      final id = res['order']?['id'];
      if (id == null) throw Exception('Server tidak mengembalikan nomor pesanan');
      if (!mounted) return;
      Navigator.pop(context, id.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _mengirim = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: AppTheme.errorColor),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final k = widget.keranjang;
    final estimasi = _estimasi;
    final ongkir = estimasi?.ongkos ?? 0;
    final biayaJasa = estimasi?.biayaJasa ?? 0;
    final total = k.subtotal + ongkir + biayaJasa;
    final tunai = _metode == 'Tunai';
    // Saldo belum terbaca dianggap cukup; server yang menolak kalau ternyata
    // kurang. Saldo yang tertahan pesanan lain tidak terlihat dari sini.
    final saldoCukup = _saldo == null || _saldo! >= total;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Konfirmasi pesanan', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _muatSaldo,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _bagian(
            'Diantar ke',
            _kartu(
              isDark,
              Row(
                children: [
                  const Icon(Icons.location_on, color: AppTheme.errorColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _mencariLokasi
                        ? Text('Mencari lokasimu…', style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13))
                        : Text(
                            _tujuan == null ? 'Belum ada titik antar' : _alamatTujuan,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _tujuan == null ? AppTheme.errorColor : null),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  TextButton(onPressed: _ubahAlamat, child: Text(_tujuan == null ? 'Pilih' : 'Ubah')),
                ],
              ),
            ),
            bawah: TextField(
              controller: _patokan,
              maxLength: 150,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Patokan untuk driver, mis. pagar hijau sebelah masjid',
                prefixIcon: Icon(Icons.signpost_outlined, size: 20),
                isDense: true,
                counterText: '',
              ),
            ),
          ),

          _bagian(
            'Pesananmu dari ${_warung.nama}',
            _kartu(
              isDark,
              Column(
                children: [
                  for (final b in k.baris)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(b.menu.nama, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                if (b.opsi.isNotEmpty) Text(b.teksOpsi, style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
                                Text(rupiah(b.subtotal), style: const TextStyle(fontSize: 13)),
                              ],
                            ),
                          ),
                          // Jumlah diubah di sini, tanpa kembali ke menu dan
                          // tanpa menebak varian mana yang dimaksud.
                          PengaturJumlah(
                            jumlah: b.jumlah,
                            saatKurang: _mengirim ? null : () => _ubahBaris(b, -1),
                            saatTambah: _mengirim || b.jumlah >= Keranjang.maksPorsi ? null : () => _ubahBaris(b, 1),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _mengirim ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Tambah menu lain'),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    ),
                  ),
                ],
              ),
            ),
          ),

          _bagian(
            'Catatan untuk warung',
            TextField(
              controller: _catatan,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Contoh: tanpa sambal, pedas sedang', isDense: true),
            ),
          ),

          _bagian(
            'Cara bayar',
            Column(
              children: [
                _KartuMetode(
                  ikon: Icons.payments_outlined,
                  judul: 'Tunai',
                  keterangan: 'Bayar ke driver saat makanan tiba',
                  dipilih: tunai,
                  isDark: isDark,
                  saatTekan: () => setState(() => _metode = 'Tunai'),
                ),
                const SizedBox(height: 8),
                _KartuMetode(
                  ikon: Icons.account_balance_wallet_outlined,
                  judul: 'PayAntar',
                  keterangan: _saldo == null
                      ? 'Dipotong dari saldo setelah makanan diterima'
                      : saldoCukup
                          ? 'Saldo ${rupiah(_saldo!)} · dipotong setelah makanan diterima'
                          : 'Saldo ${rupiah(_saldo!)} tidak cukup. Pilih Tunai atau isi saldo dari beranda.',
                  peringatan: !saldoCukup,
                  dipilih: !tunai,
                  isDark: isDark,
                  saatTekan: () => setState(() => _metode = 'PayAntar'),
                ),
              ],
            ),
          ),

          _bagian(
            'Rincian pembayaran',
            _kartu(
              isDark,
              Column(
                children: [
                  _barisHarga('Makanan (${k.totalPorsi} porsi)', k.subtotal),
                  _barisHarga(
                    estimasi == null ? 'Ongkir' : 'Ongkir (${estimasi.km.toStringAsFixed(1).replaceAll('.', ',')} km)',
                    ongkir,
                    keterangan: estimasi != null
                        ? null
                        : _tujuan == null
                            ? 'pilih titik antar dulu'
                            : _estimasiGagal
                                ? 'gagal dihitung'
                                : 'sedang dihitung',
                  ),
                  if (_estimasiGagal && _tujuan != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _ambilEstimasi(_tujuan!),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Hitung ulang ongkir'),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                    ),
                  if (biayaJasa > 0) _barisHarga('Biaya jasa aplikasi', biayaJasa),
                  const Divider(height: 20),
                  _barisHarga('Total', total, tebal: true),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 15, color: AppTheme.teksRedup(context)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tunai
                              ? 'Driver membayar dulu ke warung. Kamu bayar total ini ke driver saat makanan tiba.'
                              : 'Driver membayar dulu ke warung. Saldo PayAntar-mu dipotong setelah makanan diterima.',
                          style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context)),
                        ),
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
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton(
            // Ongkirnya belum diketahui selama estimasi belum datang, dan
            // tombolnya menyebut total — jadi jangan biarkan ditekan sebelum
            // angka yang tertulis di situ benar.
            onPressed: estimasi == null || _mengirim || _mencariLokasi || (!tunai && !saldoCukup) ? null : _pesan,
            child: _mengirim
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text('Pesan sekarang · ${rupiah(total)}'),
          ),
        ),
      ),
    );
  }

  Widget _bagian(String judul, Widget isi, {Widget? bawah}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(judul, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          isi,
          if (bawah != null) ...[const SizedBox(height: 8), bawah],
          const SizedBox(height: 20),
        ],
      );

  Widget _kartu(bool isDark, Widget anak) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardObsidianDark : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.withOpacity(0.15)),
        ),
        child: anak,
      );

  Widget _barisHarga(String label, double nilai, {bool tebal = false, String? keterangan}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: tebal ? 15 : 13, fontWeight: tebal ? FontWeight.bold : FontWeight.normal, color: tebal ? null : AppTheme.teksRedup(context))),
            ),
            if (keterangan != null)
              Text(keterangan, style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context), fontStyle: FontStyle.italic))
            else
              Text(
                rupiah(nilai),
                style: TextStyle(fontSize: tebal ? 18 : 13, fontWeight: tebal ? FontWeight.w900 : FontWeight.w500, color: tebal ? AppTheme.primaryBlue : null),
              ),
          ],
        ),
      );
}

class _KartuMetode extends StatelessWidget {
  final IconData ikon;
  final String judul;
  final String keterangan;
  final bool dipilih;
  final bool peringatan; // keterangan ditulis merah: metode ini tidak bisa dipakai sekarang
  final bool isDark;
  final VoidCallback saatTekan;
  const _KartuMetode({required this.ikon, required this.judul, required this.keterangan, required this.dipilih, required this.isDark, required this.saatTekan, this.peringatan = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: saatTekan,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardObsidianDark : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: dipilih ? AppTheme.primaryBlue : Colors.grey.withOpacity(0.2), width: dipilih ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(ikon, color: dipilih ? AppTheme.primaryBlue : Colors.grey, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(judul, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(keterangan, style: TextStyle(color: peringatan ? AppTheme.errorColor : AppTheme.teksRedup(context), fontSize: 11)),
                ],
              ),
            ),
            Icon(dipilih ? Icons.radio_button_checked : Icons.radio_button_off, color: dipilih ? AppTheme.primaryBlue : Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Peta dengan pin di tengah: geser petanya, bukan pinnya. Lebih mudah dikenai
/// jempol daripada menyeret penanda kecil, dan tidak butuh dukungan drag dari
/// flutter_map.
class _PetaPilihTitik extends StatefulWidget {
  final LatLng awal;
  const _PetaPilihTitik({required this.awal});

  @override
  State<_PetaPilihTitik> createState() => _PetaPilihTitikState();
}

class _PetaPilihTitikState extends State<_PetaPilihTitik> {
  final _peta = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Geser peta ke titik antar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _peta,
            options: MapOptions(initialCenter: widget.awal, initialZoom: 16),
            children: [ubinOSM, sumberPeta],
          ),
          // Ujung pin tepat di pusat peta: ikonnya digeser naik setengah tinggi.
          const IgnorePointer(
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 44),
                child: Icon(Icons.location_pin, size: 44, color: AppTheme.errorColor),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, _peta.camera.center),
              icon: const Icon(Icons.check),
              label: const Text('Antar ke titik ini'),
            ),
          ),
        ],
      ),
    );
  }
}
