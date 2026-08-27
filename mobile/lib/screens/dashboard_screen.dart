import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/screens/chat_screen.dart';
import 'package:mobile/screens/login_screen.dart';
import 'package:mobile/screens/order_ride_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/services/notifikasi_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/decorative_background.dart';

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
  bool _loadingProfile = true;
  String _userName = "";
  String _userBadge = "Silver";
  Map<String, String> _userAddresses = {};
  Map<String, dynamic>? _riderActiveOrder;

  // Active driver states
  Timer? _driverPollTimer;
  Timer? _riderActiveOrderTimer;
  Map<String, dynamic>? _currentIncomingOrder;
  Map<String, dynamic>? _acceptedOrder;

  // Driver map states
  GoogleMapController? _driverMapController;
  // Titik awal peta sebelum GPS terbaca. Begitu _mulaiPantauPosisi() jalan,
  // isinya selalu posisi sungguhan.
  LatLng _driverLatLng = const LatLng(-0.02012, 109.33878); // Default: Pontianak
  StreamSubscription<Position>? _posisiSub;
  // Titik saat rute terakhir digambar, untuk menahan panggilan Routes API.
  LatLng? _titikRuteTerakhir;
  // Dialog izin lokasi latar belakang cukup sekali per sesi; menanyakannya tiap
  // kali driver menekan online akan terasa seperti gangguan.
  bool _izinLatarSudahDitanya = false;

  // Jarak minimum sebelum rute digambar ulang. Knob biaya: turunkan kalau garis
  // rutenya terasa tertinggal, naikkan kalau tagihan Routes API terasa.
  static const double _jarakGambarUlangRuteMeter = 500;
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
          _loadingProfile = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching profile: $e");
      setState(() {
        _loadingProfile = false;
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
        if (mounted) {
          setState(() {
            _riderActiveOrder = activeOrder;
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
        _acceptedOrder = null;
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
          final List ordersList = response['orders'] ?? [];
          if (ordersList.isNotEmpty) {
            final order = ordersList.first;
            setState(() {
              _currentIncomingOrder = order;
              _hasIncomingOrder = true;
              _countdownSeconds = 15;
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
          _driverMapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(avgLat, avgLng), 13.5));
        } else {
          _driverMapController?.animateCamera(CameraUpdate.newLatLngZoom(pickupLatLng, 14.5));
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
          _driverMapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(avgLat, avgLng), 13.5));
        } else {
          _driverMapController?.animateCamera(CameraUpdate.newLatLngZoom(pickupLatLng, 14.0));
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
          _driverMapController?.animateCamera(CameraUpdate.newLatLngZoom(parsed, 14.0));
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
      // Setiap penggambaran adalah satu panggilan berbayar ke Routes API. Kalau
      // dipanggil pada tiap pembaruan posisi (tiap 30 m), satu perjalanan 5 km
      // jadi sekitar 160 panggilan. Dengan ambang 500 m, jumlahnya turun ke
      // sekitar 10 — dan garis di peta tetap terlihat mengikuti driver karena
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
      body: Stack(
        children: [
          const DecorativeCircles(),
          _buildRiderTabContent(theme, isDark),
        ],
      ),
      bottomNavigationBar: _buildRiderBottomNavBar(isDark),
    );
  }

  Widget _buildRiderBottomNavBar(bool isDark) {
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
        currentIndex: _currentTabIndex,
        onTap: (index) {
          setState(() {
            _currentTabIndex = index;
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
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_outlined),
            activeIcon: Icon(Icons.receipt_long),
            label: 'Aktivitas',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.help_outline),
            activeIcon: Icon(Icons.help),
            label: 'Bantuan',
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
          Row(
            children: [
              const Icon(Icons.location_on, color: AppTheme.primaryBlue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Lokasi kamu', style: TextStyle(color: Colors.grey, fontSize: 11)),
                    Text(
                      _userAddresses["Rumah"] ?? "Jl. Merdeka No. 10, Pontianak",
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.notifications_none, size: 24),
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
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.cardObsidianDark : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppTheme.primaryBlue.withOpacity(isDark ? 0.15 : 0.08),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryBlue.withOpacity(isDark ? 0.12 : 0.04),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                )
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.wallet, color: AppTheme.primaryBlue, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'bohPay',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.primaryBlue),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Rp ${_walletBalance.toStringAsFixed(0).replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (Match m) => "${m[1]}.")}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                ElevatedButton(
                  onPressed: _showTopUpDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(80, 38),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    elevation: 0,
                  ),
                  child: const Text('Top Up'),
                )
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Services Grid
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 20,
            crossAxisSpacing: 16,
            childAspectRatio: 0.9,
            children: [
              _buildServiceButton(Icons.local_shipping, 'BohAntar', AppTheme.primaryBlue, Colors.white, () {
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
              _buildServiceButton(Icons.motorcycle, 'BohRide', const Color(0xFF4D90FF), Colors.white, () {
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
              _buildServiceButton(Icons.restaurant, 'BohFood', const Color(0xFFFF4D4D), Colors.white, () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Layanan BohFood sedang dalam pengembangan. Silakan coba BohRide/BohCar!'),
                    backgroundColor: AppTheme.primaryBlue,
                  ),
                );
              }),
              _buildServiceButton(Icons.drafts, 'BohSend', const Color(0xFF00B4D8), Colors.white, () {
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
              _buildServiceButton(Icons.shopping_bag, 'BohMart', const Color(0xFFFFB703), Colors.white, () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Layanan BohMart sedang dalam pengembangan. Silakan coba BohRide/BohCar!'),
                    backgroundColor: AppTheme.primaryBlue,
                  ),
                );
              }),
              _buildServiceButton(Icons.grid_view_rounded, 'Lainnya', const Color(0xFF6C757D), Colors.white, () {
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
              child: const Text('Lihat semua', style: TextStyle(color: AppTheme.primaryBlue)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          height: 120,
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
                  child: const Icon(Icons.local_shipping, size: 140, color: Colors.white),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Text(
                      'DISKON ONGKIR\nbohAntar',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Hingga Rp10.000 • s/d 30 Des 2026',
                      style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              )
            ],
          ),
        )
      ],
    );
  }

  Widget _buildAktivitasBody(ThemeData theme, bool isDark) {
    return FutureBuilder<Map<String, dynamic>>(
      future: ApiService().getOrders(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text("Error: ${snapshot.error}"));
        }
        final List ordersList = snapshot.data?['orders'] ?? [];
        if (ordersList.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.receipt_long, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text("Belum ada riwayat aktivitas pesanan", style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
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
                    const Text(
                      "0812 3456 7890",
                      style: TextStyle(color: Colors.grey, fontSize: 13),
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
          
          _buildAkunMenuItem(Icons.receipt, "Pesanan saya", () {
            setState(() {
              _currentTabIndex = 1;
            });
          }, isDark),
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

  Widget _buildServiceButton(IconData icon, String label, Color bgColor, Color iconColor, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: bgColor.withOpacity(0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPlaceTile(String title, String subtitle, IconData icon, Color iconBgColor, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardObsidianDark : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDark ? Colors.blueGrey.shade800 : Colors.grey.shade100, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 6,
              offset: const Offset(0, 2),
            )
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconBgColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconBgColor, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
          ],
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
      body: Stack(
        children: [
          // Peta driver. Penanda Google memakai ikon bawaan, bukan widget
          // Flutter, jadi label "Jemput"/"Tujuan" pindah ke gelembung info yang
          // muncul saat penandanya ditekan.
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _orderPickupLatLng ?? _driverLatLng,
                zoom: 14,
              ),
              onMapCreated: (c) => _driverMapController = c,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              polylines: {
                // Ruas 1: driver menuju titik jemput (biru)
                if (_driverRoutePoints.isNotEmpty)
                  Polyline(
                    polylineId: const PolylineId('ke-jemput'),
                    points: _driverRoutePoints,
                    color: AppTheme.primaryBlue,
                    width: 5,
                  ),
                // Ruas 2: titik jemput menuju tujuan (hijau)
                if (_dropoffRoutePoints.isNotEmpty)
                  Polyline(
                    polylineId: const PolylineId('ke-tujuan'),
                    points: _dropoffRoutePoints,
                    color: Colors.green.shade600,
                    width: 4,
                  ),
              },
              markers: {
                if (_isOnline)
                  Marker(
                    markerId: const MarkerId('driver'),
                    position: _driverLatLng,
                    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                    infoWindow: const InfoWindow(title: 'Posisi Anda'),
                  ),
                if (_orderPickupLatLng != null)
                  Marker(
                    markerId: const MarkerId('jemput'),
                    position: _orderPickupLatLng!,
                    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
                    infoWindow: const InfoWindow(title: 'Jemput penumpang'),
                  ),
                if (_orderDropoffLatLng != null)
                  Marker(
                    markerId: const MarkerId('tujuan'),
                    position: _orderDropoffLatLng!,
                    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
                    infoWindow: const InfoWindow(title: 'Tujuan'),
                  ),
              },
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
      ),
    );
  }

  Widget _buildStatBox(String value, String label, Color color) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
            color: color,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildDivider(bool isDark) {
    return Container(
      width: 1,
      height: 30,
      color: isDark ? Colors.blueGrey.shade900 : Colors.grey.shade300,
    );
  }

  Widget _buildBottomPanel(bool isDark, ThemeData theme) {
    if (!_isOnline) {
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
                      if (await canLaunchUrl(uri)) { await launchUrl(uri); }
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
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.local_taxi, color: AppTheme.primaryBlue, size: 20),
          ),
          const SizedBox(width: 8),
          const Text(
            'bohAntar',
            style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 18),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.logout, color: isDark ? Colors.white70 : Colors.black87),
          onPressed: _logout,
        )
      ],
    );
  }
}
