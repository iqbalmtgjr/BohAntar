import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/tarif.dart';

/// Satu klien untuk semua permintaan ke server. http.get dan kawan-kawan
/// membuat klien baru tiap panggilan, jadi tiap permintaan — termasuk polling
/// tiap beberapa detik — berjabat tangan TCP + TLS dari nol. Klien bersama
/// memakai ulang sambungannya (keep-alive). Dibuat lewat http.Client() supaya
/// http.runWithClient di tes tetap bisa menggantinya.
final http.Client klienHttp = http.Client();

/// Pesan galat yang layak dibaca pemakai, untuk SEMUA galat yang tampil di
/// layar. Galat jaringan dan galat bawaan Dart (ClientException,
/// SocketException, TimeoutException, FormatException, …) memuat alamat
/// server, port, dan kode OS — yang perlu dibaca pemakai cuma apa yang terjadi
/// dan apa yang bisa dilakukan. Pesan yang kita tulis sendiri (termasuk dari
/// server) dilempar sebagai Exception('…') dan diteruskan apa adanya.
String pesanGalat(Object e) {
  final teks = e.toString();
  if (teks.startsWith('Exception: ')) return teks.substring('Exception: '.length);
  if (e is TimeoutException) return 'Server tidak menjawab. Cek koneksi internet, lalu coba lagi.';
  if (e is SocketException || e is http.ClientException || e is HandshakeException || e is HttpException) {
    return 'Tidak bisa terhubung ke server. Cek koneksi internet, lalu coba lagi.';
  }
  debugPrint('Galat tanpa pesan ramah: $e'); // yang begini perlu pesan sendiri
  return 'Terjadi kesalahan. Coba lagi sebentar, ya.';
}

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // Set to true ketika ingin rilis menggunakan VPS produksi
  static const bool isProduction = true;
  static const String prodUrl = 'https://bohantar.indotechconsulting.com';

  /// WhatsApp CS/admin bohAntar (format wa.me, tanpa "+"). Dipakai "Lupa
  /// password?" di layar masuk dan menu Bantuan.
  static const String waCS = '628996979079';

  // Determine base URL dynamically based on platform (Emulator vs. Device/Simulator)
  String get baseUrl {
    if (isProduction) {
      return prodUrl;
    }
    if (kIsWeb) {
      return 'http://localhost:8080';
    }
    // Android emulator uses 10.0.2.2, iOS simulator uses localhost
    return Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://localhost:8080';
  }

  // Token disimpan di Keystore (Android) / Keychain (iOS), bukan SharedPreferences
  // yang bisa dibaca aplikasi lain di perangkat yang di-root. Nilai bawaan v11
  // sudah AES-GCM dengan pembungkusan kunci RSA, jadi tidak perlu opsi tambahan.
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'token';

  String? _token;
  String? get token => _token;

  Future<void> setToken(String token) async {
    _token = token;
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<void> clearToken() async {
    _token = null;
    await _storage.delete(key: _tokenKey);
  }

  Future<bool> tryAutoLogin() async {
    final savedToken = await _storage.read(key: _tokenKey);
    if (savedToken != null && savedToken.isNotEmpty) {
      _token = savedToken;
      return true;
    }

    // Migrasi sekali jalan: token lama dari SharedPreferences dipindahkan ke
    // penyimpanan terenkripsi supaya pengguna lama tidak terlempar ke login.
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_tokenKey);
    if (legacy != null && legacy.isNotEmpty) {
      await prefs.remove(_tokenKey);
      await setToken(legacy);
      return true;
    }
    return false;
  }

  // ponytail: requestOtp/verifyOtp menganggur — rutenya dimatikan di backend
  // selama belum ada gateway SMS/WA. Dibiarkan supaya tinggal dipanggil lagi.
  // Request OTP
  Future<Map<String, dynamic>> requestOtp(String phoneNumber) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/auth/request-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber}),
    );
    return _handleResponse(response);
  }

  // Verify OTP
  Future<Map<String, dynamic>> verifyOtp(String phoneNumber, String otp) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/auth/verify-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber, 'otp': otp}),
    );
    
    final data = _handleResponse(response);
    if (data['status'] == 'success' && data['token'] != null) {
      await setToken(data['token']);
    }
    return data;
  }

  // Login dengan email + password
  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    final data = _handleResponse(response);
    if (data['status'] == 'success' && data['token'] != null) {
      await setToken(data['token']);
    }
    return data;
  }

  // Register User
  Future<Map<String, dynamic>> register({
    required String phoneNumber,
    required String name,
    required String email,
    required String role,
    required String password,
  }) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'phone_number': phoneNumber,
        'name': name,
        'email': email,
        'role': role,
        'password': password,
      }),
    );

    final data = _handleResponse(response);
    if (data['status'] == 'success' && data['token'] != null) {
      await setToken(data['token']);
    }
    return data;
  }

  // Pengajuan jadi driver. Dokumen ikut di permintaan yang sama karena calon
  // driver belum punya token — /api/upload tidak bisa dipakai olehnya. Tidak
  // mengembalikan token: akun baru bisa masuk setelah admin menyetujui.
  Future<Map<String, dynamic>> daftarDriver({
    required String phoneNumber,
    required String name,
    required String email,
    required String password,
    required String ktpNumber,
    required String simNumber,
    required String vehiclePlate,
    required String vehicleType,
    required String vehicleModel,
    required String ktpPhotoPath,
    required String simPhotoPath,
    required String stnkPhotoPath,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/admin/drivers/register'),
    );
    request.fields.addAll({
      'phone_number': phoneNumber,
      'name': name,
      'email': email,
      'password': password,
      'ktp_number': ktpNumber,
      'sim_number': simNumber,
      'vehicle_plate': vehiclePlate,
      'vehicle_type': vehicleType,
      'vehicle_model': vehicleModel,
    });
    request.files.addAll([
      await http.MultipartFile.fromPath('ktp_photo', ktpPhotoPath),
      await http.MultipartFile.fromPath('sim_photo', simPhotoPath),
      await http.MultipartFile.fromPath('stnk_photo', stnkPhotoPath),
    ]);
    return _handleResponse(
      await http.Response.fromStream(await klienHttp.send(request)),
    );
  }

  // Google Login
  // id_token dikirim mentah; verifikasi tanda tangan dilakukan di backend.
  Future<Map<String, dynamic>> googleLogin(String idToken, {String? phoneNumber}) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/auth/google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'id_token': idToken,
        if (phoneNumber != null) 'phone_number': phoneNumber,
      }),
    );
    final data = _handleResponse(response);
    if (data['status'] == 'success' && data['token'] != null) {
      await setToken(data['token']);
    }
    return data;
  }

  // Lupa password: token Google membuktikan pemilik email akun, lalu password
  // baru disimpan. Sesi tidak dibuat — pengguna masuk seperti biasa sesudahnya.
  Future<Map<String, dynamic>> resetPasswordGoogle(String idToken, String newPassword) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/auth/reset-password-google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'id_token': idToken, 'new_password': newPassword}),
    );
    return _handleResponse(response);
  }

  // Fetch User Profile
  Future<Map<String, dynamic>> getProfile() async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }

    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/users/profile'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    final data = _handleResponse(response);
    // Server mengirim token baru kalau peran akun sudah berubah sejak token ini
    // terbit — misalnya penumpang yang baru disetujui jadi driver.
    if (data['token'] is String) await setToken(data['token']);
    return data;
  }

  /// Ganti password dari dalam aplikasi. Password lama wajib — server menolak
  /// tanpanya, supaya sesi yang dibajak tidak bisa mengunci pemilik akun.
  Future<Map<String, dynamic>> gantiPassword(String lama, String baru) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.put(
      Uri.parse('$baseUrl/api/users/profile'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'current_password': lama, 'new_password': baru}),
    );
    return _handleResponse(response);
  }

  // Helper response parser. Server bisa membalas HTML (nginx 502, portal WiFi),
  // jadi jsonDecode tidak boleh dipanggil tanpa pengaman.
  Map<String, dynamic> _handleResponse(http.Response response) {
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {
      data = null;
    }

    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (data == null) {
      // Bukan JSON: biasanya halaman galat nginx/Cloudflare saat backend mati.
      throw Exception(ok ? 'Balasan server tidak terbaca. Coba lagi sebentar.' : 'Server sedang gangguan. Coba lagi beberapa saat lagi.');
    }
    if (ok) {
      return data;
    }
    if (response.statusCode == 401 && data['error'] == 'Token otorisasi diperlukan') throw Exception(_sesiHabis);
    throw Exception(data['error'] ?? 'Terjadi kesalahan di server. Coba lagi sebentar.');
  }

  static const _sesiHabis = 'Sesi sudah berakhir. Silakan keluar, lalu masuk lagi.';

  // Wallet Top Up
  /// Menukar QR setoran jadi saldo. Nominalnya ditentukan petugas saat membuat
  /// QR, bukan dikirim dari sini — aplikasi cuma menyerahkan isi QR-nya.
  Future<Map<String, dynamic>> klaimSetoran(String token) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/driver/setoran/klaim'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'token': token}),
    );
    return _handleResponse(response);
  }

  /// Riwayat pencairan saldo milik akun ini, terbaru dulu.
  Future<List<dynamic>> getPencairan() async {
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/pencairan'),
      headers: {'Authorization': 'Bearer $_token'},
    );
    return (_handleResponse(response)['pencairan'] as List?) ?? [];
  }

  /// Mengajukan pencairan. Saldo dipotong server saat itu juga; admin
  /// mentransfer lalu menandai selesai, atau menolak dan saldonya kembali.
  Future<Map<String, dynamic>> ajukanPencairan({
    required int amount,
    required String bank,
    required String nomorRekening,
    required String namaPemilik,
  }) async {
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/pencairan'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({
        'amount': amount,
        'bank': bank,
        'nomor_rekening': nomorRekening,
        'nama_pemilik': namaPemilik,
      }),
    );
    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> topUp(double amount) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/users/topup'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'amount': amount}),
    );
    return _handleResponse(response);
  }

  // Daftarkan token perangkat untuk notifikasi. Gagal diam-diam: notifikasi
  // yang tidak terdaftar tidak boleh menghalangi pemakaian aplikasi.
  Future<void> kirimTokenPerangkat(String token) async {
    if (_token == null) return;
    try {
      await klienHttp.post(
        Uri.parse('$baseUrl/api/users/fcm-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
        body: jsonEncode({'token': token}),
      );
    } catch (_) {}
  }

  /// Benar kalau server sudah tidak melayani versi aplikasi ini (MIN_APP_BUILD
  /// di backend). Galat apa pun dianggap "tidak perlu": HP yang sedang tanpa
  /// sinyal tidak boleh terkunci di layar perbarui.
  Future<bool> perluPerbarui() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final r = await klienHttp
          .get(Uri.parse('$baseUrl/api/aplikasi/versi'))
          .timeout(const Duration(seconds: 5));
      final minimal = (jsonDecode(r.body)['minimal_build'] as num?)?.toInt() ?? 0;
      return (int.tryParse(info.buildNumber) ?? 0) < minimal;
    } catch (_) {
      return false;
    }
  }

  // URL publik kebijakan privasi sekaligus cara hapus akun tanpa aplikasi.
  // Google Play menuntut keduanya bisa dibuka dari luar aplikasi. Lewat /api/
  // karena nginx produksi hanya meneruskan /api/* ke backend — /privasi
  // berakhir di halaman 404 dashboard.
  String get privacyUrl => '$baseUrl/api/privasi';

  // Hapus akun sendiri. Backend menolak kalau masih ada pesanan berjalan atau
  // komisi yang belum disetor, jadi pesan errornya diteruskan apa adanya.
  Future<Map<String, dynamic>> deleteAccount() async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/users/delete'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    final data = _handleResponse(response);
    await clearToken();
    return data;
  }

  /// Taksiran ongkos untuk satu rute. Yang dikirim koordinat, bukan jarak:
  /// server memakai jarak versinya sendiri untuk menagih, jadi taksirannya pun
  /// harus lahir dari jarak yang sama.
  Future<EstimasiTarif> estimasiTarif({
    required String layanan,
    required double dariLat,
    required double dariLng,
    required double keLat,
    required double keLng,
  }) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final uri = Uri.parse('$baseUrl/api/tarif/estimasi').replace(queryParameters: {
      'layanan': layanan,
      'from_lat': '$dariLat',
      'from_lng': '$dariLng',
      'to_lat': '$keLat',
      'to_lng': '$keLng',
    });
    final response = await klienHttp.get(uri, headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_token',
    });
    return EstimasiTarif.dariJson(_handleResponse(response));
  }

  // Kirim posisi driver. Nomor driver diambil backend dari token, tidak dikirim
  // dari sini — supaya tidak ada yang bisa memalsukan posisi driver lain.
  Future<void> sendDriverLocation(double lat, double lng) async {
    if (_token == null) return;
    await klienHttp.post(
      Uri.parse('$baseUrl/api/driver/location'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'lat': lat, 'lng': lng}),
    );
  }

  /// Memberi tahu server bahwa driver berhenti bekerja. Tanpa ini ia masih
  /// dibangunkan notifikasi orderan sampai sepuluh menit setelah offline.
  Future<void> setDriverOffline() async {
    if (_token == null) return;
    try {
      await klienHttp.post(
        Uri.parse('$baseUrl/api/driver/offline'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
      );
    } catch (e) {
      // Gagal memberi tahu server bukan alasan menahan tombolnya: penanda waktu
      // posisi akan basi sendiri dalam sepuluh menit.
      debugPrint('Gagal mengirim status offline: $e');
    }
  }

  // Create Order (Rider)
  // Ongkos tidak dikirim: server menghitungnya sendiri dari koordinat dan
  // membalikkannya di `order['fare']`. Angka yang ditampilkan sebelum memesan
  // hanya taksiran lokal dengan rumus yang sama.
  Future<Map<String, dynamic>> createOrder({
    required String pickup,
    required String dropoff,
    required String service,
    required String paymentMethod, // "cash" atau "wallet"
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
    String? packageType,
    int? packageQuantity,
    String? packageWeight,
    String? packageNotes,
    bool? insurance,
    bool? specialHandling,
    String? receiverName,
    String? receiverPhone,
    // BohFood: warung dan isi keranjang ({menu_id, qty}); harga dihitung server.
    String? merchantId,
    List<Map<String, dynamic>>? items,
  }) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({
        'pickup': pickup,
        'dropoff': dropoff,
        'pickup_lat': pickupLat,
        'pickup_lng': pickupLng,
        'dropoff_lat': dropoffLat,
        'dropoff_lng': dropoffLng,
        'payment_method': paymentMethod,
        'service': service,
        'package_type': packageType,
        'package_quantity': packageQuantity,
        'package_weight': packageWeight,
        'package_notes': packageNotes,
        'insurance': insurance,
        'special_handling': specialHandling,
        'receiver_name': receiverName,
        'receiver_phone': receiverPhone,
        'merchant_id': merchantId,
        'items': items,
      }),
    );
    return _handleResponse(response);
  }

  /// Daftar warung BohFood. Dengan posisi, server mengurutkan yang terdekat dan
  /// mengisi jarak_km serta ongkir. Dengan q, server mencocokkan nama warung,
  /// alamat, dan nama menu.
  Future<List<dynamic>> getFoodMerchants({double? lat, double? lng, String q = ''}) async =>
      ((await getEtalaseFood(lat: lat, lng: lng, q: q, menu: false))['merchants'] as List?) ?? [];

  /// Layar depan BohFood, satu halaman: 'menus' (dengan porsi terjual 30 hari
  /// terakhir, sudah diurutkan server), 'merchants' pemilik menu-menu itu, dan
  /// 'ada_lagi'. Dengan q, server mencari nama menu, kategori, dan nama warung.
  Future<Map<String, dynamic>> getEtalaseFood({double? lat, double? lng, String q = '', bool menu = true, int page = 1, int limit = 10}) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final uri = Uri.parse('$baseUrl/api/food/merchants').replace(queryParameters: {
      if (lat != null && lng != null) 'lat': '$lat',
      if (lat != null && lng != null) 'lng': '$lng',
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (menu) ...{'menu': '1', 'page': '$page', 'limit': '$limit'},
    });
    return _handleResponse(await klienHttp.get(uri, headers: {'Authorization': 'Bearer $_token'}));
  }

  /// Banner beranda yang aktif, diatur dari dashboard. Tanpa token: isinya
  /// memang untuk dipajang. Kosong berarti tidak ada yang aktif.
  Future<List<Map<String, dynamic>>> getBanner() async {
    final data = _handleResponse(await klienHttp.get(Uri.parse('$baseUrl/api/banner')));
    return [for (final b in (data['banner'] as List?) ?? const []) Map<String, dynamic>.from(b as Map)];
  }

  /// Menu satu warung. Endpoint ini membalas array polos, bukan {status, ...},
  /// jadi tidak lewat _handleResponse.
  Future<List<dynamic>> getFoodMenus(String merchantId) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/food/menus').replace(queryParameters: {'merchant_id': merchantId}),
      headers: {'Authorization': 'Bearer $_token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Menu warung gagal dimuat. Coba lagi sebentar.');
    }
    final decoded = jsonDecode(response.body);
    return decoded is List ? decoded : [];
  }

  // Get Active Orders (Driver)
  Future<Map<String, dynamic>> getActiveOrders() async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/orders/active'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  // Accept Order (Driver)
  Future<Map<String, dynamic>> acceptOrder(String orderId) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders/$orderId/accept'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  // Pickup Order (Driver - Ambil Barang). Foto bukti opsional — hasil uploadFoto.
  Future<Map<String, dynamic>> pickupOrder(String orderId, {String? photoUrl}) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders/$orderId/pickup'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'photo_url': photoUrl}),
    );
    return _handleResponse(response);
  }

  // Complete Order (Driver). Foto serah-terima dan nama penerima opsional.
  Future<Map<String, dynamic>> completeOrder(String orderId, {String? photoUrl, String? receivedBy}) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders/$orderId/complete'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'photo_url': photoUrl, 'received_by': receivedBy}),
    );
    return _handleResponse(response);
  }

  /// Melepas pesanan yang sudah diterima supaya kembali ke papan orderan.
  ///
  /// Hanya sebelum penumpang atau barangnya diambil. Tanpa ini, pesanan yang
  /// tidak bisa dilanjutkan menahan komisi driver tanpa batas waktu dan bisa
  /// membuatnya tidak bisa menerima pesanan lain sama sekali.
  Future<Map<String, dynamic>> lepasPesanan(String orderId) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders/$orderId/lepas'),
      headers: {'Authorization': 'Bearer $_token'},
    );
    return _handleResponse(response);
  }

  /// Mengunggah satu foto dan mengembalikan path /uploads/... miliknya.
  Future<String> uploadFoto(String path) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/upload'))
      ..headers['Authorization'] = 'Bearer $_token'
      ..files.add(await http.MultipartFile.fromPath('file', path));
    final data = _handleResponse(await http.Response.fromStream(await klienHttp.send(request)));
    return data['url'] as String;
  }

  // Monitor Order Status (Rider & Driver)
  /// Mengirim penilaian penumpang untuk driver. Hanya diterima setelah
  /// perjalanan selesai, dan satu pesanan tetap satu suara.
  Future<Map<String, dynamic>> rateOrder(String orderId, int stars, String review) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders/$orderId/rate'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'stars': stars, 'review': review}),
    );
    return _handleResponse(response);
  }

  /// Membatalkan pesanan. Backend hanya mengizinkannya sebelum penumpang naik.
  Future<Map<String, dynamic>> cancelOrder(String orderId) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/orders/$orderId/cancel'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> getOrderStatus(String orderId) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/orders/$orderId/status'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  /// Tab Chat: satu baris per pesanan, pesan terakhir, dan jumlah belum dibaca.
  Future<Map<String, dynamic>> getDaftarChat() async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/chats'),
      headers: {'Authorization': 'Bearer $_token'},
    );
    return _handleResponse(response);
  }

  /// BohRental: kendaraan aktif semua mitra.
  Future<List<Map<String, dynamic>>> getKatalogRental() async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final data = _handleResponse(await klienHttp.get(
      Uri.parse('$baseUrl/api/rental/katalog'),
      headers: {'Authorization': 'Bearer $_token'},
    ));
    return [for (final k in (data['kendaraan'] as List?) ?? const []) Map<String, dynamic>.from(k as Map)];
  }

  /// BohRental: sewa milik pemakai ini. Endpoint-nya dipakai juga oleh mitra
  /// dan membalas array polos, jadi tidak lewat _handleResponse.
  Future<List<Map<String, dynamic>>> getSewaSaya(String phone) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/rental/bookings'),
      headers: {'Authorization': 'Bearer $_token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Daftar sewa gagal dimuat. Coba lagi sebentar.');
    }
    final decoded = jsonDecode(response.body);
    final daftar = [
      for (final b in decoded is List ? decoded : const [])
        if ((b as Map)['customer_phone'] == phone) Map<String, dynamic>.from(b),
    ];
    daftar.sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
    return daftar;
  }

  /// [mulai] dan [selesai] berformat "YYYY-MM-DD HH:mm:ss"; harga dihitung server.
  Future<Map<String, dynamic>> ajukanSewa(String carId, String mulai, String selesai) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    return _handleResponse(await klienHttp.post(
      Uri.parse('$baseUrl/api/rental/bookings'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_token'},
      body: jsonEncode({'car_id': carId, 'start_time': mulai, 'end_time': selesai}),
    ));
  }

  Future<Map<String, dynamic>> batalkanSewa(String bookingId) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    return _handleResponse(await klienHttp.put(
      Uri.parse('$baseUrl/api/rental/bookings/$bookingId'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_token'},
      body: jsonEncode({'status': 'cancelled'}),
    ));
  }

  /// Riwayat pesanan (sebagai penumpang maupun driver), terbaru dulu, satu
  /// halaman. 'ada_lagi' menandai masih ada halaman berikutnya.
  Future<Map<String, dynamic>> getOrders({int page = 1, int limit = 20}) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.get(
      Uri.parse('$baseUrl/api/orders').replace(queryParameters: {'page': '$page', 'limit': '$limit'}),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  // Save Favorite Location / Address
  Future<Map<String, dynamic>> saveAddress(String type, String address) async {
    if (_token == null) {
      throw Exception(_sesiHabis);
    }
    final response = await klienHttp.post(
      Uri.parse('$baseUrl/api/users/addresses'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({
        'type': type,
        'address': address,
      }),
    );
    return _handleResponse(response);
  }
}
