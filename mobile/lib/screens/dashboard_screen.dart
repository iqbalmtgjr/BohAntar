import 'dart:async';
// Path dari dart:ui dipakai beralias: latlong2 lewat flutter_map juga
// mengekspor Path (versi LatLng), dan tanpa alias namanya bentrok.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/screens/chat_screen.dart';
import 'package:mobile/screens/login_screen.dart';
import 'package:mobile/screens/order_ride_screen.dart';
import 'package:mobile/screens/pindai_setoran_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/services/notifikasi_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/peta.dart';

class DashboardScreen extends StatefulWidget {
  final String name;
  final String role; // 'rider' or 'driver'
  final String phone;

  const DashboardScreen({
    super.key,
    required this.name,
    required this.role,
    required this.phone,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with TickerProviderStateMixin {
  bool _isOnline = false;
  bool _hasIncomingOrder = false;
  
  // Dynamic User State
  double _walletBalance = 0.0;
  String _userName = "";
  String _userBadge = "Silver";
  Map<String, String> _userAddresses = {};
  Map<String, dynamic>? _riderActiveOrder;

  // Active driver states
  Timer? _driverPollTimer;
  Timer? _riderActiveOrderTimer;
  Map<String, dynamic>? _currentIncomingOrder;
  Map<String, dynamic>? _acceptedOrder;
  // Pesanan yang sudah ditolak driver ini, supaya tidak ditawarkan lagi tiap
  // tiga detik. Cukup bertahan selama sesi — pesanan yang benar-benar dilewatkan
  // semua driver akan kedaluwarsa sendiri di server.
  final Set<String> _pesananDitolak = {};

  // Driver map states
  final MapController _driverMapController = MapController();
  // Menggeser peta sebelum ia sempat tergambar sekali melempar galat, dan
  // pesanan bisa masuk sebelum layar petanya terpasang.
  bool _petaSiap = false;
  // Titik awal peta sebelum GPS terbaca. Begitu _mulaiPantauPosisi() jalan,
  // isinya selalu posisi sungguhan.
  LatLng _driverLatLng = const LatLng(-0.0784, 111.4933); // Default: kota Sintang
  StreamSubscription<Position>? _posisiSub;
  // Titik saat rute terakhir digambar, untuk menahan panggilan layanan rute.
  LatLng? _titikRuteTerakhir;
  // Dialog izin lokasi latar belakang cukup sekali per sesi; menanyakannya tiap
  // kali driver menekan online akan terasa seperti gangguan.
  bool _izinLatarSudahDitanya = false;

  void _pindahPeta(LatLng titik, double zoom) {
    if (_petaSiap) _driverMapController.move(titik, zoom);
  }

  // Jarak minimum sebelum rute digambar ulang. Knob: turunkan kalau garis
  // rutenya terasa tertinggal, naikkan kalau layanan rute mulai menolak.
  // ponytail: 2 km, bukan 500 m — pada 500 m satu perjalanan 5 km memakan ~10
  // panggilan hanya untuk memperhalus garis yang sudah benar. Rutenya sekarang
  // gratis (OSRM), tapi itu server umum yang dipakai bersama, jadi ambangnya
  // tetap. Turunkan lagi kalau driver mengeluh garisnya tertinggal.
  static const double _jarakGambarUlangRuteMeter = 2000;
  LatLng? _orderPickupLatLng;
  LatLng? _orderDropoffLatLng;
  List<LatLng> _driverRoutePoints = [];         // Driver -> Pickup (biru)
  List<LatLng> _dropoffRoutePoints = [];        // Pickup -> Dropoff (hijau)

  // Animation Controllers
  late AnimationController _radarController;
  late AnimationController _countdownController;
  
  // Timer for order countdown
  Timer? _countdownTimer;
  int _countdownSeconds = 15;
  int _currentTabIndex = 0;
  // Tab driver terpisah dari tab penumpang: keduanya hidup di state yang sama,
  // tapi satu akun hanya memakai salah satunya.
  int _driverTabIndex = 0;
  // Disimpan di state, bukan dibuat di dalam build. Peta driver memanggil
  // setState tiap 3 detik, dan Future yang dibuat di build ikut dibuat ulang
  // setiap kali — riwayat pesanan akan ditarik dua puluh kali per menit.
  Future<Map<String, dynamic>>? _pendapatanFuture;

  // Riwayat untuk tab Aktivitas. Diisi oleh polling yang memang sudah berjalan
  // tiap 4 detik untuk mencari pesanan aktif, jadi tab ini tidak menembak
  // permintaan sendiri. _riwayatSidik menyimpan sidik jari daftar terakhir
  // (id:status tiap baris) supaya setState hanya dipanggil ketika isinya benar-
  // benar berubah — tanpa itu daftarnya digambar ulang tiap 4 detik dan
  // kelihatan berkedip terus.
  List<dynamic> _riwayatPesanan = [];
  String _riwayatSidik = '';
  bool _riwayatSudahDimuat = false;

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
    if (widget.role == 'rider') {
      _startRiderActiveOrderPolling();
    }
    
    // Radar pulse animation
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    // Countdown animation for incoming order
    _countdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    );

    // Setelah kedua controller siap: pemulihan memakai keduanya.
    if (widget.role != 'rider') {
      _pulihkanPesananBerjalan();
    }
  }

  @override
  void dispose() {
    _radarController.dispose();
    _countdownController.dispose();
    _countdownTimer?.cancel();
    _driverPollTimer?.cancel();
    _riderActiveOrderTimer?.cancel();
    _posisiSub?.cancel();
    super.dispose();
  }

  /// Mengambil kembali pesanan yang sedang dijalankan saat aplikasi dibuka.
  ///
  /// Tanpa ini, HP yang mati atau aplikasi yang tertutup di tengah perjalanan
  /// membuat pesanannya lenyap dari layar driver — sementara di server statusnya
  /// tetap berjalan selamanya, karena tidak ada yang bisa menekan Selesai lagi.
  ///
  /// Tidak perlu endpoint baru: GET /api/orders sudah mengembalikan pesanan
  /// sebagai driver, tinggal disaring.
  Future<void> _pulihkanPesananBerjalan() async {
    try {
      final response = await ApiService().getOrders();
      if (response['status'] != 'success') return;

      final daftar = (response['orders'] as List?) ?? [];
      final berjalan = daftar.cast<dynamic>().where((o) =>
          o['driver_phone'] == widget.phone &&
          (o['status'] == 'accepted' || o['status'] == 'picked_up'));
      if (berjalan.isEmpty || !mounted) return;

      setState(() {
        _acceptedOrder = berjalan.first;
        // Driver yang punya perjalanan belum selesai memang sedang bekerja.
        // Tanpa ini kartu pesanannya tidak tergambar sama sekali, karena panel
        // bawah menampilkan layar "Anda Sedang Offline" lebih dulu.
        _isOnline = true;
      });
      _radarController.repeat();
      _startDriverPolling();
      _mulaiPantauPosisi();
      _setupDriverOrderRouting();
    } catch (e) {
      debugPrint('Gagal memulihkan pesanan berjalan: $e');
    }
  }

  Future<void> _fetchUserProfile() async {
    try {
      final response = await ApiService().getProfile();
      if (response['status'] == 'success') {
        final user = response['user'];
        setState(() {
          _walletBalance = (user['balance'] as num?)?.toDouble() ?? 0.0;
          _userName = user['name'] ?? '';
          _userBadge = user['badge'] ?? 'Silver';
          if (user['addresses'] != null) {
            _userAddresses = Map<String, String>.from(user['addresses']);
          }
        });
      }
    } catch (e) {
      debugPrint("Error fetching profile: $e");
      setState(() {
      });
    }
  }

  void _startRiderActiveOrderPolling() {
    _riderActiveOrderTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (mounted) {
        _fetchRiderActiveOrder();
      }
    });
  }

  Future<void> _fetchRiderActiveOrder() async {
    try {
      final response = await ApiService().getOrders();
      if (response['status'] == 'success') {
        final List ordersList = response['orders'] ?? [];
        Map<String, dynamic>? activeOrder;
        for (var o in ordersList) {
          final status = o['status'];
          if (status == 'pending' || status == 'accepted' || status == 'picked_up') {
            activeOrder = o;
            break;
          }
        }
        // Daftar yang sama persis tidak perlu digambar ulang. Sidik jarinya
        // memuat status tiap pesanan, jadi perubahan status ikut terdeteksi,
        // bukan cuma pesanan baru.
        final sidik = ordersList.map((o) => '${o['id']}:${o['status']}').join(',');
        final berubah = sidik != _riwayatSidik || activeOrder?['id'] != _riderActiveOrder?['id'];
        if (mounted && (berubah || !_riwayatSudahDimuat)) {
          setState(() {
            _riderActiveOrder = activeOrder;
            _riwayatPesanan = ordersList;
            _riwayatSidik = sidik;
            _riwayatSudahDimuat = true;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching active order for rider: $e");
    }
  }

  void _showTopUpDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Top Up PayAntar"),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: "Masukkan nominal (misal: 50000)",
              prefixText: "Rp ",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () async {
                final text = controller.text.trim();
                final amount = double.tryParse(text);
                if (amount == null || amount <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Nominal tidak valid")),
                  );
                  return;
                }
                Navigator.pop(context);
                try {
                  final res = await ApiService().topUp(amount);
                  if (res['status'] == 'success') {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Top up berhasil! Saldo baru: Rp ${res['balance']}")),
                    );
                    _fetchUserProfile();
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.toString())),
                  );
                }
              },
              child: const Text("Top Up"),
            ),
          ],
        );
      },
    );
  }

  void _toggleOnline(bool online) {
    setState(() {
      _isOnline = online;
      if (_isOnline) {
        _radarController.repeat();
        _startDriverPolling();
      } else {
        _radarController.stop();
        _stopDriverPolling();
        _hasIncomingOrder = false;
        _currentIncomingOrder = null;
        // _acceptedOrder sengaja TIDAK dihapus. Offline berarti berhenti
        // menerima orderan baru, bukan meninggalkan penumpang yang sudah
        // dijemput — dan tanpa tombol Selesai, pesanannya tersangkut selamanya.
        _countdownTimer?.cancel();
      }
    });
    // Di luar setState karena keduanya asinkron. Posisi hanya dikirim selagi
    // driver online — offline berarti berhenti dilacak, bukan sekadar berhenti
    // menerima orderan.
    if (online) {
      _mulaiPantauPosisi();
    } else {
      _hentikanPantauPosisi();
      // Server menebak siapa yang siaga dari waktu posisi terakhir, jadi berhenti
      // mengirim posisi saja tidak cukup: tanpa kabar ini, driver yang sudah
      // pulang masih dibangunkan orderan sampai sepuluh menit sesudahnya.
      ApiService().setDriverOffline();
    }
  }

  void _startDriverPolling() {
    _driverPollTimer?.cancel();
    _driverPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_isOnline) return;
      if (_acceptedOrder != null) {
        _checkAcceptedOrderStatus();
        return;
      }
      if (_hasIncomingOrder) return;

      try {
        final response = await ApiService().getActiveOrders();
        if (response['status'] == 'success') {
          final List ordersList = (response['orders'] as List? ?? [])
              .where((o) => !_pesananDitolak.contains(o['id']))
              .toList();
          if (ordersList.isNotEmpty) {
            final order = ordersList.first;
            setState(() {
              _currentIncomingOrder = order;
              _hasIncomingOrder = true;
              _countdownSeconds = 15;
              // Kartu orderan hidup di tab peta dan hitung mundurnya cuma 15
              // detik. Driver yang sedang membuka tab Pendapatan akan kehilangan
              // orderan tanpa pernah melihatnya, jadi tabnya ditarik kembali.
              _driverTabIndex = 0;
            });
            _startIncomingOrderCountdown();

            // Center map to rider's pickup location immediately
            _centerMapToIncomingOrder(order);
          }
        }
      } catch (e) {
        debugPrint("Error polling active orders: $e");
      }
    });
  }

  void _stopDriverPolling() {
    _driverPollTimer?.cancel();
    _driverPollTimer = null;
    _countdownTimer?.cancel();
  }

  void _centerMapToIncomingOrder(Map<String, dynamic> order) {
    final double pickupLat = (order['pickup_lat'] ?? 0.0) is int
        ? (order['pickup_lat'] as int).toDouble()
        : (order['pickup_lat'] ?? 0.0) as double;
    final double pickupLng = (order['pickup_lng'] ?? 0.0) is int
        ? (order['pickup_lng'] as int).toDouble()
        : (order['pickup_lng'] ?? 0.0) as double;
    final double dropoffLat = (order['dropoff_lat'] ?? 0.0) is int
        ? (order['dropoff_lat'] as int).toDouble()
        : (order['dropoff_lat'] ?? 0.0) as double;
    final double dropoffLng = (order['dropoff_lng'] ?? 0.0) is int
        ? (order['dropoff_lng'] as int).toDouble()
        : (order['dropoff_lng'] ?? 0.0) as double;

    if (pickupLat != 0.0 && pickupLng != 0.0) {
      final pickupLatLng = LatLng(pickupLat, pickupLng);
      final LatLng? dropoffLatLng = dropoffLat != 0.0 && dropoffLng != 0.0
          ? LatLng(dropoffLat, dropoffLng)
          : null;

      // Preview markers
      setState(() {
        _orderPickupLatLng = pickupLatLng;
        _orderDropoffLatLng = dropoffLatLng;
      });

      // Center map to show full route overview
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        if (dropoffLatLng != null) {
          final avgLat = (pickupLatLng.latitude + dropoffLatLng.latitude) / 2;
          final avgLng = (pickupLatLng.longitude + dropoffLatLng.longitude) / 2;
          _pindahPeta(LatLng(avgLat, avgLng), 13.5);
        } else {
          _pindahPeta(pickupLatLng, 14.5);
        }
      });

      // Draw route preview: pickup -> dropoff (green line preview)
      if (dropoffLatLng != null) {
        _fetchDropoffRoute(pickupLatLng, dropoffLatLng);
      }
    }
  }

  /// Strips the "Lokasi Saya (...)" wrapper if address was not reverse geocoded,
  /// and returns a cleaner display string for the driver panel.
  String _cleanPickupAddress(String? raw) {
    if (raw == null || raw.isEmpty) return 'Lokasi tidak diketahui';
    // If it still contains "Lokasi Saya", extract coords and format them nicely
    if (raw.startsWith('Lokasi Saya (') && raw.endsWith(')')) {
      final coords = raw.replaceFirst('Lokasi Saya (', '').replaceFirst(')', '');
      final parts = coords.split(',');
      if (parts.length == 2) {
        final lat = double.tryParse(parts[0].trim());
        final lng = double.tryParse(parts[1].trim());
        if (lat != null && lng != null) {
          return '${lat.toStringAsFixed(4)}°, ${lng.toStringAsFixed(4)}° (GPS)';
        }
      }
    }
    return raw;
  }

  void _startIncomingOrderCountdown() {
    _countdownController.reset();
    _countdownController.forward();
    
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownSeconds == 0) {
        _rejectOrder();
      } else {
        setState(() {
          _countdownSeconds--;
        });
      }
    });
  }

  Future<void> _checkAcceptedOrderStatus() async {
    if (_acceptedOrder == null) return;
    try {
      final response = await ApiService().getOrderStatus(_acceptedOrder!['id']);
      if (response['status'] == 'success') {
        final order = response['order'];
        if (order['status'] == 'completed') {
          setState(() {
            _acceptedOrder = null;
            _hasIncomingOrder = false;
            _driverRoutePoints = [];
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Perjalanan selesai! Pendapatan telah ditambahkan ke dompet Anda.'),
              backgroundColor: Colors.teal,
            ),
          );
          _fetchUserProfile();
        }
      }
    } catch (e) {
      debugPrint("Error checking order status: $e");
    }
  }

  LatLng? _parseLatLng(String? text) {
    if (text == null) return null;
    try {
      final regExp = RegExp(r'\(([^,]+),\s*([^)]+)\)');
      final match = regExp.firstMatch(text);
      if (match != null) {
        final lat = double.parse(match.group(1)!);
        final lng = double.parse(match.group(2)!);
        return LatLng(lat, lng);
      }
    } catch (e) {
      debugPrint("Coordinate parsing error: $e");
    }
    return null;
  }

  Future<void> _fetchDriverRoute(LatLng start, LatLng end) async {
    try {
      final hasil = await MapsService().rute(start, end);
      if (!mounted) return;
      if (hasil != null && hasil.titik.isNotEmpty) {
        setState(() => _driverRoutePoints = hasil.titik);
        return;
      }
    } catch (e) {
      debugPrint("Driver routing error: $e");
    }
    if (!mounted) return;
    setState(() => _driverRoutePoints = [start, end]);
  }

  void _setupDriverOrderRouting() {
    if (_acceptedOrder == null) return;

    // Use stored GPS coordinates from the order (sent by rider when booking)
    double pickupLat = (_acceptedOrder!['pickup_lat'] ?? 0.0) is int
        ? (_acceptedOrder!['pickup_lat'] as int).toDouble()
        : (_acceptedOrder!['pickup_lat'] ?? 0.0) as double;
    double pickupLng = (_acceptedOrder!['pickup_lng'] ?? 0.0) is int
        ? (_acceptedOrder!['pickup_lng'] as int).toDouble()
        : (_acceptedOrder!['pickup_lng'] ?? 0.0) as double;
    double dropoffLat = (_acceptedOrder!['dropoff_lat'] ?? 0.0) is int
        ? (_acceptedOrder!['dropoff_lat'] as int).toDouble()
        : (_acceptedOrder!['dropoff_lat'] ?? 0.0) as double;
    double dropoffLng = (_acceptedOrder!['dropoff_lng'] ?? 0.0) is int
        ? (_acceptedOrder!['dropoff_lng'] as int).toDouble()
        : (_acceptedOrder!['dropoff_lng'] ?? 0.0) as double;

    if (pickupLat != 0.0 && pickupLng != 0.0) {
      final pickupLatLng = LatLng(pickupLat, pickupLng);
      final LatLng? dropoffLatLng = dropoffLat != 0.0 && dropoffLng != 0.0
          ? LatLng(dropoffLat, dropoffLng)
          : null;

      // _driverLatLng tidak disetel di sini: isinya posisi GPS sungguhan dari
      // _mulaiPantauPosisi(). Versi lama menaruh driver 0,004° dari titik jemput
      // (sekitar 450 m) lalu menganimasikannya mendekat, jadi peta menunjukkan
      // perjalanan yang tidak pernah terjadi.
      setState(() {
        _orderPickupLatLng = pickupLatLng;
        _orderDropoffLatLng = dropoffLatLng;
        // Pesanan baru: rutenya digambar sekali tanpa menunggu 500 m pertama.
        _titikRuteTerakhir = null;
      });

      // Center map to show overview of the whole journey
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dropoffLatLng != null) {
          // Fit map to show driver, pickup and dropoff
          final avgLat = (pickupLatLng.latitude + dropoffLatLng.latitude) / 2;
          final avgLng = (pickupLatLng.longitude + dropoffLatLng.longitude) / 2;
          _pindahPeta(LatLng(avgLat, avgLng), 13.5);
        } else {
          _pindahPeta(pickupLatLng, 14.0);
        }
      });

      // Fetch segment 1: driver -> pickup (blue route)
      _fetchDriverRoute(_driverLatLng, pickupLatLng);

      // Fetch segment 2: pickup -> dropoff (green route)
      if (dropoffLatLng != null) {
        _fetchDropoffRoute(pickupLatLng, dropoffLatLng);
      }
    } else {
      // Fallback: parse from text if coordinates are missing (legacy orders)
      final pickupStr = _acceptedOrder!['pickup'] as String?;
      final parsed = _parseLatLng(pickupStr);
      if (parsed != null) {
        setState(() {
          _orderPickupLatLng = parsed;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pindahPeta(parsed, 14.0);
        });
        _fetchDriverRoute(_driverLatLng, parsed);
      }
    }
  }

  Future<void> _fetchDropoffRoute(LatLng start, LatLng end) async {
    try {
      final hasil = await MapsService().rute(start, end);
      if (!mounted) return;
      if (hasil != null && hasil.titik.isNotEmpty) {
        setState(() => _dropoffRoutePoints = hasil.titik);
        return;
      }
    } catch (e) {
      debugPrint('Dropoff routing error: $e');
    }
    if (!mounted) return;
    setState(() {
      _dropoffRoutePoints = [start, end];
    });
  }

  // Pemantauan posisi driver yang sungguhan, menggantikan animasi yang dulu
  // menggeser penanda 15% mendekat setiap 2 detik tanpa pernah membaca GPS.
  //
  // Memakai stream Geolocator, bukan timer: pembaruan datang saat driver benar-
  // benar berpindah, jadi ojek yang sedang menunggu di pangkalan tidak menguras
  // baterai maupun kuota. distanceFilter 30 m kira-kira satu blok.
  //
  // ponytail: hanya jalan selama aplikasi terbuka. Android menghentikan stream
  // ini begitu aplikasi ke latar belakang, jadi penumpang berhenti melihat
  // pergerakan kalau driver mengunci layarnya. Perbaikannya butuh izin
  // ACCESS_BACKGROUND_LOCATION plus alasan tertulis ke Google Play — kerjakan
  // bersama notifikasi push, karena keduanya menuntut layanan latar depan.
  Future<void> _mulaiPantauPosisi() async {
    if (!await _pastikanIzinLokasi()) return;

    await _posisiSub?.cancel();
    _posisiSub = Geolocator.getPositionStream(
      // AndroidSettings dengan foregroundNotificationConfig menyalakan foreground
      // service bawaan geolocator, jadi tidak perlu paket tambahan. Notifikasi
      // tetapnya bukan gangguan melainkan syarat: Android menuntut pengguna bisa
      // melihat kapan lokasinya sedang dibaca, dan itu memang seharusnya.
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 30,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'bohAntar aktif',
          notificationText: 'Berbagi posisi supaya penumpang bisa melihat Anda.',
          notificationChannelName: 'Status driver',
          enableWakeLock: true,
          setOngoing: true,
        ),
      ),
    ).listen((posisi) {
      if (!mounted) return;
      final titik = LatLng(posisi.latitude, posisi.longitude);
      setState(() => _driverLatLng = titik);

      // Penumpang membaca posisi ini lewat status pesanan. Murah: hanya menulis
      // satu baris di database sendiri.
      ApiService().sendDriverLocation(titik.latitude, titik.longitude);

      // Rute digambar ulang jauh lebih jarang daripada posisi diperbarui.
      //
      // Setiap penggambaran adalah satu panggilan ke layanan rute umum. Kalau
      // dipanggil pada tiap pembaruan posisi (tiap 30 m), satu perjalanan 5 km
      // jadi sekitar 160 panggilan. Dengan ambang 2 km, jumlahnya turun ke dua
      // atau tiga — dan garis di peta tetap terlihat mengikuti driver karena
      // penandanya sendiri bergerak tiap 30 m.
      final jemput = _orderPickupLatLng;
      if (_acceptedOrder != null && jemput != null && _perluGambarUlangRute(titik)) {
        _titikRuteTerakhir = titik;
        _fetchDriverRoute(titik, jemput);
      }
    }, onError: (e) {
      debugPrint('Pantau posisi driver gagal: $e');
    });
  }

  bool _perluGambarUlangRute(LatLng titik) {
    final terakhir = _titikRuteTerakhir;
    if (terakhir == null) return true;
    final jarak = Geolocator.distanceBetween(
      terakhir.latitude,
      terakhir.longitude,
      titik.latitude,
      titik.longitude,
    );
    return jarak >= _jarakGambarUlangRuteMeter;
  }

  Future<void> _hentikanPantauPosisi() async {
    await _posisiSub?.cancel();
    _posisiSub = null;
  }

  // Izin lokasi driver. Tanpa ini penumpang tidak bisa melihat driver bergerak,
  // jadi penolakannya dijelaskan, bukan didiamkan.
  Future<bool> _pastikanIzinLokasi() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _beriTahu('GPS mati. Nyalakan lokasi supaya penumpang bisa melihat posisi Anda.');
      return false;
    }
    var izin = await Geolocator.checkPermission();
    if (izin == LocationPermission.denied) {
      izin = await Geolocator.requestPermission();
    }
    if (izin == LocationPermission.denied || izin == LocationPermission.deniedForever) {
      _beriTahu('Izin lokasi ditolak. bohAntar tidak bisa mengirim posisi Anda ke penumpang.');
      return false;
    }

    // whileInUse berhenti begitu layar terkunci — dan driver mengunci layarnya
    // setiap kali menyetir. Izin "sepanjang waktu" diminta sekali, tapi tidak
    // dipaksakan: sejak Android 11 pilihan itu hanya muncul di halaman
    // pengaturan, bukan di dialog izin, jadi menolak pun pelacakan tetap jalan
    // selama aplikasi terbuka.
    if (izin == LocationPermission.whileInUse && !_izinLatarSudahDitanya && mounted) {
      _izinLatarSudahDitanya = true;
      final lanjut = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Izinkan lokasi sepanjang waktu'),
          content: const Text(
            'Saat ini posisi Anda hanya terkirim selama aplikasi terbuka di layar. '
            'Begitu layar terkunci, penumpang berhenti melihat Anda bergerak.\n\n'
            'Pilih "Izinkan sepanjang waktu" di pengaturan supaya posisi tetap '
            'terkirim sambil menyetir.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Nanti saja'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Buka pengaturan'),
            ),
          ],
        ),
      );
      if (lanjut == true) await Geolocator.openAppSettings();
    }
    return true;
  }

  void _beriTahu(String pesan) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(pesan), backgroundColor: AppTheme.errorColor),
    );
  }

  Future<void> _acceptOrder() async {
    _countdownTimer?.cancel();
    if (_currentIncomingOrder == null) return;
    
    try {
      final response = await ApiService().acceptOrder(_currentIncomingOrder!['id']);
      if (response['status'] == 'success') {
        setState(() {
          _acceptedOrder = response['order'];
          _hasIncomingOrder = false;
          _currentIncomingOrder = null;
        });
        _setupDriverOrderRouting();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pesanan Diterima! Menghubungkan ke Penumpang...'),
            backgroundColor: AppTheme.primaryBlue,
          ),
        );
      }
    } catch (e) {
      _rejectOrder();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  void _rejectOrder() {
    _countdownTimer?.cancel();
    setState(() {
      // Tanpa daftar ini, polling tiga detik berikutnya mengembalikan pesanan
      // yang sama dan kartunya muncul lagi dengan hitung mundur baru. Driver
      // tidak punya cara melewatkan orderan selain offline.
      final id = _currentIncomingOrder?['id'];
      if (id != null) _pesananDitolak.add(id as String);
      _hasIncomingOrder = false;
      _currentIncomingOrder = null;
    });
  }

  Future<void> _bukaKebijakanPrivasi() async {
    final url = Uri.parse(ApiService().privacyUrl);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      _beriTahu('Tidak bisa membuka halaman kebijakan privasi.');
    }
  }

  // Konfirmasi dua langkah: dialog yang menyebut akibatnya, lalu tombol merah
  // terpisah. Penghapusan tidak bisa dibatalkan, jadi satu ketukan tidak cukup.
  Future<void> _konfirmasiHapusAkun() async {
    final setuju = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hapus akun?'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Yang akan terhapus permanen:'),
            SizedBox(height: 8),
            Text('• Nama, email, dan nomor handphone\n'
                '• Alamat tersimpan\n'
                '• Isi percakapan dengan driver\n'
                '• Sisa saldo PayAntar Anda',
                style: TextStyle(fontSize: 13, height: 1.6)),
            SizedBox(height: 12),
            Text('Riwayat pesanan tetap disimpan tanpa nama Anda, karena '
                'dibutuhkan untuk pembukuan.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 12),
            Text('Tindakan ini tidak bisa dibatalkan.',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Hapus akun saya'),
          ),
        ],
      ),
    );
    if (setuju != true) return;

    try {
      await NotifikasiService().lupakanPerangkat();
      await ApiService().deleteAccount();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    } catch (e) {
      // Pesan backend sudah jelas: pesanan berjalan, atau komisi belum disetor.
      _beriTahu(e.toString().replaceAll('Exception: ', ''));
    }
  }

  void _logout() {
    // Token perangkat dilepas duluan, kalau tidak notifikasi orderan tetap
    // menyusul ke HP ini atas nama akun yang sudah keluar.
    NotifikasiService().lupakanPerangkat();
    ApiService().clearToken();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRider = widget.role == 'rider';
    
    if (isRider) {
      return _buildRiderLayout();
    } else {
      return _buildDriverLayout();
    }
  }

  // ==========================================
  // 1. RIDER LAYOUT (STUNNING HOME/SERVICES)
  // ==========================================
  Widget _buildRiderLayout() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: _buildAppBar(),
      // Badan halaman dinaikkan sampai ke belakang app bar supaya lengkungannya
      // ikut lewat di belakang logo, bukan berhenti sebagai garis lurus di
      // bawahnya. Isinya sendiri didorong turun oleh Padding di bawah.
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // DecorativeCircles sengaja tidak dipakai di sini: empat lingkaran
          // samarnya membuat latar tampak berkabut di mana-mana, sedangkan
          // rancangannya cuma minta satu lengkungan di pojok kanan atas.
          _latarLengkungKananAtas(isDark),
          // removePadding wajib di sini. Sejak badan halaman naik ke belakang app
          // bar, Scaffold tidak lagi memakan padding sistem, jadi MediaQuery di
          // dalamnya masih membawa tinggi status bar dan bilah gestur. Setiap
          // daftar bergulir bersarang (GridView menu, ListView aktivitas) diam-diam
          // menambahkan padding itu ke dirinya sendiri — itulah jarak kosong yang
          // muncul antara kartu saldo dan menu. Jaraknya dipasang sekali di sini.
          MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            child: Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 74),
              child: _buildRiderTabContent(theme, isDark),
            ),
          ),
        ],
      ),
      floatingActionButton: SizedBox(
        width: 58,
        height: 58,
        child: FloatingActionButton(
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pindai QR sedang dalam pengembangan.'),
              backgroundColor: AppTheme.primaryBlue,
            ),
          ),
          backgroundColor: AppTheme.primaryBlue,
          elevation: 4,
          shape: const CircleBorder(),
          child: const Icon(Icons.qr_code_scanner, color: Colors.white, size: 26),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _buildRiderBottomNavBar(isDark),
    );
  }

  /// Latar lengkung biru di pojok kanan atas.
  ///
  /// Dibuat dari widget, bukan PNG: ikut warna tema, tidak menambah aset, dan
  /// ukurannya tetap benar di layar mana pun. Warna tepi luar bidangnya sengaja
  /// hampir sama dengan latar halaman — perbedaan tipis itulah yang terbaca
  /// sebagai garis lengkung, ditegaskan cincin tipis di luarnya.
  Widget _latarLengkungKananAtas(bool isDark) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SizedBox(
          height: 420,
          child: CustomPaint(
            painter: _PelukisLengkungAtas(isDark: isDark),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }

  // Bar bawah memakai BottomAppBar, bukan BottomNavigationBar, karena tombol
  // bundar di tengah butuh takik (notch) dan satu slot kosong di antara menu.
  // Indeks tabnya tetap 0–3 seperti sebelumnya; slot tengah bukan tab.
  Widget _buildRiderBottomNavBar(bool isDark) {
    return BottomAppBar(
      // Tanpa latar sendiri: warna halaman yang terlihat, jadi bar bawah menyatu
      // dengan isinya. Bayangan ikut dimatikan, kalau tidak garis abu-abunya
      // tetap tercetak di atas bar yang sudah bening.
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const CircularNotchedRectangle(),
      notchMargin: 8,
      height: 66,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          _itemNavRider(0, Icons.home_outlined, Icons.home, 'Home', isDark),
          _itemNavRider(1, Icons.receipt_long_outlined, Icons.receipt_long, 'Aktivitas', isDark),
          const SizedBox(width: 64), // ruang untuk tombol bundar di tengah
          _itemNavRider(2, Icons.help_outline, Icons.help, 'Bantuan', isDark),
          _itemNavRider(3, Icons.person_outline, Icons.person, 'Akun', isDark),
        ],
      ),
    );
  }

  Widget _itemNavRider(int index, IconData icon, IconData iconAktif, String label, bool isDark) {
    final aktif = _currentTabIndex == index;
    final warna = aktif
        ? AppTheme.primaryBlue
        : (isDark ? Colors.white38 : Colors.grey.shade400);
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _currentTabIndex = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(aktif ? iconAktif : icon, color: warna, size: 23),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: warna,
                fontSize: aktif ? 11.5 : 11,
                fontWeight: aktif ? FontWeight.bold : FontWeight.w500,
              ),
            ),
            // Garis penanda tab aktif, seperti di rancangan. Slot setinggi 3 px
            // tetap dipesan walau tab tidak aktif supaya label tidak bergeser
            // naik-turun setiap pindah tab.
            const SizedBox(height: 3),
            Container(
              width: 16,
              height: 2.5,
              decoration: BoxDecoration(
                color: aktif ? AppTheme.primaryBlue : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRiderTabContent(ThemeData theme, bool isDark) {
    if (_currentTabIndex == 0) {
      return _buildRiderHomeBody(theme, isDark);
    } else if (_currentTabIndex == 1) {
      return _buildAktivitasBody(theme, isDark);
    } else if (_currentTabIndex == 2) {
      return _buildBantuanBody(theme, isDark);
    } else {
      return _buildAkunBody(theme, isDark);
    }
  }

  Widget _buildRiderHomeBody(ThemeData theme, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header lokasi
          // Lonceng pindah ke app bar, jadi baris ini tinggal lokasi saja.
          Row(
            children: [
              const Icon(Icons.location_on, color: AppTheme.primaryBlue, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Lokasi kamu', style: TextStyle(color: Colors.grey, fontSize: 11)),
                    Text(
                      _userAddresses["Rumah"] ?? "Jl. Merdeka No. 10, Sintang",
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
            ],
          ),
          const SizedBox(height: 24),

          // Greeting
          Text(
            'Halo, ${_userName.isNotEmpty ? _userName : "Pengguna"} 👋',
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, fontSize: 24),
          ),
          const SizedBox(height: 4),
          const Text(
            'Mau antar apa hari ini?',
            style: TextStyle(color: Colors.grey, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 20),

          // bohPay balance Card
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryBlue, Color(0xFF4D90FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryBlue.withOpacity(0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                )
              ],
            ),
            // ClipRRect supaya dua lingkaran hias di bawah ini terpotong rapi
            // mengikuti sudut kartunya, bukan menonjol keluar.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  Positioned(
                    top: -55,
                    right: -30,
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.10),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: -70,
                    right: 40,
                    child: Container(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.07),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.22),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.account_balance_wallet, color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'bohPay',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.white70),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Rp ${_walletBalance.toStringAsFixed(0).replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (Match m) => "${m[1]}.")}',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.role == 'rider')
                      ElevatedButton(
                        onPressed: _showTopUpDialog,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppTheme.primaryBlue,
                          padding: const EdgeInsets.only(left: 14, right: 8),
                          minimumSize: const Size(0, 38),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          elevation: 0,
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Top Up'),
                            Icon(Icons.chevron_right, size: 16),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                        const Row(
                          children: [
                            Icon(Icons.check_circle, size: 14, color: Colors.white70),
                            SizedBox(width: 6),
                            Text(
                              'Saldo kamu aman dan siap digunakan',
                              style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Services Grid
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
            padding: EdgeInsets.zero, // jangan ambil padding sistem dari MediaQuery
            children: [
              _buildServiceButton(Icons.delivery_dining, 'BohAntar', 'Antar barang & makanan', AppTheme.primaryBlue, () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => OrderRideScreen(
                      initialService: 'BohAntar',
                      riderName: _userName.isNotEmpty ? _userName : widget.name,
                      riderPhone: widget.phone,
                    ),
                  ),
                ).then((_) => _fetchUserProfile());
              }),
              _buildServiceButton(Icons.motorcycle, 'BohRide', 'Jasa transportasi', const Color(0xFF4D90FF), () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => OrderRideScreen(
                      initialService: 'BohRide',
                      riderName: _userName.isNotEmpty ? _userName : widget.name,
                      riderPhone: widget.phone,
                    ),
                  ),
                ).then((_) => _fetchUserProfile());
              }),
              _buildServiceButton(Icons.restaurant, 'BohFood', 'Pesan makanan', const Color(0xFFFF4D4D), () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Layanan BohFood sedang dalam pengembangan. Silakan coba BohRide/BohCar!'),
                    backgroundColor: AppTheme.primaryBlue,
                  ),
                );
              }),
              _buildServiceButton(Icons.mail, 'BohSend', 'Kirim paket & dokumen', const Color(0xFF00B4D8), () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => OrderRideScreen(
                      initialService: 'BohSend',
                      riderName: _userName.isNotEmpty ? _userName : widget.name,
                      riderPhone: widget.phone,
                    ),
                  ),
                ).then((_) => _fetchUserProfile());
              }),
              _buildServiceButton(Icons.shopping_bag, 'BohMart', 'Belanja kebutuhan', const Color(0xFFFFB703), () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Layanan BohMart sedang dalam pengembangan. Silakan coba BohRide/BohCar!'),
                    backgroundColor: AppTheme.primaryBlue,
                  ),
                );
              }),
              _buildServiceButton(Icons.grid_view_rounded, 'Lainnya', 'Layanan lainnya', const Color(0xFF6C757D), () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Membuka seluruh menu layanan...')),
                );
              }),
            ],
          ),
          const SizedBox(height: 24),

          // Promo Section
          _buildPromoSection(isDark),

          // Active Order banner (Floating status)
          _buildActiveOrderFloatingCard(isDark),
        ],
      ),
    );
  }

  Widget _buildPromoSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Promo untuk kamu',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: () {},
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Lihat semua', style: TextStyle(color: AppTheme.primaryBlue, fontWeight: FontWeight.w600)),
                  Icon(Icons.chevron_right, size: 16, color: AppTheme.primaryBlue),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          height: 150,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF4D90FF), AppTheme.primaryBlue],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -20,
                bottom: -20,
                child: Opacity(
                  opacity: 0.15,
                  child: const Icon(Icons.local_shipping, size: 150, color: Colors.white),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Spesial Pengguna Baru',
                        style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Diskon Ongkir\nhingga Rp10.000',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900, height: 1.2),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Untuk semua layanan bohAntar',
                      style: TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: () => setState(() => _currentTabIndex = 0),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppTheme.primaryBlue,
                        padding: const EdgeInsets.only(left: 12, right: 6),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        elevation: 0,
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Pesan Sekarang'),
                          Icon(Icons.chevron_right, size: 15),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Titik indikator. Baru satu promo, jadi hanya satu yang menyala —
              // sisanya menyusul begitu promonya datang dari server.
              Positioned(
                right: 16,
                bottom: 12,
                child: Row(
                  children: List.generate(3, (i) {
                    return Container(
                      width: i == 0 ? 14 : 6,
                      height: 6,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(i == 0 ? 0.95 : 0.4),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        )
      ],
    );
  }

  // Digambar dari _riwayatPesanan, bukan FutureBuilder yang Future-nya dibuat di
  // dalam build: polling pesanan aktif memanggil setState tiap 4 detik, dan
  // Future yang lahir di build ikut dibuat ulang setiap kali — riwayatnya ditarik
  // ulang lengkap dengan lingkaran memuat, terus-menerus. Sekarang datanya ikut
  // menumpang polling yang sama, dan tarik-ke-bawah untuk menyegarkan manual.
  Widget _buildAktivitasBody(ThemeData theme, bool isDark) {
    if (!_riwayatSudahDimuat) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_riwayatPesanan.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetchRiderActiveOrder,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 160),
            Icon(Icons.receipt_long, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Center(
              child: Text("Belum ada riwayat aktivitas pesanan", style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetchRiderActiveOrder,
      child: Builder(
        builder: (context) {
          final ordersList = _riwayatPesanan;
          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: const EdgeInsets.all(16),
            itemCount: ordersList.length,
            itemBuilder: (context, index) {
              final order = ordersList[index];
            final pickup = order['pickup'] ?? '';
            final dropoff = order['dropoff'] ?? '';
            final fare = (order['fare'] as num?)?.toDouble() ?? 0.0;
            final status = order['status'] ?? 'pending';
            final service = order['service'] ?? 'Layanan';
            
            Color statusColor = Colors.orange;
            if (status == 'completed') statusColor = Colors.green;
            if (status == 'cancelled') statusColor = Colors.red;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: CircleAvatar(
                  backgroundColor: AppTheme.primaryBlue.withOpacity(0.1),
                  child: Icon(
                    service == "BohRide" ? Icons.motorcycle : Icons.directions_car,
                    color: AppTheme.primaryBlue,
                  ),
                ),
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(service, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        status.toUpperCase(),
                        style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    Text("Jemput: $pickup", maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    Text("Tujuan: $dropoff", maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(
                      "Rp ${fare.toStringAsFixed(0).replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (Match m) => "${m[1]}.")}",
                      style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryBlue, fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
            },
          );
        },
      ),
    );
  }

  Widget _buildBantuanBody(ThemeData theme, bool isDark) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          "Pusat Bantuan",
          style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text("Punya kendala dengan perjalanan atau layanan? Cari tahu jawabannya disini.", style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 24),
        _buildFAQTile("Bagaimana cara top up saldo PayAntar?", isDark),
        _buildFAQTile("Tarif perjalanan tidak muncul di peta?", isDark),
        _buildFAQTile("Bagaimana cara membatalkan pesanan?", isDark),
        _buildFAQTile("Barang belum sampai tetapi status pesanan selesai?", isDark),
        _buildFAQTile("Ingin mendaftar sebagai pengemudi?", isDark),
      ],
    );
  }

  Widget _buildFAQTile(String question, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.blueGrey.shade900 : Colors.grey.shade100),
      ),
      child: ExpansionTile(
        title: Text(question, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        children: const [
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "Anda bisa menghubungi Customer Service kami melalui tombol bantuan langsung atau membaca petunjuk selengkapnya di situs resmi bohAntar.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildAkunBody(ThemeData theme, bool isDark) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 36,
                backgroundColor: AppTheme.primaryBlue.withOpacity(0.12),
                child: Text(
                  _userName.isNotEmpty ? _userName[0].toUpperCase() : 'U',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppTheme.primaryBlue),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _userName.isNotEmpty ? _userName : "Pengguna",
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.phone.isNotEmpty ? widget.phone : "-",
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isDark
                              ? [Colors.blueGrey.shade800, Colors.blueGrey.shade700]
                              : [Colors.grey.shade300, Colors.grey.shade100],
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade400, width: 0.5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star, color: Colors.amber.shade700, size: 12),
                          const SizedBox(width: 4),
                          Text(
                            _userBadge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
          const SizedBox(height: 24),
          
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.cardObsidianDark : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark ? Colors.blueGrey.shade800 : Colors.grey.shade200,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "bohPay",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.primaryBlue),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Rp ${_walletBalance.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}",
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 22),
                    ),
                  ],
                ),
                ElevatedButton(
                  onPressed: _showTopUpDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(90, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: const Text("Top Up", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Layar Akun ini dipakai dua peran. Yang menunjuk tab penumpang akan
          // jadi tombol mati kalau ditekan driver — nomor tabnya tidak ada di
          // sana — jadi tujuannya dipilih, bukan dibiarkan.
          _buildAkunMenuItem(Icons.receipt, "Pesanan saya", () {
            setState(() {
              if (widget.role == 'rider') {
                _currentTabIndex = 1;
              } else {
                _driverTabIndex = 1;
              }
            });
          }, isDark),
          if (widget.role == 'rider') ...[
            _buildAkunMenuItem(Icons.location_on, "Alamat tersimpan", () {
              _showSavedAddressesDialog();
            }, isDark),
            _buildAkunMenuItem(Icons.payment, "Metode pembayaran", () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Metode pembayaran PayAntar (Default).")),
              );
            }, isDark),
            _buildAkunMenuItem(Icons.card_giftcard, "Promo saya", () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Tidak ada kode promo aktif saat ini.")),
              );
            }, isDark),
            _buildAkunMenuItem(Icons.help, "Bantuan", () {
              setState(() {
                _currentTabIndex = 2;
              });
            }, isDark),
          ],
          _buildAkunMenuItem(Icons.settings, "Pengaturan", () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Pengaturan akun sedang dipersiapkan.")),
            );
          }, isDark),
          _buildAkunMenuItem(Icons.privacy_tip_outlined, "Kebijakan privasi", _bukaKebijakanPrivasi, isDark),
          const SizedBox(height: 12),

          ListTile(
            onTap: _logout,
            leading: const Icon(Icons.exit_to_app, color: Colors.red),
            title: const Text(
              "Keluar",
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.red),
          ),

          // Google Play mewajibkan aplikasi yang punya pendaftaran menyediakan
          // cara menghapus akun dari dalam aplikasi. Ditaruh paling bawah dan
          // dibedakan warnanya supaya tidak tertekan tanpa sengaja.
          ListTile(
            onTap: _konfirmasiHapusAkun,
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text(
              "Hapus akun",
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              "Menghapus data Anda secara permanen",
              style: TextStyle(fontSize: 11, color: isDark ? Colors.blueGrey.shade400 : Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.red),
          ),
        ],
      ),
    );
  }

  Widget _buildAkunMenuItem(IconData icon, String title, VoidCallback onTap, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.blueGrey.shade900 : Colors.grey.shade100,
            width: 1,
          ),
        ),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: AppTheme.primaryBlue),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        trailing: const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey),
      ),
    );
  }

  void _showSavedAddressesDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Alamat Tersimpan"),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDialogAddressTile("Rumah", _userAddresses["Rumah"] ?? "Belum diatur", () {
                      _editAddressPrompt("Rumah", setDialogState);
                    }),
                    const SizedBox(height: 12),
                    _buildDialogAddressTile("Kantor", _userAddresses["Kantor"] ?? "Belum diatur", () {
                      _editAddressPrompt("Kantor", setDialogState);
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Tutup"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDialogAddressTile(String type, String address, VoidCallback onEdit) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark ? AppTheme.cardObsidianDark : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(
            type == "Rumah" ? Icons.home : Icons.work,
            color: AppTheme.primaryBlue,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Text(
                  address,
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit, size: 16, color: AppTheme.primaryBlue),
          ),
        ],
      ),
    );
  }

  void _editAddressPrompt(String type, StateSetter setDialogState) {
    final controller = TextEditingController(text: _userAddresses[type] == "Belum diatur" ? "" : _userAddresses[type]);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Ubah Alamat $type"),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: "Masukkan detail jalan dan nomor rumah",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () async {
                final addr = controller.text.trim();
                if (addr.isNotEmpty) {
                  try {
                    final response = await ApiService().saveAddress(type, addr);
                    if (response['status'] == 'success') {
                      setState(() {
                        _userAddresses[type] = addr;
                      });
                      setDialogState(() {});
                      if (mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Alamat $type berhasil diperbarui")),
                        );
                      }
                    }
                  } catch (e) {
                    debugPrint("Error updating address: $e");
                  }
                }
              },
              child: const Text("Simpan"),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActiveOrderFloatingCard(bool isDark) {
    if (_riderActiveOrder == null) return const SizedBox.shrink();

    final driverName = _riderActiveOrder!['driver_name'] ?? 'Driver';
    final service = _riderActiveOrder!['service'] ?? 'Layanan';
    final status = _riderActiveOrder!['status'];
    
    String statusText = "Driver sedang bersiap";
    if (status == 'accepted') {
      statusText = "Driver menuju lokasi kamu";
    } else if (status == 'picked_up') {
      statusText = "Perjalanan sedang berlangsung";
    }

    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.primaryBlue.withOpacity(0.15),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryBlue.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: AppTheme.primaryBlue.withOpacity(0.12),
            child: const Icon(Icons.directions_run, color: AppTheme.primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  "$driverName • $service",
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => OrderRideScreen(
                    initialService: service,
                    riderName: _userName.isNotEmpty ? _userName : widget.name,
                    riderPhone: widget.phone,
                    // Tanpa id ini yang terbuka adalah formulir pemesanan
                    // kosong, bukan pelacakan — dan penumpang kehilangan peta,
                    // status, serta tombol chat pesanan yang sedang jalan.
                    initialOrderId: _riderActiveOrder!['id'],
                  ),
                ),
              ).then((_) => _fetchUserProfile());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              elevation: 0,
            ),
            child: const Text("Lihat"),
          ),
        ],
      ),
    );
  }

  Widget _buildServiceButton(IconData icon, String label, String subjudul, Color bgColor, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? AppTheme.cardObsidianDark : Colors.white,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE8EEF7)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: bgColor.withOpacity(0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12.5,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              // Flexible supaya subjudul dua baris di layar sempit terpotong
              // rapi, bukan meluberkan kartunya.
              Flexible(
                child: Text(
                  subjudul,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    height: 1.2,
                    color: isDark ? Colors.white38 : Colors.grey.shade500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  // ==========================================
  // 2. DRIVER LAYOUT (VIBRANT GOPARTNER UI)
  // ==========================================
  Widget _buildDriverLayout() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      // IndexedStack, bukan if/else seperti sisi penumpang: peta yang dibuang
      // tiap pindah tab akan mengunduh ubinnya lagi saat kembali — itu kuota
      // driver — dan _petaSiap tertinggal true sementara controllernya sudah
      // lepas, jadi _pindahPeta berikutnya menembak peta yang tidak ada.
      body: IndexedStack(
        index: _driverTabIndex,
        children: [
          _buildDriverPeta(theme, isDark),
          _buildPendapatanBody(theme, isDark),
          _buildAkunBody(theme, isDark),
        ],
      ),
      bottomNavigationBar: _buildDriverBottomNavBar(isDark),
    );
  }

  Widget _buildDriverBottomNavBar(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: _driverTabIndex,
        onTap: (index) {
          setState(() {
            _driverTabIndex = index;
            // Ditarik saat tabnya dibuka, bukan di initState: driver yang tidak
            // pernah membukanya tidak perlu membayar kuotanya.
            if (index == 1) _pendapatanFuture ??= ApiService().getOrders();
          });
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: AppTheme.primaryBlue,
        unselectedItemColor: Colors.grey.shade400,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 11),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: 'Beranda',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_outlined),
            activeIcon: Icon(Icons.account_balance_wallet),
            label: 'Pendapatan',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Akun',
          ),
        ],
      ),
    );
  }

  Widget _buildDriverPeta(ThemeData theme, bool isDark) {
    return Stack(
        children: [
          // Peta driver. Label "Jemput"/"Tujuan" muncul saat penandanya ditekan
          // lama, menggantikan gelembung info bawaan Google.
          Positioned.fill(
            child: FlutterMap(
              mapController: _driverMapController,
              options: MapOptions(
                initialCenter: _orderPickupLatLng ?? _driverLatLng,
                initialZoom: 14,
                onMapReady: () => _petaSiap = true,
              ),
              children: [
                ubinOSM,
                // Ruas 1: driver menuju titik jemput (biru)
                if (_driverRoutePoints.isNotEmpty)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: _driverRoutePoints,
                      color: AppTheme.primaryBlue,
                      strokeWidth: 5,
                    ),
                  ]),
                // Ruas 2: titik jemput menuju tujuan (hijau)
                if (_dropoffRoutePoints.isNotEmpty)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: _dropoffRoutePoints,
                      color: Colors.green.shade600,
                      strokeWidth: 4,
                    ),
                  ]),
                MarkerLayer(markers: [
                  if (_isOnline)
                    penandaPeta(
                      titik: _driverLatLng,
                      warna: AppTheme.primaryBlue,
                      judul: 'Posisi Anda',
                    ),
                  if (_orderPickupLatLng != null)
                    penandaPeta(
                      titik: _orderPickupLatLng!,
                      warna: Colors.green,
                      judul: 'Jemput penumpang',
                    ),
                  if (_orderDropoffLatLng != null)
                    penandaPeta(
                      titik: _orderDropoffLatLng!,
                      warna: Colors.red,
                      judul: 'Tujuan',
                    ),
                ]),
                sumberPeta,
              ],
            ),
          ),

          // Header Panel
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.only(top: 50, left: 20, right: 20, bottom: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    isDark ? const Color(0xFF0F172A).withOpacity(0.95) : Colors.white.withOpacity(0.95),
                    isDark ? const Color(0xFF0F172A).withOpacity(0.8) : Colors.white.withOpacity(0.8),
                    Colors.transparent
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Active Toggle Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: _isOnline ? AppTheme.primaryBlue : Colors.grey.shade600,
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: _isOnline
                              ? [
                                  BoxShadow(
                                    color: AppTheme.primaryBlue.withOpacity(0.4),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  )
                                ]
                              : [],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isOnline ? 'AKTIF' : 'OFFLINE',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ],
                        ),
                      ),

                      // Online Switch Button
                      Row(
                        children: [
                          const Text('Online', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          Switch.adaptive(
                            value: _isOnline,
                            activeColor: AppTheme.primaryBlue, // Blue instead of green
                            onChanged: _toggleOnline,
                          ),
                        ],
                      ),
                      
                      // Logout
                      IconButton(
                        icon: Icon(Icons.logout, color: isDark ? Colors.white70 : Colors.black87),
                        onPressed: _logout,
                      )
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Greet Row
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: AppTheme.primaryBlue.withOpacity(0.12),
                        child: Text(
                          _userName.isNotEmpty ? _userName[0].toUpperCase() : (widget.name.isNotEmpty ? widget.name[0].toUpperCase() : 'D'),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryBlue),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Halo, ${_userName.isNotEmpty ? _userName : widget.name}!',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            Text(
                              'Mitra Driver bohAntar',
                              style: TextStyle(
                                  color: isDark ? Colors.white60 : Colors.grey,
                                  fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Bottom Section (States: Offline, Online-Radar, Incoming Order)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomPanel(isDark, theme),
          ),
        ],
    );
  }



  // ==========================================
  // 3. PENDAPATAN DRIVER
  // ==========================================

  /// Setoran hari ini dan riwayat pesanan yang sudah diantar.
  ///
  /// Tidak ada endpoint pendapatan di backend, dan tidak perlu dibuat:
  /// `GET /api/orders` sudah mengembalikan pesanan sebagai driver sekaligus
  /// sebagai penumpang, jadi yang dikerjakan di sini hanya menyaring dan
  /// menjumlahkan. Yang diterima driver adalah `fare - komisi`; komisi itu
  /// bagian aplikator dan tidak pernah masuk ke tangan driver, jadi menampilkan
  /// `fare` saja akan menjanjikan lebih dari yang benar-benar didapat.
  Widget _buildPendapatanBody(ThemeData theme, bool isDark) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _pendapatanFuture = ApiService().getOrders());
        await _pendapatanFuture;
      },
      child: FutureBuilder<Map<String, dynamic>>(
        future: _pendapatanFuture,
        builder: (context, snapshot) {
          if (_pendapatanFuture == null || snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final pesan = snapshot.hasError ? "Riwayat gagal dimuat. Tarik ke bawah untuk mencoba lagi." : null;

          final semua = (snapshot.data?['orders'] as List?) ?? [];
          final selesai = semua.where((o) => o['driver_phone'] == widget.phone && o['status'] == 'completed').toList()
            ..sort((a, b) => _waktuSelesai(b).compareTo(_waktuSelesai(a)));

          final hariIni = selesai.where((o) => _hariIni(_waktuSelesai(o))).toList();
          final total = hariIni.fold<double>(0, (jumlah, o) => jumlah + _bagianDriver(o));

          return ListView(
            // Wajib, kalau tidak daftar yang pendek atau kosong tidak bisa
            // ditarik untuk menyegarkan.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.primaryBlue, Color(0xFF1D4ED8)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Pendapatan hari ini', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(
                      _rupiah(total),
                      style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${hariIni.length} pesanan selesai hari ini · sudah dipotong komisi',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Saldo minus berarti komisi pesanan tunai yang belum disetor.
              // Kartunya hanya muncul kalau memang ada utangnya.
              if (_walletBalance < 0) _kartuUtangKomisi(isDark),
              Text(
                'Riwayat pesanan',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              if (pesan != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    pesan,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              else if (selesai.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Icon(Icons.receipt_long, size: 56, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'Belum ada pesanan yang selesai',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              else
                ...selesai.map((o) => _buildRiwayatTile(o, isDark)),
            ],
          );
        },
      ),
    );
  }

  /// Kartu utang komisi + tombol pindai QR setoran.
  ///
  /// Uangnya diserahkan tunai ke petugas lebih dulu; QR yang dipindai di sini
  /// cuma bukti bahwa petugas sudah menerimanya. Karena itu tombolnya bicara
  /// "sudah setor tunai", bukan "bayar sekarang".
  Widget _kartuUtangKomisi(bool isDark) {
    final utang = -_walletBalance;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.errorColor.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet, color: AppTheme.errorColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Komisi belum disetor',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              Text(
                _rupiah(utang),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: AppTheme.errorColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Dari pesanan tunai: ongkosnya Anda terima langsung, komisinya jadi utang ke bohAntar.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _pindaiSetoran,
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('Sudah setor tunai — pindai QR petugas'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 46),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pindaiSetoran() async {
    final hasil = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const PindaiSetoranScreen()),
    );
    if (hasil == null || !mounted) return;
    // Saldo dibaca ulang dari server, bukan dihitung sendiri di sini: setoran
    // lain bisa masuk di sela-sela, dan angka yang benar hanya ada di database.
    await _fetchUserProfile();
    if (!mounted) return;
    final jumlah = (hasil['amount'] as num?)?.toDouble() ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Setoran ${_rupiah(jumlah)} diterima. Terima kasih!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Widget _buildRiwayatTile(dynamic o, bool isDark) {
    final waktu = _waktuSelesai(o);
    String dua(int n) => n.toString().padLeft(2, '0');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  o['service'] ?? 'Layanan',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              Text(
                _rupiah(_bagianDriver(o)),
                style: const TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${o['pickup'] ?? '-'} → ${o['dropoff'] ?? '-'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            '${dua(waktu.day)}/${dua(waktu.month)}/${waktu.year} · ${dua(waktu.hour)}:${dua(waktu.minute)}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Waktu selesai dipakai, bukan waktu dibuat: pesanan yang dipesan menjelang
  /// tengah malam dan selesai lewat tengah malam masuk setoran hari berikutnya,
  /// sama seperti hitungan driver sendiri.
  DateTime _waktuSelesai(dynamic o) =>
      DateTime.tryParse((o['updated_at'] ?? o['created_at'] ?? '') as String)?.toLocal() ??
      DateTime.fromMillisecondsSinceEpoch(0);

  double _bagianDriver(dynamic o) => ((o['fare'] as num?)?.toDouble() ?? 0) - ((o['komisi'] as num?)?.toDouble() ?? 0);

  bool _hariIni(DateTime t) {
    final kini = DateTime.now();
    return t.year == kini.year && t.month == kini.month && t.day == kini.day;
  }

  static String _rupiah(double nilai) =>
      'Rp ${nilai.toStringAsFixed(0).replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (m) => "${m[1]}.")}';

  Widget _buildBottomPanel(bool isDark, ThemeData theme) {
    // Perjalanan yang sedang berlangsung diperiksa lebih dulu daripada status
    // online. Driver yang mematikan tombolnya di tengah jalan tetap harus bisa
    // menekan Selesai — kalau tidak, pesanannya tidak pernah bisa ditutup.
    if (!_isOnline && _acceptedOrder == null) {
      // 1. OFFLINE PANEL
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 15,
            )
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.offline_bolt_outlined, size: 48, color: Colors.grey.shade500),
            const SizedBox(height: 12),
            const Text(
              'Anda Sedang Offline',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 6),
            const Text(
              'Aktifkan tombol online di atas untuk mulai menerima orderan pelanggan.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    }

    if (_acceptedOrder != null) {
      // 4. ACTIVE ORDER DRIVER PANEL
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 15,
            )
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryBlue.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person, color: AppTheme.primaryBlue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _acceptedOrder!['rider_name'] ?? 'Penumpang',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        _acceptedOrder!['service'] ?? 'Layanan',
                        style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                Text(
                  "Rp ${_acceptedOrder!['fare'].toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}",
                  style: const TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 18),
                )
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Column(
                  children: [
                    const Icon(Icons.radio_button_checked, color: AppTheme.primaryBlue, size: 14),
                    Container(width: 1.5, height: 16, color: Colors.grey),
                    const Icon(Icons.location_on, color: AppTheme.errorColor, size: 14),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("📍 Jemput Penumpang: ${_cleanPickupAddress(_acceptedOrder!['pickup'])}", overflow: TextOverflow.ellipsis, maxLines: 2, style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 12),
                      Text("🏁 Antar ke: ${_acceptedOrder!['dropoff']}", overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                )
              ],
            ),
            const SizedBox(height: 16),
            // Chat & Call buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(
                        orderID: _acceptedOrder!['id'] ?? '',
                        myPhone: widget.phone,
                        myName: widget.name,
                        myRole: 'driver',
                        otherName: _acceptedOrder!['rider_name'] ?? 'Penumpang',
                        otherPhone: _acceptedOrder!['rider_phone'] ?? '',
                      )));
                    },
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: const Text('Chat', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryBlue,
                      side: const BorderSide(color: AppTheme.primaryBlue),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final phone = _acceptedOrder!['rider_phone'] ?? '';
                      final uri = Uri.parse('tel:$phone');
                      if (phone.isNotEmpty && await canLaunchUrl(uri)) {
                        await launchUrl(uri);
                      } else {
                        _beriTahu('Tidak dapat melakukan panggilan');
                      }
                    },
                    icon: const Icon(Icons.phone, size: 16),
                    label: const Text('Telepon', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green,
                      side: const BorderSide(color: Colors.green),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                final orderId = _acceptedOrder!['id'];
                final status = _acceptedOrder!['status'] ?? 'accepted';
                final service = _acceptedOrder!['service'] ?? 'Layanan';
                final isPickedUp = status == 'picked_up';

                if (!isPickedUp) {
                  try {
                    final res = await ApiService().pickupOrder(orderId);
                    if (!mounted) return;
                    if (res['status'] == 'success') {
                      setState(() {
                        _acceptedOrder = res['order'];
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            service == "BohAntar" || service == "BohSend"
                                ? "Barang berhasil diambil! Mulai pengantaran."
                                : "Penumpang berhasil dijemput! Mulai perjalanan."
                          ),
                          backgroundColor: Colors.teal,
                        ),
                      );
                    }
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.toString())),
                    );
                  }
                } else {
                  try {
                    final res = await ApiService().completeOrder(orderId);
                    if (!mounted) return;
                    if (res['status'] == 'success') {
                      setState(() {
                        _acceptedOrder = null;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Perjalanan berhasil diselesaikan!"), backgroundColor: Colors.green),
                      );
                      _fetchUserProfile();
                    }
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.toString())),
                    );
                  }
                }
              },
              icon: Icon(
                (_acceptedOrder!['status'] ?? 'accepted') == 'picked_up'
                    ? Icons.check_circle_outline
                    : ((_acceptedOrder!['service'] ?? '') == 'BohAntar' || (_acceptedOrder!['service'] ?? '') == 'BohSend'
                        ? Icons.local_shipping
                        : Icons.person_pin_circle),
              ),
              label: Text(
                (_acceptedOrder!['status'] ?? 'accepted') == 'picked_up'
                    ? "SELESAIKAN PERJALANAN"
                    : ((_acceptedOrder!['service'] ?? '') == 'BohAntar' || (_acceptedOrder!['service'] ?? '') == 'BohSend'
                        ? "AMBIL BARANG"
                        : "AMBIL PENUMPANG"),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: (_acceptedOrder!['status'] ?? 'accepted') == 'picked_up' ? Colors.green.shade700 : AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            )
          ],
        ),
      );
    }

    if (_hasIncomingOrder && _currentIncomingOrder != null) {
      // 2. INCOMING ORDER BOTTOM OVERLAY
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1625) : const Color(0xFFEEF2FF), // Subtle blue Alert bg
          border: Border.all(color: AppTheme.primaryBlue, width: 2),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(28),
            topRight: Radius.circular(28),
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primaryBlue.withOpacity(0.15),
              blurRadius: 20,
              spreadRadius: 2,
            )
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.motorcycle, color: AppTheme.primaryBlue),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('PESANAN MASUK!', style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 12, letterSpacing: 1)),
                        Text('Layanan ${_currentIncomingOrder!['service']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ],
                    ),
                  ],
                ),
                // Circular Countdown Timer Widget
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        value: _countdownSeconds / 15,
                        color: AppTheme.primaryBlue,
                        backgroundColor: Colors.grey.withOpacity(0.2),
                        strokeWidth: 4,
                      ),
                    ),
                    Text(
                      '$_countdownSeconds',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    )
                  ],
                )
              ],
            ),
            const Divider(height: 32),
            
            // Fare / Price
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Tarif Bersih (PayAntar/Tunai)', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                Text(
                  "Rp ${_currentIncomingOrder!['fare'].toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}",
                  style: const TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 24),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Route Details
            Row(
              children: [
                Column(
                  children: [
                    const Icon(Icons.radio_button_checked, color: AppTheme.primaryBlue, size: 16),
                    Container(width: 2, height: 24, color: Colors.grey),
                    const Icon(Icons.location_on, color: AppTheme.errorColor, size: 16),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '📍 Lokasi Penumpang: ${_cleanPickupAddress(_currentIncomingOrder!['pickup'])}',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        '🏁 Tujuan: ${_currentIncomingOrder!['dropoff']}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _rejectOrder,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.errorColor),
                      foregroundColor: AppTheme.errorColor,
                      minimumSize: const Size(0, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('LEWATKAN', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _acceptOrder,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      minimumSize: const Size(0, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('TERIMA', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            )
          ],
        ),
      );
    }

    // 3. RADAR / LOOKING FOR ORDERS STATE
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 15,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _radarController,
                builder: (context, child) {
                  return Container(
                    width: 70 * (1 + _radarController.value),
                    height: 70 * (1 + _radarController.value),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.primaryBlue.withOpacity(0.25 * (1 - _radarController.value)),
                    ),
                  );
                },
              ),
              Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(
                  color: AppTheme.primaryBlue,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.radar, color: Colors.white, size: 28),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Mencari Orderan Pelanggan...',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 4),
          const Text(
            'Pastikan GPS Anda aktif. Berkelilinglah ke area ramai.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // Material 3 mewarnai app bar dengan surfaceTint begitu isinya tergulir di
      // bawahnya — itulah pita putih di belakang logo. Dua baris ini
      // mematikannya, jadi app bar benar-benar bening di posisi mana pun.
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // Bar ditinggikan supaya logo yang lebih besar tidak mepet ke tepi.
      toolbarHeight: 74,
      // Logonya sudah memuat tulisan "bohAntar", jadi ikon taksi dan teksnya
      // tidak perlu lagi. cacheHeight dipasang karena berkasnya 421 KB: tanpa
      // itu Flutter mendekode bitmap penuh untuk slot setinggi 46 px.
      title: Image.asset(
        'assets/images/logo.png',
        height: 46,
        cacheHeight: 138,
        semanticLabel: 'bohAntar',
      ),
      actions: [
        _tombolHeader(
          icon: Icons.notifications_none,
          isDark: isDark,
          // Titik merah hanya menyala kalau memang ada yang perlu dilihat.
          // Lencana yang menyala terus berhenti berarti setelah sehari.
          bertanda: _riderActiveOrder != null,
          onTap: () => setState(() => _currentTabIndex = 1),
        ),
        const SizedBox(width: 8),
        _tombolHeader(icon: Icons.logout, isDark: isDark, onTap: _logout),
        const SizedBox(width: 16),
      ],
    );
  }

  /// Tombol persegi membulat di kanan atas, seperti di rancangan.
  Widget _tombolHeader({
    required IconData icon,
    required bool isDark,
    required VoidCallback onTap,
    bool bertanda = false,
  }) {
    return Material(
      // Bening, bukan putih: kotaknya cuma ditandai garis tepi, jadi bentuknya
      // tetap terlihat tanpa kotak putih di belakang ikonnya.
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE8EEF7)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 24, color: isDark ? Colors.white70 : const Color(0xFF334155)),
              if (bertanda)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lengkungan biru di pojok kanan atas.
