import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'api_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

class ChatMessage {
  final String id;
  final String orderID;
  final String senderPhone;
  final String senderName;
  final String senderRole;
  final String content;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.orderID,
    required this.senderPhone,
    required this.senderName,
    required this.senderRole,
    required this.content,
    required this.timestamp,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] ?? '',
      orderID: json['order_id'] ?? '',
      senderPhone: json['sender_phone'] ?? '',
      senderName: json['sender_name'] ?? '',
      senderRole: json['sender_role'] ?? '',
      content: json['content'] ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
    );
  }
}

class ChatService {
  WebSocketChannel? _channel;
  StreamSubscription? _langganan;
  Timer? _ulang;
  String? _orderID;
  // Layar chat masih ingin tersambung. Selama ini benar, sambungan yang putus
  // disambung lagi sendiri.
  bool _dipakai = false;
  final List<ChatMessage> _messages = [];
  final List<Function(List<ChatMessage>)> _listeners = [];
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  void connect({
    required String orderID,
    required String phone,
    required String name,
    required String role,
  }) {
    _orderID = orderID;
    _dipakai = true;
    _sambung();
  }

  Future<void> _sambung() async {
    _ulang?.cancel();
    await _langganan?.cancel();
    if (!_dipakai || _orderID == null) return;
    try {
      // Identitas ditentukan backend dari token ini; phone/name/role hanya dipakai
      // untuk tampilan lokal. WebSocket tidak bisa mengirim header, jadi token
      // dilewatkan sebagai query parameter.
      final token = ApiService().token;
      if (token == null || token.isEmpty) {
        debugPrint('Chat: token tidak tersedia, koneksi dibatalkan');
        _isConnected = false;
        return;
      }
      final auth = 'token=${Uri.encodeComponent(token)}';
      String wsUrl;
      if (ApiService.isProduction) {
        final uri = Uri.parse(ApiService.prodUrl);
        final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
        final wsHostPort = uri.port != 0 && uri.port != 80 && uri.port != 443 ? '${uri.host}:${uri.port}' : uri.host;
        wsUrl = '$wsScheme://$wsHostPort/ws/chat/$_orderID?$auth';
      } else {
        final host = kIsWeb ? 'localhost' : '10.0.2.2';
        wsUrl = 'ws://$host:8080/ws/chat/$_orderID?$auth';
      }

      // Cloudflare dan nginx memutus sambungan yang diam ±1 menit. Ping menjaga
      // sambungan tetap hidup selama layar chat terbuka walau tidak ada yang
      // mengetik.
      final ch = kIsWeb
          ? WebSocketChannel.connect(Uri.parse(wsUrl))
          : IOWebSocketChannel.connect(Uri.parse(wsUrl), pingInterval: const Duration(seconds: 20));
      _channel = ch;
      _langganan = ch.stream.listen(
        (data) {
          try {
            final json = jsonDecode(data as String);
            if (json['type'] == 'history') {
              // Riwayat dikirim ulang tiap kali tersambung, jadi pesan yang masuk
              // selama putus ikut terbawa di sini.
              final list = json['messages'] as List? ?? [];
              _messages.clear();
              for (final m in list) {
                _messages.add(ChatMessage.fromJson(m));
              }
            } else if (json['type'] == 'message') {
              _messages.add(ChatMessage.fromJson(json['message']));
            }
            _notify();
          } catch (e) {
            debugPrint('Chat parse error: $e');
          }
        },
        onError: (_) => _putus(),
        onDone: _putus,
      );
      await ch.ready;
      if (identical(_channel, ch)) {
        _isConnected = true;
        _notify();
      }
    } catch (e) {
      debugPrint('Chat connect error: $e');
      _putus();
    }
  }

  void _putus() {
    _isConnected = false;
    _notify();
    _ulang?.cancel();
    // ponytail: jeda tetap 3 detik, bukan backoff. Yang menyambung paling
    // banyak dua HP per pesanan.
    if (_dipakai) _ulang = Timer(const Duration(seconds: 3), _sambung);
  }

  /// Mengembalikan false kalau sedang tidak tersambung, supaya layar bisa
  /// menahan teksnya alih-alih membuangnya diam-diam.
  bool sendMessage(String content) {
    if (_channel == null || !_isConnected) return false;
    _channel!.sink.add(jsonEncode({'content': content}));
    return true;
  }

  void addListener(Function(List<ChatMessage>) l) {
    _listeners.add(l);
  }

  void removeListener(Function(List<ChatMessage>) l) {
    _listeners.remove(l);
  }

  void _notify() {
    for (final l in List.of(_listeners)) {
      l(List.unmodifiable(_messages));
    }
  }

  /// Aplikasi ke latar belakang. Sambungannya sengaja ditutup: backend tidak
  /// mengirim notifikasi ke orang yang "sedang membuka chat", jadi HP di saku
  /// dengan layar chat tertinggal terbuka tidak akan pernah berdering.
  void jeda() {
    _tutup();
    _notify();
  }

  /// Aplikasi kembali ke depan.
  void lanjut() {
    if (_orderID == null || _dipakai) return;
    _dipakai = true;
    _sambung();
  }

  void _tutup() {
    _dipakai = false;
    _ulang?.cancel();
    _langganan?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
  }

  void disconnect() {
    _tutup();
    _orderID = null;
    _messages.clear();
    _listeners.clear();
  }
}
