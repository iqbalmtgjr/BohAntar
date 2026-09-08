import 'package:flutter/material.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Layar pindai QR setoran komisi.
///
/// Dipakai driver setelah menyerahkan uang tunai ke petugas: petugas membuat
/// setoran di dashboard, QR-nya muncul di layar mereka, driver memindainya, dan
/// saldo driver naik sebesar uang yang tadi diserahkan.
class PindaiSetoranScreen extends StatefulWidget {
  const PindaiSetoranScreen({super.key});

  @override
  State<PindaiSetoranScreen> createState() => _PindaiSetoranScreenState();
}

class _PindaiSetoranScreenState extends State<PindaiSetoranScreen> {
  final MobileScannerController _kamera = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  // Kamera memuntahkan hasil berkali-kali per detik. Tanpa penjaga ini satu QR
  // bisa terkirim beberapa kali sekaligus; server memang menolak yang kedua,
  // tapi driver akan melihat pesan "sudah pernah dipindai" untuk setorannya
  // sendiri yang baru saja berhasil.
  bool _sedangMengirim = false;
  String? _pesanGagal;

  @override
  void dispose() {
    _kamera.dispose();
    super.dispose();
  }

  Future<void> _kirim(String isi) async {
    if (_sedangMengirim) return;
    setState(() {
      _sedangMengirim = true;
      _pesanGagal = null;
    });
    try {
      final hasil = await ApiService().klaimSetoran(isi);
      if (!mounted) return;
      Navigator.pop(context, hasil);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sedangMengirim = false;
        _pesanGagal = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Pindai QR Setoran'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _kamera,
            onDetect: (capture) {
              final isi = capture.barcodes.firstOrNull?.rawValue;
              if (isi != null && isi.isNotEmpty) {
                _kirim(isi);
              }
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Kamera tidak bisa dibuka: ${error.errorCode.name}.\n'
                  'Pastikan izin kamera diberikan di pengaturan aplikasi.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
          // Bingkai bidik.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 40,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_sedangMengirim)
                  const CircularProgressIndicator(color: Colors.white)
                else if (_pesanGagal != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _pesanGagal!,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Mode noDuplicates menolak membaca QR yang sama dua kali, jadi
                  // kegagalan sesaat (jaringan putus) akan membuat layar ini buntu
                  // tanpa tombol ini. Memulai ulang kamera membersihkan riwayatnya.
                  ElevatedButton.icon(
                    onPressed: () async {
                      await _kamera.stop();
                      await _kamera.start();
                      if (mounted) setState(() => _pesanGagal = null);
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Pindai ulang'),
                  ),
                ]
                else
                  const Text(
                    'Arahkan ke QR di layar petugas',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