///
/// Digambar sebagai kurva bezier, bukan lingkaran: sebesar apa pun lingkarannya,
/// begitu busurnya masuk layar bentuknya terbaca sebagai bola. Rancangannya minta
/// satu bidang melengkung yang masuk dari tepi atas dan keluar di tepi kanan,
/// dan itu cuma bisa dari path sendiri.
///
/// Semua titiknya relatif terhadap lebar/tinggi kanvas, jadi lengkungannya sama
/// di layar sempit maupun tablet.
class _PelukisLengkungAtas extends CustomPainter {
  const _PelukisLengkungAtas({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final bidang = ui.Path()
      ..moveTo(w * 0.40, 0)
      ..quadraticBezierTo(w * 0.94, h * 0.06, w, h * 0.58)
      ..lineTo(w, 0)
      ..close();

    final warna = isDark
        ? [AppTheme.primaryBlue.withOpacity(0.30), AppTheme.primaryBlue.withOpacity(0.10)]
        : [const Color(0xFFC9E0FC), const Color(0xFFE9F2FE)];

    canvas.drawPath(
      bidang,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: warna,
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // Garis lengkung tipis, sejajar di luar bidangnya.
    final garis = ui.Path()
      ..moveTo(w * 0.16, 0)
      ..quadraticBezierTo(w * 0.82, h * 0.14, w, h * 0.92);

    canvas.drawPath(
      garis,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppTheme.primaryBlue.withOpacity(isDark ? 0.18 : 0.14),
    );
  }

  @override
  bool shouldRepaint(covariant _PelukisLengkungAtas lama) => lama.isDark != isDark;
}
