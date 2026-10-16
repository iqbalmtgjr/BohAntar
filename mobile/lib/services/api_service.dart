import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/tarif.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // Set to true ketika ingin rilis menggunakan VPS produksi
  static const bool isProduction = true;
  static const String prodUrl = 'https://bohantar.indotechconsulting.com';

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
    final response = await http.post(
      Uri.parse('$baseUrl/api/auth/request-otp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone_number': phoneNumber}),
    );
    return _handleResponse(response);
  }

  // Verify OTP
  Future<Map<String, dynamic>> verifyOtp(String phoneNumber, String otp) async {
    final response = await http.post(
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
    final response = await http.post(
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
    final response = await http.post(
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
      await http.Response.fromStream(await request.send()),
    );
  }

  // Google Login
  // id_token dikirim mentah; verifikasi tanda tangan dilakukan di backend.
  Future<Map<String, dynamic>> googleLogin(String idToken, {String? phoneNumber}) async {
    final response = await http.post(
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
    final response = await http.post(
      Uri.parse('$baseUrl/api/auth/reset-password-google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'id_token': idToken, 'new_password': newPassword}),
    );
    return _handleResponse(response);
  }

  // Fetch User Profile
  Future<Map<String, dynamic>> getProfile() async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }

    final response = await http.get(
      Uri.parse('$baseUrl/api/users/profile'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  /// Ganti password dari dalam aplikasi. Password lama wajib — server menolak
  /// tanpanya, supaya sesi yang dibajak tidak bisa mengunci pemilik akun.
  Future<Map<String, dynamic>> gantiPassword(String lama, String baru) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.put(
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
      throw Exception(ok
          ? 'Respons server tidak dikenali. Coba lagi sebentar.'
          : 'Server sedang bermasalah (kode ${response.statusCode}). Coba lagi nanti.');
    }
    if (ok) {
      return data;
    }
    throw Exception(data['error'] ?? 'Terjadi kesalahan pada server');
  }

  // Wallet Top Up
  /// Menukar QR setoran jadi saldo. Nominalnya ditentukan petugas saat membuat
  /// QR, bukan dikirim dari sini — aplikasi cuma menyerahkan isi QR-nya.
  Future<Map<String, dynamic>> klaimSetoran(String token) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
    final response = await http.get(
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
    final response = await http.post(
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

  /// Awalan isi QR tagihan warung. Dipakai untuk menolak QR asing sebelum
  /// permintaan dikirim, supaya QRIS bank atau QR promo tidak jadi pesan error
  /// dari server.
  static const awalanQRTagihan = 'bohantar:tagihan:';

  /// Membaca tagihan yang baru dipindai — nominal dan nama warungnya datang
  /// dari server, tidak pernah dari isi QR, supaya QR yang diedit orang tidak
  /// bisa menampilkan angka palsu di layar konfirmasi.
  Future<Map<String, dynamic>> lihatTagihan(String isiQR) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    if (!isiQR.startsWith(awalanQRTagihan)) {
      throw Exception('QR ini bukan QR pembayaran bohAntar.');
    }
    final id = isiQR.substring(awalanQRTagihan.length);
    final response = await http.get(
      Uri.parse('$baseUrl/api/tagihan?id=${Uri.encodeQueryComponent(id)}'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  /// Membayar tagihan dari saldo. Nominalnya ditentukan warung saat membuat QR,
  /// bukan dikirim dari sini — aplikasi cuma menyerahkan isi QR-nya.
  Future<Map<String, dynamic>> bayarTagihan(String isiQR) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
      Uri.parse('$baseUrl/api/tagihan/bayar'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
      body: jsonEncode({'token': isiQR}),
    );
    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> topUp(double amount) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      await http.post(
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
      final r = await http
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final uri = Uri.parse('$baseUrl/api/tarif/estimasi').replace(queryParameters: {
      'layanan': layanan,
      'from_lat': '$dariLat',
      'from_lng': '$dariLng',
      'to_lat': '$keLat',
      'to_lng': '$keLng',
    });
    final response = await http.get(uri, headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_token',
    });
    return EstimasiTarif.dariJson(_handleResponse(response));
  }

  // Kirim posisi driver. Nomor driver diambil backend dari token, tidak dikirim
  // dari sini — supaya tidak ada yang bisa memalsukan posisi driver lain.
  Future<void> sendDriverLocation(double lat, double lng) async {
    if (_token == null) return;
    await http.post(
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
      await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
  Future<List<dynamic>> getFoodMerchants({double? lat, double? lng, String q = ''}) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final uri = Uri.parse('$baseUrl/api/food/merchants').replace(queryParameters: {
      if (lat != null && lng != null) 'lat': '$lat',
      if (lat != null && lng != null) 'lng': '$lng',
      if (q.trim().isNotEmpty) 'q': q.trim(),
    });
    final data = _handleResponse(await http.get(uri, headers: {'Authorization': 'Bearer $_token'}));
    return (data['merchants'] as List?) ?? [];
  }

  /// Menu satu warung. Endpoint ini membalas array polos, bukan {status, ...},
  /// jadi tidak lewat _handleResponse.
  Future<List<dynamic>> getFoodMenus(String merchantId) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.get(
      Uri.parse('$baseUrl/api/food/menus').replace(queryParameters: {'merchant_id': merchantId}),
      headers: {'Authorization': 'Bearer $_token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Gagal memuat menu (kode ${response.statusCode}). Coba lagi sebentar.');
    }
    final decoded = jsonDecode(response.body);
    return decoded is List ? decoded : [];
  }

  // Get Active Orders (Driver)
  Future<Map<String, dynamic>> getActiveOrders() async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.get(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
      Uri.parse('$baseUrl/api/orders/$orderId/lepas'),
      headers: {'Authorization': 'Bearer $_token'},
    );
    return _handleResponse(response);
  }

  /// Mengunggah satu foto dan mengembalikan path /uploads/... miliknya.
  Future<String> uploadFoto(String path) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/upload'))
      ..headers['Authorization'] = 'Bearer $_token'
      ..files.add(await http.MultipartFile.fromPath('file', path));
    final data = _handleResponse(await http.Response.fromStream(await request.send()));
    return data['url'] as String;
  }

  // Monitor Order Status (Rider & Driver)
  /// Mengirim penilaian penumpang untuk driver. Hanya diterima setelah
  /// perjalanan selesai, dan satu pesanan tetap satu suara.
  Future<Map<String, dynamic>> rateOrder(String orderId, int stars, String review) async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.get(
      Uri.parse('$baseUrl/api/orders/$orderId/status'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      },
    );
    return _handleResponse(response);
  }

  // Get Orders History
  Future<Map<String, dynamic>> getOrders() async {
    if (_token == null) {
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.get(
      Uri.parse('$baseUrl/api/orders'),
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
      throw Exception('Otorisasi diperlukan. Silakan login kembali.');
    }
    final response = await http.post(
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
