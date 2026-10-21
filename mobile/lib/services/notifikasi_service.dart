import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../firebase_config.dart';
import '../screens/chat_screen.dart';
import 'api_service.dart';
import 'chat_service.dart';

/// Notifikasi orderan masuk dan perubahan status pesanan.
///
/// Tanpa ini driver harus menatap layar terbuka supaya tidak kehilangan orderan,
/// dan penumpang tidak tahu apa-apa sampai membuka aplikasi lagi. Polling tiap
/// 3 detik tidak menggantikannya: begitu Android menidurkan aplikasi, polling
/// ikut berhenti.
///
/// Seluruh kelas ini gagal dengan diam. Firebase yang belum dikonfigurasi
/// (google-services.json belum ada) atau izin notifikasi yang ditolak tidak
/// boleh membuat aplikasi tidak bisa dipakai — hanya notifikasinya yang absen.

/// Handler pesan latar belakang wajib fungsi tingkat atas: Android menjalankannya
/// di isolate terpisah tanpa akses ke state aplikasi.
@pragma('vm:entry-point')
Future<void> _pesanLatarBelakang(RemoteMessage pesan) async {
  // Sengaja kosong. Payload `notification` sudah ditampilkan sistem sendiri;
  // handler ini hanya perlu ada supaya Firebase tidak menolak pesannya.
}

class NotifikasiService {
  static final NotifikasiService _instance = NotifikasiService._internal();
  factory NotifikasiService() => _instance;
  NotifikasiService._internal();

  bool _siap = false;
  final _lokal = FlutterLocalNotificationsPlugin();

  /// Kanal yang disebut backend di setiap notifikasi (`fcm.go`). Selama kanal
  /// ini belum dibuat, Android menaruh notifikasinya di kanal cadangan FCM yang
  /// tidak muncul melayang di atas layar.
  static const _kanal = AndroidNotificationChannel(
    'bohantar_orderan',
    'Pesanan & chat',
    importance: Importance.high,
  );

  /// Dipasang di MaterialApp supaya notifikasi chat yang diketuk bisa membuka
  /// layar chat dari mana pun, tanpa menitipkan BuildContext.
  static final navigatorKey = GlobalKey<NavigatorState>();

