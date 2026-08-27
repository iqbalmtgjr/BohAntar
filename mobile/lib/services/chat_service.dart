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
        wsUrl = '$wsScheme://$wsHostPort/ws/chat/$orderID?$auth';
      } else {
        final host = kIsWeb ? 'localhost' : '10.0.2.2';
        wsUrl = 'ws://$host:8080/ws/chat/$orderID?$auth';
      }
      
      _channel = kIsWeb
          ? WebSocketChannel.connect(Uri.parse(wsUrl))
          : IOWebSocketChannel.connect(Uri.parse(wsUrl));
      
      _isConnected = true;
      _channel!.stream.listen(
        (data) {
          try {
            final json = jsonDecode(data as String);
            if (json['type'] == 'history') {
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
        onError: (e) {
          _isConnected = false;
          _notify();
        },
        onDone: () {
          _isConnected = false;
          _notify();
        },
      );
    } catch (e) {
      debugPrint('Chat connect error: $e');
      _isConnected = false;
    }
  }

  void sendMessage(String content) {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(jsonEncode({'content': content}));
    }
  }

  void addListener(Function(List<ChatMessage>) l) {
    _listeners.add(l);
  }

  void removeListener(Function(List<ChatMessage>) l) {
    _listeners.remove(l);
  }

  void _notify() {
    for (final l in _listeners) {
      l(List.unmodifiable(_messages));
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _isConnected = false;
    _messages.clear();
    _listeners.clear();
  }
}
