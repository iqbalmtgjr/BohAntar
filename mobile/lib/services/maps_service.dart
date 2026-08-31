import 'dart:convert';
import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Semua permintaan alamat dan rute lewat backend, bukan langsung ke penyedianya.
///
/// Kunci API yang ditaruh di dalam APK bisa diambil siapa saja dengan `unzip`,
/// lalu kuota berbayar dihabiskan orang lain — jadi kunci Places disimpan di VPS
/// dan dikunci ke IP-nya. Peta sendiri digambar dari ubin OpenStreetMap yang
/// tidak butuh kunci apa pun, lihat widgets/peta.dart.
///
/// Bentuk balasan sudah dinormalkan backend, jadi berkas ini tidak tahu-menahu
/// penyedia mana yang sedang dipakai — lihat backend/maps.go kalau penasaran.
class MapsService {
  static final MapsService _instance = MapsService._internal();
  factory MapsService() => _instance;
  MapsService._internal();

  String get _base => ApiService().baseUrl;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${ApiService().token}',
      };

  /// Token sesi Places. Satu token menaungi seluruh ketikan sampai penumpang
  /// memilih satu tempat — tanpa itu setiap huruf ditagih sebagai permintaan
  /// terpisah, dan mengetik "rumah sakit" jadi 11 kali biaya.
  String? _sessionToken;

  String _mulaiSesi() {
    final acak = Random();
    return _sessionToken ??=
        '${DateTime.now().microsecondsSinceEpoch}-${acak.nextInt(1 << 32)}';
  }

  /// Dipanggil setelah satu tempat dipilih, supaya ketikan berikutnya memulai
  /// sesi baru.
  void selesaikanSesi() => _sessionToken = null;

  Future<List<PlaceSuggestion>> cariTempat(String query, {LatLng? dekat}) async {
    if (query.trim().length < 3) return [];
    final q = {
      'q': query,
      'session': _mulaiSesi(),
      if (dekat != null) 'lat': '${dekat.latitude}',
      if (dekat != null) 'lng': '${dekat.longitude}',
    };
    final uri = Uri.parse('$_base/api/maps/autocomplete').replace(queryParameters: q);
    final res = await http.get(uri, headers: _headers);
    final data = _urai(res);
    final daftar = data['suggestions'] as List? ?? [];
    return daftar
        .map((e) => PlaceSuggestion(
              placeId: e['place_id'] ?? '',
              name: e['name'] ?? '',
              address: e['address'] ?? '',
            ))
        .where((s) => s.placeId.isNotEmpty)
        .toList();
  }

  /// Menukar place_id hasil pencarian jadi koordinat.
  Future<PlaceDetail?> detailTempat(String placeId) async {
    final uri = Uri.parse('$_base/api/maps/place')
        .replace(queryParameters: {'place_id': placeId, 'session': _mulaiSesi()});
    final res = await http.get(uri, headers: _headers);
    final data = _urai(res);
    selesaikanSesi();
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return PlaceDetail(
      posisi: LatLng(lat, lng),
      name: data['name'] ?? '',
      address: data['address'] ?? '',
    );
  }

  /// Alamat untuk satu titik, dipakai saat titik di peta dipindahkan.
  Future<String?> alamatDariTitik(LatLng titik) async {
    final uri = Uri.parse('$_base/api/maps/reverse').replace(queryParameters: {
      'lat': '${titik.latitude}',
      'lng': '${titik.longitude}',
    });
    final res = await http.get(uri, headers: _headers);
    final data = _urai(res);
    return data['address'] as String?;
  }

  /// Rute jalan sungguhan antara dua titik.
  Future<Rute?> rute(LatLng dari, LatLng ke) async {
    final uri = Uri.parse('$_base/api/maps/route').replace(queryParameters: {
      'from_lat': '${dari.latitude}',
      'from_lng': '${dari.longitude}',
      'to_lat': '${ke.latitude}',
      'to_lng': '${ke.longitude}',
    });
    final res = await http.get(uri, headers: _headers);
    final data = _urai(res);
    final encoded = data['polyline'] as String?;
    if (encoded == null || encoded.isEmpty) return null;
    return Rute(
      titik: decodePolyline(encoded),
      meter: (data['distance_m'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> _urai(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
        throw Exception(decoded['error'] ?? 'Layanan peta bermasalah');
      }
    } catch (e) {
      if (e is Exception) rethrow;
    }
    throw Exception('Layanan peta tidak dapat dihubungi');
  }
}

class PlaceSuggestion {
  final String placeId;
  final String name;
  final String address;
  const PlaceSuggestion({required this.placeId, required this.name, required this.address});
}

class PlaceDetail {
  final LatLng posisi;
  final String name;
  final String address;
  const PlaceDetail({required this.posisi, required this.name, required this.address});
}

class Rute {
  final List<LatLng> titik;
  final double meter;
  const Rute({required this.titik, required this.meter});
}

/// Membongkar polyline terkode jadi daftar titik. Google dan OSRM memakai
/// pengkodean yang sama persis, jadi bagian ini tidak ikut berubah waktu
/// penyedia rutenya diganti.
///
/// Backend meneruskan bentuk terkodenya apa adanya karena ukurannya sekitar
/// sepersepuluh JSON berisi daftar koordinat, dan penumpang di Sintang membayar
/// kuota data untuk setiap byte-nya. Algoritmanya baku dan pendek, jadi tidak
/// perlu menambah paket hanya untuk ini.
List<LatLng> decodePolyline(String encoded) {
  final titik = <LatLng>[];
  int indeks = 0;
  int lat = 0;
  int lng = 0;

  while (indeks < encoded.length) {
    int hasil = 0, geser = 0, b;
    do {
      b = encoded.codeUnitAt(indeks++) - 63;
      hasil |= (b & 0x1f) << geser;
      geser += 5;
    } while (b >= 0x20);
    lat += (hasil & 1) != 0 ? ~(hasil >> 1) : (hasil >> 1);

    hasil = 0;
    geser = 0;
    do {
      b = encoded.codeUnitAt(indeks++) - 63;
      hasil |= (b & 0x1f) << geser;
      geser += 5;
    } while (b >= 0x20);
    lng += (hasil & 1) != 0 ? ~(hasil >> 1) : (hasil >> 1);

    titik.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return titik;
}
