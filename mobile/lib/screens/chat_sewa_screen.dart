import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile/screens/chat_screen.dart' show ChatBubble;
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/chat_service.dart' show ChatMessage;
import 'package:mobile/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Chat penyewa dengan mitra rental untuk satu sewa. Mitra membalas dari
/// dashboard web-nya, jadi percakapan ini lewat REST yang ditanya tiap 4 detik
/// selama layarnya terbuka, bukan WebSocket seperti chat driver.
class ChatSewaScreen extends StatefulWidget {
  final String bookingId;
  final String judul;
  final String myPhone;
  final String nomorLawan; // untuk tombol WhatsApp; kosong = tombolnya disembunyikan

  /// Sewa yang chatnya sedang di layar: notifikasi chat untuknya tidak perlu
  /// digambar, pesannya muncul sendiri lewat polling.
  static String? terbuka;

  const ChatSewaScreen({super.key, required this.bookingId, required this.judul, required this.myPhone, this.nomorLawan = ''});

  @override
  State<ChatSewaScreen> createState() => _ChatSewaScreenState();
}

class _ChatSewaScreenState extends State<ChatSewaScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage>? _pesan;
  String _galat = '';
  bool _mengirim = false;
  Timer? _tanya;

  @override
  void initState() {
    super.initState();
    ChatSewaScreen.terbuka = widget.bookingId;
    _muat();
    _tanya = Timer.periodic(const Duration(seconds: 4), (_) {
      // Di latar belakang tidak ada yang membaca; jangan tandai terbaca.
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _muat();
    });
  }

  @override
  void dispose() {
    _tanya?.cancel();
    if (ChatSewaScreen.terbuka == widget.bookingId) ChatSewaScreen.terbuka = null;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _muat() async {
    try {
      final data = await ApiService().getChatSewa(widget.bookingId);
      if (!mounted) return;
      final baru = data.length != (_pesan?.length ?? -1);
      setState(() {
        _pesan = [for (final m in data) ChatMessage.fromJson(m)];
        _galat = '';
      });
      if (baru) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _galat = pesanGalat(e));
    }
  }

  Future<void> _kirim() async {
    final isi = _input.text.trim();
    if (isi.isEmpty || _mengirim) return;
    setState(() => _mengirim = true);
    try {
      await ApiService().kirimChatSewa(widget.bookingId, isi);
      _input.clear();
      await _muat();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pesanGalat(e))));
    } finally {
      if (mounted) setState(() => _mengirim = false);
    }
  }

  Future<void> _bukaWA() async {
    var nomor = widget.nomorLawan.replaceAll(RegExp(r'\D'), '');
    if (nomor.startsWith('0')) nomor = '62${nomor.substring(1)}';
    if (!await launchUrl(Uri.parse('https://wa.me/$nomor'), mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WhatsApp tidak bisa dibuka')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pesan = _pesan;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.judul, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.nomorLawan.isNotEmpty)
            IconButton(
              onPressed: _bukaWA,
              icon: const Icon(Icons.phone_in_talk_outlined, color: Color(0xFF25D366)),
              tooltip: 'Telepon atau chat lewat WhatsApp',
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: pesan == null
                ? Center(
                    child: _galat.isEmpty
                        ? const CircularProgressIndicator()
                        : Padding(padding: const EdgeInsets.all(24), child: Text(_galat, textAlign: TextAlign.center)),
                  )
                : pesan.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'Tanyakan apa saja soal sewamu ke mitra: lokasi ambil, syarat, atau minta diantar.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.teksRedup(context)),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: pesan.length,
                        itemBuilder: (_, i) => ChatBubble(msg: pesan[i], isMe: pesan[i].senderPhone == widget.myPhone),
                      ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(top: BorderSide(color: isDark ? Colors.white10 : Colors.black12)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      maxLines: null,
                      maxLength: 1000,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _kirim(),
                      decoration: InputDecoration(
                        hintText: 'Tulis pesan...',
                        counterText: '',
                        filled: true,
                        fillColor: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _mengirim ? null : _kirim,
                    icon: const Icon(Icons.send_rounded, size: 20),
                    style: IconButton.styleFrom(backgroundColor: AppTheme.primaryBlue, foregroundColor: Colors.white, fixedSize: const Size(44, 44)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
