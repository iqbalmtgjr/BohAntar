import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mobile/theme.dart';

/// Bahan peta yang dipakai layar penumpang dan layar driver.
///
/// Petanya Google Maps SDK for Android (17 Okt 2026, menggantikan ubin
/// OpenStreetMap): di Sintang label tokonya jauh lebih lengkap, dan
/// menampilkan peta lewat SDK seluler tidak ditagih. Kuncinya ada di
/// AndroidManifest lewat `MAPS_API_KEY` (android/key.properties), dibatasi ke
/// package + SHA-1 aplikasi. Kunci Places (cari alamat) tetap terpisah di
/// backend, lihat backend/maps.go.

/// Pin bawaan Google diberi warna lewat hue, jadi ujung bawahnya otomatis
/// menunjuk koordinatnya. [judul] muncul saat pin diketuk, dan sekaligus jadi
/// id-nya — tiap peta tidak pernah punya dua pin berjudul sama.
Marker penandaPeta({
  required LatLng titik,
  required Color warna,
  required String judul,
}) =>
    Marker(
      markerId: MarkerId(judul),
      position: titik,
      icon: BitmapDescriptor.defaultMarkerWithHue(HSVColor.fromColor(warna).hue),
      infoWindow: InfoWindow(title: judul),
    );

/// Penanda driver: motor dalam lingkaran, titiknya tepat di tengah — beda dari
/// pin jemput/tujuan supaya sekali lihat tahu mana yang bergerak.
///
/// Gambarnya disiapkan [muatIkonKendaraan]; sebelum siap jatuh ke pin biru.
Marker penandaMotor({required LatLng titik, required String judul, IconData ikon = Icons.two_wheeler}) => Marker(
      markerId: MarkerId('kendaraan:$judul'),
      position: titik,
      icon: _ikonKendaraan[ikon] ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      anchor: _ikonKendaraan.containsKey(ikon) ? const Offset(0.5, 0.5) : const Offset(0.5, 1),
      infoWindow: InfoWindow(title: judul),
      zIndexInt: 1,
    );

final _ikonKendaraan = <IconData, BitmapDescriptor>{};

/// Google Maps tidak bisa memakai widget sebagai penanda, jadi lingkaran +
/// ikon kendaraan digambar sekali ke PNG. Panggil di initState, lalu setState
/// saat selesai.
Future<void> muatIkonKendaraan() async {
  for (final ikon in const [Icons.two_wheeler, Icons.directions_car]) {
    if (_ikonKendaraan.containsKey(ikon)) continue;
    const ukuran = 40.0, rasio = 3.0;
    const pusat = Offset(ukuran / 2, ukuran / 2);
    final rekam = ui.PictureRecorder();
    final kanvas = Canvas(rekam)..scale(rasio);
    kanvas
      ..drawCircle(pusat.translate(0, 1), ukuran / 2 - 2,
          Paint()..color = Colors.black26..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2))
      ..drawCircle(pusat, ukuran / 2 - 3, Paint()..color = Colors.white)
      ..drawCircle(pusat, ukuran / 2 - 4,
          Paint()..color = AppTheme.primaryBlue..style = PaintingStyle.stroke..strokeWidth = 2);
    final teks = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(ikon.codePoint),
        style: TextStyle(fontSize: 24, fontFamily: ikon.fontFamily, package: ikon.fontPackage, color: AppTheme.primaryBlue),
      ),
    )..layout();
    teks.paint(kanvas, pusat - Offset(teks.width / 2, teks.height / 2));
    final gambar = await rekam.endRecording().toImage((ukuran * rasio).round(), (ukuran * rasio).round());
    final png = await gambar.toByteData(format: ui.ImageByteFormat.png);
    if (png != null) _ikonKendaraan[ikon] = BitmapDescriptor.bytes(png.buffer.asUint8List(), imagePixelRatio: rasio);
  }
}