  /// Dipanggil sekali saat aplikasi mulai. Aman dipanggil berulang.
  Future<void> mulai() async {
    if (_siap) return;
    if (!firebaseSudahDikonfigurasi) {
      debugPrint('Firebase belum dikonfigurasi (lihat lib/firebase_config.dart) — notifikasi dilewati');
      return;
    }
    try {
      await Firebase.initializeApp(options: kFirebaseOptions);
      FirebaseMessaging.onBackgroundMessage(_pesanLatarBelakang);
      FirebaseMessaging.onMessage.listen(_pesanSaatAplikasiTerbuka);
      // Notifikasi sistem diketuk saat aplikasi di latar belakang.
      FirebaseMessaging.onMessageOpenedApp.listen(_bukaDariPesan);
      _siap = true;
    } catch (e) {
      debugPrint('Firebase gagal disiapkan, notifikasi dilewati: $e');
      return;
    }
    try {
      await _lokal.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        // Notifikasi yang kita gambar sendiri (aplikasi sedang terbuka) diketuk.
        onDidReceiveNotificationResponse: (r) => bukaChat(r.payload),
      );
      await _lokal
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_kanal);
    } catch (e) {
      debugPrint('Notifikasi lokal gagal disiapkan: $e');
    }
  }

  /// Android sengaja tidak menampilkan notifikasi selama aplikasinya terbuka —
  /// tanpa ini, pesan chat yang masuk saat penumpang sedang menatap peta tidak
  /// muncul di mana pun, dan itu justru saat yang paling sering terjadi.
  ///
  /// Hanya chat yang ditampilkan. Orderan baru dan perubahan status sudah
  /// menggambar layarnya sendiri lewat polling tiap 2–3 detik, jadi menampilkan
  /// keduanya cuma menumpuk pemberitahuan yang sama dua kali.
  ///
  /// Notifikasi sistem bersuara, bukan SnackBar: driver yang sedang menyetir
  /// dengan aplikasi terbuka tidak sedang menatap layar, dan SnackBar bisu lima
  /// detik itulah yang dulu membuat chat terasa "tidak ada notifikasinya".
  void _pesanSaatAplikasiTerbuka(RemoteMessage pesan) {
    if (pesan.data['tipe'] != 'chat') return;
    segarkanDaftarChat();
    final isi = pesan.notification?.body ?? '';
    final pengirim = pesan.notification?.title ?? 'Pesan baru';
    if (isi.isEmpty) return;

    _lokal
        .show(
          // Satu notifikasi per pesanan: pesan berikutnya menimpa, tidak menumpuk.
          id: (pesan.data['order_id'] ?? '').hashCode,
          title: pengirim,
          body: isi,
          payload: pesan.data['order_id'],
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              _kanal.id,
              _kanal.name,
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        )
        .catchError((e) => debugPrint('Notifikasi chat gagal ditampilkan: $e'));
  }

  void _bukaDariPesan(RemoteMessage pesan) {
    if (pesan.data['tipe'] == 'chat') bukaChat(pesan.data['order_id']);
  }

  /// Aplikasi baru dinyalakan karena notifikasi chat diketuk. Dipanggil
  /// setelah sesi pulih (AuthGate), karena layar chat butuh token.
  Future<void> bukaChatDariPeluncuran() async {
    if (!_siap) return;
    try {
      final fcm = await FirebaseMessaging.instance.getInitialMessage();
      if (fcm != null) return _bukaDariPesan(fcm);
      final lokal = await _lokal.getNotificationAppLaunchDetails();
      if (lokal?.didNotificationLaunchApp ?? false) {
        await bukaChat(lokal!.notificationResponse?.payload);
      }
    } catch (e) {
      debugPrint('Notifikasi peluncuran gagal dibaca: $e');
    }
  }

  /// Membuka layar chat satu pesanan. Notifikasi cuma membawa id pesanan;
  /// siapa saya dan siapa lawan bicaranya dibaca dari profil dan pesanannya.
  Future<void> bukaChat(String? orderId) async {
    final nav = navigatorKey.currentState;
    if (orderId == null || orderId.isEmpty || nav == null || ApiService().token == null) return;
    try {
      final saya = (await ApiService().getProfile())['user'] as Map?;
      final o = (await ApiService().getOrderStatus(orderId))['order'] as Map?;
      if (saya == null || o == null) return;
      final nomorSaya = (saya['phone_number'] ?? '').toString();
      final sayaDriver = o['driver_phone'] == nomorSaya;
      final namaDriver = (o['driver_name'] ?? '').toString();
      nav.push(MaterialPageRoute(
        builder: (_) => ChatScreen(
          orderID: orderId,
          myPhone: nomorSaya,
          myName: (saya['name'] ?? '').toString(),
          myRole: sayaDriver ? 'driver' : 'rider',
          otherName: sayaDriver ? (o['rider_name'] ?? 'Penumpang').toString() : (namaDriver.isEmpty ? 'Driver' : namaDriver),
          otherPhone: ((sayaDriver ? o['rider_phone'] : o['driver_phone']) ?? '').toString(),
        ),
      ));
    } catch (e) {
      debugPrint('Layar chat dari notifikasi gagal dibuka: $e');
    }
  }

  /// Dipanggil setelah login berhasil: token perangkat hanya berguna kalau
  /// backend tahu ia milik siapa.
  Future<void> daftarkanPerangkat() async {
    if (!_siap) await mulai();
    if (!_siap) return;

    try {
      // Android 13+ menuntut izin ini sebelum notifikasi boleh muncul.
      final izin = await FirebaseMessaging.instance.requestPermission();
      if (izin.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('Izin notifikasi ditolak pengguna');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await ApiService().kirimTokenPerangkat(token);

      // Token bisa diputar Firebase kapan saja — kalau tidak ikut diperbarui,
      // notifikasi berhenti sampai tanpa ada yang menyadarinya.
      FirebaseMessaging.instance.onTokenRefresh.listen((baru) {
        ApiService().kirimTokenPerangkat(baru);
      });
    } catch (e) {
      debugPrint('Gagal mendaftarkan perangkat untuk notifikasi: $e');
    }
  }

  /// Dipanggil saat logout atau hapus akun, supaya notifikasi tidak menyusul ke
  /// perangkat yang sudah berpindah tangan.
  Future<void> lupakanPerangkat() async {
    if (!_siap) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('Gagal menghapus token perangkat: $e');
    }
  }
}
