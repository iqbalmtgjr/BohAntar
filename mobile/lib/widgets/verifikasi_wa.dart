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
  return _bukaLembarWA(context, minta, bolehEmail: false);
}

/// Verifikasi sebelum daftar akun email+password: nomor lewat WhatsApp, atau
/// kode di email sebagai cadangan (backend/verifikasi_email.go) — server
/// menerima salah satu. Daftar lewat Google tetap memakai [verifikasiNomorWA]
/// karena emailnya sudah diverifikasi Google. null = dibatalkan.
Future<({String wa, String email})?> verifikasiPendaftaran(BuildContext context, String phone, String email) async {
  final minta = await ApiService().mintaVerifikasiWA(phone);
  if (minta['wajib'] == true) {
    if (!context.mounted) return null;
    final kode = await _bukaLembarWA(context, minta, bolehEmail: minta['bisa_email'] == true);
    if (kode != _pakaiEmail) return kode == null ? null : (wa: kode, email: '');
  }
  if (!context.mounted) return null;
  final kode = await verifikasiEmail(context, email);
  return kode == null ? null : (wa: '', email: kode);
}

const _pakaiEmail = 'email'; // dikembalikan lembar WA saat pendaftar memilih email

Future<String?> _bukaLembarWA(BuildContext context, Map<String, dynamic> minta, {required bool bolehEmail}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    showDragHandle: true,
    builder: (_) => _LembarVerifikasiWA(
      kode: '${minta['kode']}',
      wa: '${minta['wa']}',
      teks: '${minta['teks']}',
      bolehEmail: bolehEmail,
    ),
  );
}

/// Kirim kode ke email lalu minta pendaftar mengetiknya. Mengembalikan kode,
/// '' kalau server belum mewajibkan, atau null kalau dibatalkan. Galat
/// (email sudah terdaftar, terlalu sering) dilempar ke pemanggil.
Future<String?> verifikasiEmail(BuildContext context, String email) async {
  if (!await ApiService().mintaKodeEmail(email)) return '';
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    showDragHandle: true,
    builder: (_) => _LembarKodeEmail(email: email),
  );
}

class _LembarVerifikasiWA extends StatefulWidget {
  final String kode, wa, teks;
  final bool bolehEmail;
  const _LembarVerifikasiWA({required this.kode, required this.wa, required this.teks, this.bolehEmail = false});

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
            if (widget.bolehEmail)
              TextButton(
                onPressed: () => Navigator.pop(context, _pakaiEmail),
                child: const Text('Tidak bisa WhatsApp? Pakai email saja'),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          ],
        ),
      ),
    );
  }
}

class _LembarKodeEmail extends StatefulWidget {
  final String email;
  const _LembarKodeEmail({required this.email});

  @override
  State<_LembarKodeEmail> createState() => _LembarKodeEmailState();
}

class _LembarKodeEmailState extends State<_LembarKodeEmail> {
  final _kode = TextEditingController();
  Timer? _hitung;
  int _sisaDetik = 60; // server menolak kirim ulang kurang dari semenit
  bool _memeriksa = false;
  String _galat = '';
  String _info = '';

  @override
  void initState() {
    super.initState();
    _mulaiHitung();
  }

  @override
  void dispose() {
    _hitung?.cancel();
    _kode.dispose();
    super.dispose();
  }

  void _mulaiHitung() {
    _hitung?.cancel();
    _sisaDetik = 60;
    _hitung = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _sisaDetik--);
      if (_sisaDetik <= 0) t.cancel();
    });
  }

  Future<void> _periksa() async {
    final kode = _kode.text.trim();
    if (kode.length != 6 || _memeriksa) return;
    setState(() {
      _memeriksa = true;
      _galat = '';
    });
    try {
      await ApiService().cekKodeEmail(widget.email, kode);
      if (mounted) Navigator.pop(context, kode);
    } catch (e) {
      if (mounted) setState(() => _galat = pesanGalat(e));
    } finally {
      if (mounted) setState(() => _memeriksa = false);
    }
  }

  Future<void> _kirimUlang() async {
    setState(() {
      _galat = '';
      _info = '';
    });
    try {
      await ApiService().mintaKodeEmail(widget.email);
      if (!mounted) return;
      _kode.clear();
      setState(() => _info = 'Kode baru sudah dikirim.');
      _mulaiHitung();
    } catch (e) {
      if (mounted) setState(() => _galat = pesanGalat(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final redup = AppTheme.teksRedup(context);
    return SafeArea(
      child: Padding(
        // Lembar naik di atas keyboard.
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Verifikasi email', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Kode 6 digit sudah kami kirim ke ${widget.email}. Ketik di sini, ya. '
              'Belum masuk? Cek folder Spam atau Promosi.',
              style: TextStyle(color: redup, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _kode,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 8),
              decoration: InputDecoration(
                counterText: '',
                hintText: '••••••',
                hintStyle: TextStyle(color: redup.withValues(alpha: 0.4)), // jangan terlihat seperti sudah terisi
              ),
              onChanged: (v) {
                if (v.trim().length == 6) _periksa();
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _memeriksa ? null : _periksa,
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
              child: _memeriksa
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Verifikasi'),
            ),
            const SizedBox(height: 8),
            if (_galat.isNotEmpty)
              Text(_galat, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.errorColor))
            else if (_info.isNotEmpty)
              Text(_info, textAlign: TextAlign.center, style: TextStyle(color: redup)),
            TextButton(
              onPressed: _sisaDetik > 0 ? null : _kirimUlang,
              child: Text(_sisaDetik > 0 ? 'Kirim ulang kode dalam $_sisaDetik detik' : 'Kirim ulang kode'),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          ],
        ),
      ),
    );
  }
}
