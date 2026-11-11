import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Verifikasi nomor sebelum akun dibuat: pendaftar mengirim kode lewat
/// WhatsApp ke nomor BohAntar, server menerima pesannya dan mencocokkan nomor
/// pengirim. Mengembalikan kode untuk dikirim bersama pendaftaran, '' kalau
/// server belum mewajibkan verifikasi, atau null kalau dibatalkan.
/// Galat dari server (nomor tidak valid, sudah terdaftar) dilempar ke pemanggil.
Future<String?> verifikasiNomorWA(BuildContext context, String phone) async {
  final minta = await ApiService().mintaVerifikasiWA(phone);
  if (minta['wajib'] != true) return '';
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    showDragHandle: true,
    builder: (_) => _LembarVerifikasiWA(
      kode: '${minta['kode']}',
      wa: '${minta['wa']}',
      teks: '${minta['teks']}',
    ),
  );
}

class _LembarVerifikasiWA extends StatefulWidget {
  final String kode, wa, teks;
  const _LembarVerifikasiWA({required this.kode, required this.wa, required this.teks});

  @override
  State<_LembarVerifikasiWA> createState() => _LembarVerifikasiWAState();
}

class _LembarVerifikasiWAState extends State<_LembarVerifikasiWA> {
  Timer? _tanya;
  bool _sudahDibuka = false;
  bool _kedaluwarsa = false;
  String _galat = '';

  @override
  void initState() {
    super.initState();
    // Ditanya terus, bukan menunggu kembali dari WhatsApp: pesannya bisa
    // sampai beberapa detik setelah pendaftar kembali ke aplikasi.
    _tanya = Timer.periodic(const Duration(seconds: 3), (_) => _cek());
  }

  @override
  void dispose() {
    _tanya?.cancel();
    super.dispose();
  }

  Future<void> _cek() async {
    try {
      if (await ApiService().cekVerifikasiWA(widget.kode) && mounted) {
        _tanya?.cancel();
        Navigator.pop(context, widget.kode);
      }
    } catch (e) {
      // Kode kedaluwarsa (15 menit): berhenti bertanya, pendaftar mulai lagi.
      _tanya?.cancel();
      if (mounted) {
        setState(() {
          _kedaluwarsa = true;
          _galat = pesanGalat(e);
        });
      }
    }
  }

  Future<void> _bukaWA() async {
    final url = Uri.parse('https://wa.me/${widget.wa}?text=${Uri.encodeComponent(widget.teks)}');
    final bisa = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() {
      _sudahDibuka = bisa;
      if (!bisa) _galat = 'WhatsApp tidak bisa dibuka. Pastikan WhatsApp terpasang di HP ini.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final redup = AppTheme.teksRedup(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Verifikasi nomor WhatsApp', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Supaya driver dan mitra bisa menghubungimu, kirim kode di bawah lewat WhatsApp dari nomor yang kamu daftarkan. Pesannya sudah disiapkan, tinggal tekan Kirim.',
              style: TextStyle(color: redup, height: 1.4),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(widget.kode, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 6)),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _kedaluwarsa ? null : _bukaWA,
              icon: const Icon(Icons.chat),
              label: Text(_sudahDibuka ? 'Buka WhatsApp lagi' : 'Kirim lewat WhatsApp'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
              ),
            ),
            const SizedBox(height: 12),
            if (_galat.isNotEmpty)
              Text(_galat, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.errorColor))
            else if (_sudahDibuka)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Menunggu pesanmu masuk…', style: TextStyle(color: redup)),
                ],
              ),
            const SizedBox(height: 4),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          ],
        ),
      ),
    );
  }
}
