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

/// Langkah 3 dari 3: ke mana diantar, bayar bagaimana, berapa totalnya.
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
  String _alamatTujuan = '';
  bool _mencariLokasi = true;
  String _metode = 'Tunai'; // "Tunai" | "PayAntar"
  final _catatan = TextEditingController();
  bool _mengirim = false;

  Warung get _warung => widget.keranjang.warung;

  @override
  void initState() {
    super.initState();
    _pakaiLokasiSaya();
  }

  @override
  void dispose() {
    _catatan.dispose();
    super.dispose();
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
      _alamatTujuan = '';
      _mencariLokasi = true;
    });
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

  double get _jarakKm {
    final t = _tujuan;
    if (t == null) return 0;
    return Geolocator.distanceBetween(_warung.posisi.latitude, _warung.posisi.longitude, t.latitude, t.longitude) / 1000.0;
  }

  /// Taksiran; angka finalnya dihitung server dengan rumus yang sama.
  double get _ongkir => _tujuan == null ? 0 : Tarif.untuk('BohFood').hitung(_jarakKm);

  /// Biaya jasa aplikasi. Ditagih sekali per pesanan, bukan per porsi, dan
  /// hanya kalau titik antarnya sudah dipilih — sebelum itu belum ada pesanan.
  double get _biayaJasa => _tujuan == null ? 0 : Tarif.untuk('BohFood').biayaJasa;

  Future<void> _pesan() async {
    final tujuan = _tujuan;
    if (tujuan == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tentukan dulu ke mana makanannya diantar.')));
      return;
    }
    setState(() => _mengirim = true);
    try {
      final res = await ApiService().createOrder(
        pickup: _warung.nama,
        dropoff: _alamatTujuan.isEmpty ? 'Titik yang dipilih di peta' : _alamatTujuan,
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
    final total = k.subtotal + _ongkir + _biayaJasa;
    final tunai = _metode == 'Tunai';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Konfirmasi pesanan', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const LangkahPesan(aktif: 3),
          const SizedBox(height: 20),

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
                        ? const Text('Mencari lokasimu…', style: TextStyle(color: Colors.grey, fontSize: 13))
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
          ),

          _bagian(
            'Pesananmu dari ${_warung.nama}',
            _kartu(
              isDark,
              Column(
                children: [
                  for (final b in k.baris)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(width: 32, child: Text('${b.jumlah}×', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                          Expanded(child: Text(b.menu.nama, style: const TextStyle(fontSize: 13))),
                          Text(rupiah(b.subtotal), style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _mengirim ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Ubah pesanan'),
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
                  keterangan: 'Dipotong dari saldo setelah makanan diterima',
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
                    _tujuan == null ? 'Ongkir' : 'Ongkir (${_jarakKm.toStringAsFixed(1).replaceAll('.', ',')} km)',
                    _ongkir,
                    keterangan: _tujuan == null ? 'pilih titik antar dulu' : null,
                  ),
                  if (_biayaJasa > 0) _barisHarga('Biaya jasa aplikasi', _biayaJasa),
                  const Divider(height: 20),
                  _barisHarga('Total', total, tebal: true),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, size: 15, color: Colors.grey),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tunai
                              ? 'Driver membayar dulu ke warung. Kamu bayar total ini ke driver saat makanan tiba.'
                              : 'Driver membayar dulu ke warung. Saldo PayAntar-mu dipotong setelah makanan diterima.',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
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
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton(
            onPressed: _tujuan == null || _mengirim || _mencariLokasi ? null : _pesan,
            child: _mengirim
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text('Pesan sekarang · ${rupiah(total)}'),
          ),
        ),
      ),
    );
  }

  Widget _bagian(String judul, Widget isi) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(judul, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          isi,
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
              child: Text(label, style: TextStyle(fontSize: tebal ? 15 : 13, fontWeight: tebal ? FontWeight.bold : FontWeight.normal, color: tebal ? null : Colors.grey)),
            ),
            if (keterangan != null)
              Text(keterangan, style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic))
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
  final bool isDark;
  final VoidCallback saatTekan;
  const _KartuMetode({required this.ikon, required this.judul, required this.keterangan, required this.dipilih, required this.isDark, required this.saatTekan});

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
                  Text(keterangan, style: const TextStyle(color: Colors.grey, fontSize: 11)),
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
