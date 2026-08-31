import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Bahan peta yang dipakai layar penumpang dan layar driver.
///
/// Petanya digambar dari ubin OpenStreetMap, bukan Google Maps SDK: gratis,
/// tanpa kunci API di dalam APK, dan tanpa akun berbayar. Bedanya yang perlu
/// diketahui — di kota kecil seperti Sintang ubin OSM jauh lebih sepi label
/// daripada Google: jalannya lengkap, nama tokonya tidak.
///
/// Aturan pemakaiannya dua, dan keduanya dipenuhi di sini: sebutkan sumbernya
/// ([sumberPeta]) dan perkenalkan aplikasinya lewat `userAgentPackageName`,
/// supaya pengelola ubin bisa menghubungi kalau ada yang menyalahgunakan.
///
/// ponytail: menembak server ubin OSM langsung, batasnya cuma "pemakaian
/// wajar". Kalau pengguna bertambah banyak atau ubinnya mulai lambat, daftar
/// MapTiler atau Stadia — keduanya gratis tanpa kartu kredit, dan yang berubah
/// hanya `urlTemplate` di bawah.
TileLayer get ubinOSM => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.bohantar.mobile',
      maxNativeZoom: 19,
    );

/// Keterangan sumber peta. Wajib tampil menurut aturan pemakaian ubin OSM,
/// jadi jangan dibuang untuk merapikan tampilan.
Widget get sumberPeta => const SimpleAttributionWidget(
      source: Text('OpenStreetMap'),
      alignment: Alignment.bottomLeft,
    );

/// Penanda berbentuk pin.
///
/// `Alignment.bottomCenter` membuat ujung bawah pin yang menunjuk koordinatnya,
/// bukan tengah gambarnya — tanpa itu penanda meleset sekitar dua puluh piksel
/// ke bawah, yang di zoom rapat terlihat salah jalan.
///
/// [judul] muncul saat penandanya ditekan lama, menggantikan gelembung info
/// bawaan Google Maps.
Marker penandaPeta({
  required LatLng titik,
  required Color warna,
  required String judul,
}) =>
    Marker(
      point: titik,
      width: 44,
      height: 44,
      alignment: Alignment.bottomCenter,
      child: Tooltip(
        message: judul,
        child: Icon(Icons.location_pin, size: 44, color: warna),
      ),
    );
