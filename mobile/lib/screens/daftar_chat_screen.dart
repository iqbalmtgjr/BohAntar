import 'package:flutter/material.dart';
import 'package:mobile/screens/chat_screen.dart';
import 'package:mobile/services/chat_service.dart';
import 'package:mobile/status_pesanan.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/food_widgets.dart' show PesanKosong;

/// Tab Chat di bar bawah pemesan, ala Gojek: semua percakapan per pesanan,
/// terbaru di atas, dengan jumlah pesan yang belum dibaca.
class DaftarChat extends StatefulWidget {
  final String myPhone;
  final String myName;
  const DaftarChat({super.key, required this.myPhone, required this.myName});

  @override
  State<DaftarChat> createState() => _DaftarChatState();
}

class _DaftarChatState extends State<DaftarChat> {
  // ponytail: chat sekarang hanya dengan driver, jadi "Driver" berisi sama
  // dengan "Semua chat". Tambah chip Merchant/CS begitu chatnya ada.
  bool _hanyaDriver = false;
  bool _memuat = true;

  static const _bulan = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

  @override
  void initState() {
    super.initState();
    _muat();
  }

  Future<void> _muat() async {
    if (!_memuat) setState(() => _memuat = true);
    await segarkanDaftarChat();
    if (mounted) setState(() => _memuat = false);
  }

  String _waktu(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return '';
    final kini = DateTime.now();
    final selisih = DateTime(kini.year, kini.month, kini.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (selisih == 0) return '${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
    if (selisih == 1) return 'Kemarin';
    return '${t.day} ${_bulan[t.month - 1]}';
  }

  String _nama(Map<String, dynamic> c) {
    final nama = (c['lawan_nama'] ?? '').toString().trim();
    if (nama.isNotEmpty) return nama;
    return c['lawan_peran'] == 'driver' ? 'Driver' : 'Penumpang';
  }

  // Layar chat menyegarkan daftar ini sendiri saat ditutup.
  void _buka(Map<String, dynamic> c) {
    final lawanDriver = c['lawan_peran'] == 'driver';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          orderID: c['order_id'].toString(),
          myPhone: widget.myPhone,
          myName: widget.myName,
          myRole: lawanDriver ? 'rider' : 'driver',
          otherName: _nama(c),
          otherPhone: (c['lawan_phone'] ?? '').toString(),
        ),
      ),
    );
  }

  Widget _chip(String label, bool pilih) {
    final aktif = _hanyaDriver == pilih;
    return ChoiceChip(
      label: Text(label),
      selected: aktif,
      showCheckmark: false,
      onSelected: (_) => setState(() => _hanyaDriver = pilih),
      selectedColor: AppTheme.primaryBlue.withValues(alpha: 0.12),
      side: BorderSide(color: aktif ? AppTheme.primaryBlue : Colors.grey.withValues(alpha: 0.3)),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: aktif ? FontWeight.w700 : FontWeight.w500,
        color: aktif ? AppTheme.teksBerwarna(context, AppTheme.primaryBlue) : AppTheme.teksRedup(context),
      ),
    );
  }

  Widget _baris(Map<String, dynamic> c, bool isDark) {
    final service = (c['service'] ?? '').toString();
    final belum = (c['belum_dibaca'] as num?)?.toInt() ?? 0;
    final nama = _nama(c);
    final redup = AppTheme.teksRedup(context);
    final pesan = '${c['dari_saya'] == true ? 'Kamu: ' : ''}${c['pesan_terakhir'] ?? ''}';

    return InkWell(
      onTap: () => _buka(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            // Inisial lawan bicara, dengan ikon layanan pesanannya di pojok.
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.12),
                  child: Text(
                    nama[0].toUpperCase(),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.teksBerwarna(context, AppTheme.primaryBlue)),
                  ),
                ),
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: AppTheme.warnaLayanan(service),
                      shape: BoxShape.circle,
                      border: Border.all(color: isDark ? AppTheme.bgObsidianDark : AppTheme.bgLight, width: 2),
                    ),
                    child: Icon(ikonLayanan(service), size: 11, color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(nama, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
                      ),
                      Text(
                        _waktu(c['waktu']),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: belum > 0 ? AppTheme.teksBerwarna(context, AppTheme.primaryBlue) : redup,
                          fontWeight: belum > 0 ? FontWeight.w700 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text('$service · ${labelStatus((c['status'] ?? '').toString())}', style: TextStyle(fontSize: 11.5, color: redup)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          pesan,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: belum > 0 ? null : redup,
                            fontWeight: belum > 0 ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (belum > 0) ...[
                        const SizedBox(width: 8),
                        Badge(
                          label: Text(belum > 99 ? '99+' : '$belum'),
                          largeSize: 20,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                      ],
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return ValueListenableBuilder(
      valueListenable: daftarChat,
      builder: (context, daftar, _) {
        final tampil = [
          for (final c in daftar ?? const <Map<String, dynamic>>[])
            if (!_hanyaDriver || c['lawan_peran'] == 'driver') c,
        ];
        return RefreshIndicator(
          onRefresh: segarkanDaftarChat,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: const EdgeInsets.only(bottom: 56),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Chat', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, fontSize: 24)),
                    const SizedBox(height: 2),
                    Text('Obrolan dengan driver pesananmu', style: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context))),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _chip('Semua chat', false),
                    const SizedBox(width: 8),
                    _chip('Driver', true),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (daftar == null && _memuat)
                const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CircularProgressIndicator()))
              else if (daftar == null)
                PesanKosong(
                  ikon: Icons.wifi_off,
                  judul: 'Chat belum bisa dimuat',
                  teks: 'Cek koneksi internetmu, lalu coba lagi.',
                  tombol: 'Coba lagi',
                  saatTekan: _muat,
                )
              else if (tampil.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: PesanKosong(
                    ikon: Icons.chat_bubble_outline,
                    judul: 'Belum ada chat',
                    teks: 'Chat dengan driver akan muncul di sini setelah kamu memesan.',
                  ),
                )
              else
                for (final (i, c) in tampil.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: 82, endIndent: 20, color: Colors.grey.withValues(alpha: 0.16)),
                  _baris(c, isDark),
                ],
            ],
          ),
        );
      },
    );
  }
}
