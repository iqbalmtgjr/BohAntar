import 'package:firebase_core/firebase_core.dart';

/// Konfigurasi Firebase untuk notifikasi push.
///
/// Sengaja ditulis eksplisit di sini, bukan lewat `google-services.json` dan
/// plugin Gradle `com.google.gms.google-services`. Alasannya praktis: plugin itu
/// **menggagalkan seluruh build** kalau berkas JSON-nya belum ada, sehingga
/// aplikasi tidak bisa dikompilasi sama sekali sebelum Firebase disiapkan.
/// Dengan cara ini aplikasi tetap bisa dibangun dan dipakai; hanya notifikasinya
/// yang absen sampai nilai di bawah diisi.
///
/// Nilai-nilai ini bukan rahasia — semuanya memang ikut terkirim ke perangkat
/// dan bisa dibaca dari APK. Yang menjaga proyek Firebase Anda adalah aturan
/// keamanan di sisi Google, bukan kerahasiaan nilai ini.
///
/// Ambil dari Firebase Console → Project settings → Your apps → Android app:
///   apiKey            = "current_key" di google-services.json
///   appId             = "mobilesdk_app_id"
///   messagingSenderId = "project_number"
///   projectId         = "project_id"
///
/// Pastikan aplikasi Android didaftarkan dengan package `com.bohantar.mobile`.
const FirebaseOptions kFirebaseOptions = FirebaseOptions(
  apiKey: 'GANTI_DENGAN_FIREBASE_API_KEY',
  appId: 'GANTI_DENGAN_FIREBASE_APP_ID',
  messagingSenderId: 'GANTI_DENGAN_MESSAGING_SENDER_ID',
  projectId: 'GANTI_DENGAN_FIREBASE_PROJECT_ID',
);

/// Benar kalau nilai di atas masih placeholder. Dipakai untuk melewati
/// inisialisasi Firebase dengan diam ketimbang melempar galat saat aplikasi
/// mulai.
bool get firebaseSudahDikonfigurasi =>
    !kFirebaseOptions.projectId.startsWith('GANTI_DENGAN');
