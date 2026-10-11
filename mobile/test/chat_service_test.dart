import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/chat_service.dart';

/// Di produksi Cloudflare/nginx memutus WebSocket yang diam ±1 menit. Dulu
/// layar chat tidak tahu sambungannya mati: pesan masuk tidak muncul sampai
/// layar ditutup dan dibuka lagi. Server tiruan ini memutus sambungan pertama;
/// ChatService harus menyambung sendiri dan menyusul pesan yang masuk selama
/// putus lewat riwayat.
Map<String, dynamic> pesan(String id, String isi) =>
    {'id': id, 'order_id': 'o1', 'sender_phone': '+620', 'sender_name': 'Driver', 'sender_role': 'driver', 'content': isi, 'timestamp': '2026-10-11T20:00:00+07:00'};

void main() {
  test('sambungan yang diputus server disambung lagi, pesan selama putus ikut masuk', () async {
    var sambungan = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.transform(WebSocketTransformer()).listen((ws) {
      sambungan++;
      if (sambungan == 1) {
        ws.add(jsonEncode({'type': 'history', 'messages': [pesan('m1', 'Saya di depan')]}));
        // Diputus seperti oleh proxy, tanpa layar chat tahu.
        Future.delayed(const Duration(milliseconds: 200), ws.close);
      } else {
        // Pesan m2 dikirim selama sambungan putus; riwayat membawanya.
        ws.add(jsonEncode({'type': 'history', 'messages': [pesan('m1', 'Saya di depan'), pesan('m2', 'Pintu biru')]}));
        ws.listen((_) {});
      }
    });

    final chat = ChatService(alamatUji: 'ws://127.0.0.1:${server.port}/ws/chat/o1');
    final masuk = Completer<void>();
    chat.addListener((daftar) {
      if (daftar.length == 2 && !masuk.isCompleted) masuk.complete();
    });
    chat.connect(orderID: 'o1', phone: '+621', name: 'Penumpang', role: 'rider');

    await masuk.future.timeout(const Duration(seconds: 10));
    expect(sambungan, 2);
    expect(chat.messages.map((m) => m.content), ['Saya di depan', 'Pintu biru']);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(chat.isConnected, isTrue);
    expect(chat.sendMessage('Oke'), isTrue);

    // Ke latar belakang: sambungan ditutup dan TIDAK disambung ulang sendiri,
    // supaya server tahu penerima tidak sedang membaca dan mengirim push.
    chat.jeda();
    expect(chat.sendMessage('Hilang?'), isFalse, reason: 'pesan saat putus harus ditolak, bukan dibuang diam-diam');
    await Future.delayed(const Duration(seconds: 4));
    expect(sambungan, 2);

    chat.lanjut();
    await Future.delayed(const Duration(milliseconds: 500));
    expect(sambungan, 3);
    expect(chat.isConnected, isTrue);

    chat.disconnect();
    await server.close(force: true);
  });
}
