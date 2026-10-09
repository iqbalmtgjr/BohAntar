import 'package:flutter/material.dart';
import 'package:mobile/theme.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Layar kamera pemindai QR bohAntar.
///
/// Satu layar untuk dua peran, karena yang membedakannya cuma apa yang
/// dikerjakan sesudah QR-nya terbaca:
///
///  * Driver memindai QR setoran komisi di layar petugas — saldonya naik.
///  * Penumpang memindai QR tagihan warung — saldonya turun ke warung.
///
/// Yang dikerjakan setelah membaca diserahkan ke [onKode], jadi kamera, bingkai
/// bidik, penjaga pemindaian ganda, dan penanganan gagalnya cuma ditulis sekali.
class PindaiQRScreen extends StatefulWidget {
  const PindaiQRScreen({
    super.key,
    required this.judul,
    required this.petunjuk,
    required this.onKode,
  });

  final String judul;

  /// Kalimat di bawah bingkai bidik, mis. "Arahkan ke QR di layar petugas".
  final String petunjuk;

  /// Dipanggil sekali per QR yang terbaca.
  ///
  /// Kembalikan hasil apa pun yang bukan null untuk menutup layar dan
  /// menyerahkan hasil itu ke pemanggil; kembalikan null kalau pemindaiannya
  /// dibatalkan pengguna, dan kameranya dinyalakan lagi. Lemparkan Exception
  /// untuk menampilkan pesan gagal tanpa menutup layar.
  final Future<Object?> Function(String isi) onKode;

  @override
  State<PindaiQRScreen> createState() => _PindaiQRScreenState();
}

class _PindaiQRScreenState extends State<PindaiQRScreen> {
  final MobileScannerController _kamera = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  // Kamera memuntahkan hasil berkali-kali per detik. Tanpa penjaga ini satu QR
  // bisa terkirim beberapa kali sekaligus; server memang menolak yang kedua,
  // tapi pemindainya akan melihat pesan "sudah pernah dipindai" untuk
  // transaksinya sendiri yang baru saja berhasil.
  bool _sedangMengirim = false;
  String? _pesanGagal;

  @override
  void dispose() {
    _kamera.dispose();
    super.dispose();
  }

  /// Mode noDuplicates menolak membaca QR yang sama dua kali, jadi setiap
  /// kegagalan atau pembatalan harus memulai ulang kamera — kalau tidak, layar
  /// ini buntu di depan QR yang itu-itu juga.
  Future<void> _pindaiLagi() async {
    await _kamera.stop();
    await _kamera.start();
    if (mounted) {
      setState(() {
        _sedangMengirim = false;
        _pesanGagal = null;
      });
    }
  }

  Future<void> _kirim(String isi) async {
    if (_sedangMengirim) return;
    setState(() {
      _sedangMengirim = true;
      _pesanGagal = null;
    });
    try {
      final hasil = await widget.onKode(isi);
      if (!mounted) return;
      if (hasil == null) {
        await _pindaiLagi();
        return;
      }
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
        title: Text(widget.judul),
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
                  ElevatedButton.icon(
                    onPressed: _pindaiLagi,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Pindai ulang'),
                  ),
                ]
                else
                  Text(
                    widget.petunjuk,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
