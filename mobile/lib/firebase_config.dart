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
  apiKey: 'AIzaSyB3dmFGJILIsZjLvnaaOgJs3Vf2JWuH908',
  appId: '1:1086050775839:android:88425eab0ea30a0d3c762a',
  messagingSenderId: '1086050775839',
  projectId: 'boh-antar',
);

/// Benar kalau nilai di atas masih placeholder. Dipakai untuk melewati
/// inisialisasi Firebase dengan diam ketimbang melempar galat saat aplikasi
/// mulai.
bool get firebaseSudahDikonfigurasi =>
    !kFirebaseOptions.projectId.startsWith('GANTI_DENGAN');
