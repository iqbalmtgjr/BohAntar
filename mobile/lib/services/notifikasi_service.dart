import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../firebase_config.dart';
import 'api_service.dart';

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

  /// Dipasang di MaterialApp supaya pesan chat bisa muncul dari mana saja tanpa
  /// menitipkan BuildContext ke seluruh aplikasi.
  static final pesanKey = GlobalKey<ScaffoldMessengerState>();

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
      _siap = true;
    } catch (e) {
      debugPrint('Firebase gagal disiapkan, notifikasi dilewati: $e');
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
  /// ponytail: SnackBar, bukan notifikasi sistem — menampilkan notifikasi
  /// sungguhan saat aplikasi terbuka butuh paket flutter_local_notifications
  /// sendiri. Tambahkan kalau ternyata SnackBar-nya terlalu mudah terlewat.
  void _pesanSaatAplikasiTerbuka(RemoteMessage pesan) {
    if (pesan.data['tipe'] != 'chat') return;
    final isi = pesan.notification?.body ?? '';
    final pengirim = pesan.notification?.title ?? 'Pesan baru';
    if (isi.isEmpty) return;

    // ponytail: tidak melompat ke layar chatnya. ChatScreen menuntut enam data
    // peserta yang harus diambil dulu dari pesanannya; pemakainya toh sedang
    // memegang layar yang punya tombol chat.
    pesanKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$pengirim: $isi'),
        duration: const Duration(seconds: 5),
      ));
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
