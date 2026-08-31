import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/screens/chat_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/tarif.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/peta.dart';

class OrderRideScreen extends StatefulWidget {
  final String initialService;
  final String? initialDestination;
  final String riderName;
  final String riderPhone;

  const OrderRideScreen({
    super.key,
    required this.initialService,
    this.initialDestination,
    required this.riderName,
    required this.riderPhone,
  });

  @override
  State<OrderRideScreen> createState() => _OrderRideScreenState();
}

class _OrderRideScreenState extends State<OrderRideScreen> with TickerProviderStateMixin {
  final _pickupController = TextEditingController(text: "Lokasi saya di Sintang");
  final _destinationController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  late String _selectedService;
  // Tunai jadi bawaan: saldo pengguna baru nol dan top up belum tersedia, jadi
  // memilih PayAntar duluan berarti pesanan pertama siapa pun pasti ditolak.
  String _paymentMethod = "Tunai"; // "PayAntar" or "Tunai"
  double _fare = 0.0;
  
  int _inputStep = 0; // 0 = address picker, 1 = item details (BohAntar/BohSend), 2 = estimate
  
  // Package shipping details state
  String _packageType = "Dokumen";
  int _packageQuantity = 1;
  String _packageWeight = "1 kg";
  final _packageNotesController = TextEditingController();
  bool _insuranceActive = false;
  bool _specialHandlingActive = false;
  
  // Interactive rating state
  int _ratingStars = 5;
  final _reviewController = TextEditingController();
  
  // Map Controller and LatLng coordinates
  final MapController _mapController = MapController();
  // Menggeser peta sebelum ia sempat tergambar sekali melempar galat, dan
  // pengambilan GPS memang sering selesai lebih dulu.
  bool _petaSiap = false;
  LatLng _currentLatLng = const LatLng(-0.0784, 111.4933); // Default: kota Sintang
  // Titik Sintang di atas cuma isian peta sebelum GPS terbaca — kota tempat
  // layanan ini berjalan, bukan Pontianak yang 400 km jauhnya. _gpsTerbaca tetap
  // ada karena isian ini bukan lokasi siapa pun: tanpa penanda itu, penumpang
  // yang GPS-nya gagal memesan dari titik ini dan ongkosnya dihitung dari sini.
  bool _gpsTerbaca = false;
  LatLng? _destinationLatLng;
  LatLng? _driverLatLng;

  // Autocomplete and Places suggestions
  List<PlaceSuggestion> _suggestions = [];
  bool _loadingSuggestions = false;
  Timer? _debounceTimer;
  // Rute adalah panggilan ke server OSRM umum, dan _calculateFareFromDistance()
  // dipanggil dari delapan tempat — tiap ketukan di peta memicu satu. Ditahan
  // sampai titiknya berhenti berpindah.
  Timer? _ruteDebounce;

  // Routing points
  List<LatLng> _routePoints = [];

  // Order States
  String? _orderId;
  String _orderStatus = "input"; // "input", "searching", "accepted", "completed"
  String _driverName = "";
  String _driverPhone = "";
  
  Timer? _statusTimer;
  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _selectedService = widget.initialService;
    if (widget.initialDestination != null) {
      _destinationController.text = widget.initialDestination!;
      // Tujuan yang dibawa dari layar lain cuma teks, belum punya koordinat.
      // Cari sarannya supaya penumpang tinggal memilih, bukan ditebakkan.
      _searchPlaces(widget.initialDestination!);
    }

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _destinationController.dispose();
    _packageNotesController.dispose();
    _reviewController.dispose();
    _statusTimer?.cancel();
    _radarController.dispose();
    _debounceTimer?.cancel();
    _ruteDebounce?.cancel();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.gps_off, color: AppTheme.errorColor),
                SizedBox(width: 8),
                Text("GPS Belum Aktif"),
              ],
            ),
            content: const Text(
              "Layanan lokasi/GPS Anda belum aktif. Aktifkan GPS untuk mendeteksi lokasi penjemputan Anda secara otomatis."
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Batal"),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Geolocator.openLocationSettings();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  minimumSize: const Size(100, 40),
                ),
                child: const Text("Aktifkan GPS"),
              ),
            ],
          );
        },
      );
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Izin akses lokasi ditolak"),
            backgroundColor: AppTheme.errorColor,
          ),
        );
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text("Izin Lokasi Ditolak Permanen"),
            content: const Text(
              "Izin lokasi diblokir secara permanen oleh pengaturan sistem. Buka pengaturan aplikasi untuk memberikan izin secara manual."
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Batal"),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Geolocator.openAppSettings();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  minimumSize: const Size(100, 40),
                ),
                child: const Text("Buka Pengaturan"),
              ),
            ],
          );
        },
      );
      return;
    }

    // When we reach here, permissions are granted and we can fetch coordinates
    setState(() {
      _pickupController.text = "Mengambil koordinat Anda...";
    });

    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      
      setState(() {
        _currentLatLng = LatLng(position.latitude, position.longitude);
        _gpsTerbaca = true;
      });
      _pindahPeta(_currentLatLng, 15.0);

      // Reverse geocode to get human-readable address
      await _reverseGeocode(_currentLatLng, true);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Lokasi berhasil didapatkan: ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}"),
          backgroundColor: Colors.teal,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      setState(() {
        _pickupController.text = "Sintang, Kalimantan Barat";
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Gagal mengambil lokasi GPS: $e. Menggunakan lokasi default."),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  // Ongkos hanya boleh dihitung dari koordinat sungguhan.
  //
  // Versi lama punya jalur cadangan yang menaksir ongkos dari JUMLAH HURUF yang
  // diketik, lalu mengarang titik tujuan dari panjang teks yang sama. Pesanan
  // tetap terkirim — ke tempat yang tidak ada, dengan harga yang tidak berhubungan
  // dengan jarak mana pun. Sekarang tidak ada tujuan berarti tidak ada harga.
  void _calculateFare() {
    if (_destinationLatLng == null) {
      if (_destinationController.text.trim().isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Pilih tujuan dari daftar saran atau tekan titiknya di peta untuk melihat ongkos.")),
        );
      }
      return;
    }
    _calculateFareFromDistance();
  }

  void _onDestinationChanged(String query) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (query.trim().length > 2) {
        _searchPlaces(query);
      } else {
        setState(() {
          _suggestions = [];
        });
      }
    });
  }

  Future<void> _searchPlaces(String query) async {
    setState(() {
      _loadingSuggestions = true;
    });

    // Places Autocomplete lewat backend. Nominatim dulu tidak mengenal apa pun
    // di Sintang: rumah sakit, masjid, terminal, dan alun-alunnya sama-sama nol
    // hasil, jadi kolom tujuan praktis tidak bisa dipakai di sini.
    //
    // Saran hanya membawa place_id, belum koordinat; koordinatnya diambil sekali
    // saat satu tempat dipilih, supaya tidak menagih detail untuk semua saran
    // yang cuma dilewati mata.
    try {
      final hasil = await MapsService().cariTempat(query, dekat: _currentLatLng);
      if (!mounted) return;
      setState(() {
        _suggestions = hasil;
        _loadingSuggestions = false;
      });
    } catch (e) {
      debugPrint("Suggestions fetch error: $e");
      if (!mounted) return;
      setState(() {
        _loadingSuggestions = false;
      });
    }
  }

  // Jarak dan rincian ongkos untuk tujuan yang sedang dipilih. Rumusnya ada di
  // lib/tarif.dart supaya bisa diuji terhadap angka yang sama dengan server.
  ({double km, double base, double perKm, double total}) _rincianTarif() {
    final tujuan = _destinationLatLng;
    final km = tujuan == null
        ? 0.0
        : Geolocator.distanceBetween(
              _currentLatLng.latitude,
              _currentLatLng.longitude,
              tujuan.latitude,
              tujuan.longitude,
            ) /
            1000.0;
    final tarif = Tarif.untuk(_selectedService);
    return (km: km, base: tarif.base, perKm: tarif.perKM, total: tarif.hitung(km));
  }

  void _calculateFareFromDistance() {
    if (_destinationLatLng == null) return;
    setState(() {
      _fare = _rincianTarif().total;
    });
    // Tarif dihitung langsung (gratis, hitungan lokal); rutenya ditahan.
    _ruteDebounce?.cancel();
    _ruteDebounce = Timer(const Duration(milliseconds: 500), _fetchRoute);
  }

  Future<void> _pilihTempat(PlaceSuggestion saran) async {
    setState(() {
      _destinationController.text = saran.name;
      _suggestions = [];
      _loadingSuggestions = true;
    });
    try {
      final detail = await MapsService().detailTempat(saran.placeId);
      if (!mounted) return;
      if (detail == null) {
        setState(() => _loadingSuggestions = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Tempat ini tidak punya koordinat. Pilih yang lain atau tekan titiknya di peta.")),
        );
        return;
      }
      setState(() {
        _destinationLatLng = detail.posisi;
        _destinationController.text = detail.name.isEmpty ? saran.name : detail.name;
        _loadingSuggestions = false;
      });
      _calculateFareFromDistance();
      _fitMapBounds();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingSuggestions = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
      );
    }
  }

  void _pindahPeta(LatLng titik, double zoom) {
    if (_petaSiap) _mapController.move(titik, zoom);
  }

  // Penanda di peta. Penanda flutter_map tidak bisa digeser sendiri seperti
  // `draggable` milik Google, jadi pemindahannya dilakukan lewat peta: ketuk
  // untuk memindahkan tujuan, tekan lama untuk memindahkan titik jemput.
  // Keduanya diurus di MapOptions, dan hasilnya lebih sedikit kode daripada
  // menggeser pin.
  List<Marker> _penandaPeta() {
    final tujuan = _destinationLatLng;
    final driver = _driverLatLng;

    return [
      penandaPeta(titik: _currentLatLng, warna: Colors.green, judul: 'Titik jemput'),
      if (tujuan != null)
        penandaPeta(titik: tujuan, warna: Colors.red, judul: 'Tujuan'),
      // Penanda driver tetap tampil sampai penumpang diantar, bukan hilang
      // begitu status berpindah dari "accepted" ke "picked_up".
      if (driver != null && (_orderStatus == "accepted" || _orderStatus == "picked_up"))
        penandaPeta(
          titik: driver,
          warna: AppTheme.primaryBlue,
          judul: _driverName.isEmpty ? 'Driver' : _driverName,
        ),
    ];
  }

  // Memuat kotak batasnya langsung, jadi zoom tidak ditebak dengan angka tetap
  // 13 yang dulu memotong tujuan jauh di luar layar.
  void _fitMapBounds() {
    final tujuan = _destinationLatLng;
    if (tujuan == null || !_petaSiap) return;

    // LatLngBounds flutter_map merapikan sendiri sudut mana yang barat daya dan
    // mana yang timur laut, jadi tidak perlu lagi min/max manual.
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(_currentLatLng, tujuan),
      padding: const EdgeInsets.all(60),
      // Tanpa batas ini, tujuan yang diketuk tepat di atas titik jemput membuat
      // kotak batasnya nol dan zoom-nya dihitung tak terhingga.
      maxZoom: 17,
    ));
  }

  Future<void> _fetchRoute() async {
    final tujuan = _destinationLatLng;
    if (tujuan == null) {
      setState(() => _routePoints = []);
      return;
    }
    try {
      final hasil = await MapsService().rute(_currentLatLng, tujuan);
      if (!mounted) return;
      if (hasil != null && hasil.titik.isNotEmpty) {
        setState(() => _routePoints = hasil.titik);
        return;
      }
    } catch (e) {
      debugPrint("Routing error: $e");
    }
    if (!mounted) return;
    // Garis lurus sebagai jalan terakhir supaya peta tidak kosong. Ini jelas
    // bukan rute sungguhan, tapi lebih jujur daripada tidak menggambar apa pun
    // saat layanan rute sedang tidak bisa dihubungi.
    setState(() => _routePoints = [_currentLatLng, tujuan]);
  }

  Future<void> _reverseGeocode(LatLng position, bool isPickup) async {
    try {
      final alamat = await MapsService().alamatDariTitik(position);
      if (!mounted || alamat == null) return;
      setState(() {
        if (isPickup) {
          _pickupController.text = alamat;
        } else {
          _destinationController.text = alamat;
        }
      });
      _calculateFareFromDistance();
    } catch (e) {
      debugPrint("Reverse geocoding error: $e");
    }
  }

  Future<void> _bookRide() async {
    if (_pickupController.text.isEmpty || _destinationController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Lokasi penjemputan dan tujuan tidak boleh kosong.")),
      );
      return;
    }
    if (!_gpsTerbaca) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Lokasi jemput belum pasti. Aktifkan GPS, atau tekan lama tempat Anda di peta.")),
      );
      return;
    }
    // Server menolak order tanpa koordinat tujuan, jadi jangan sampai terkirim.
    final tujuan = _destinationLatLng;
    if (tujuan == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pilih tujuan dari daftar saran atau tekan titiknya di peta.")),
      );
      return;
    }
    if (_fare <= 0) {
      _calculateFare();
      return;
    }

    setState(() {
      _orderStatus = "searching";
    });
    _radarController.repeat();

    try {
      final response = await ApiService().createOrder(
        pickup: _pickupController.text,
        dropoff: _destinationController.text,
        service: _selectedService,
        paymentMethod: _paymentMethod == "PayAntar" ? "wallet" : "cash",
        pickupLat: _currentLatLng.latitude,
        pickupLng: _currentLatLng.longitude,
        dropoffLat: tujuan.latitude,
        dropoffLng: tujuan.longitude,
        packageType: _selectedService == "BohAntar" || _selectedService == "BohSend" ? _packageType : null,
        packageQuantity: _selectedService == "BohAntar" || _selectedService == "BohSend" ? _packageQuantity : null,
        packageWeight: _selectedService == "BohAntar" || _selectedService == "BohSend" ? _packageWeight : null,
        packageNotes: _selectedService == "BohAntar" || _selectedService == "BohSend" ? _packageNotesController.text : null,
        insurance: _selectedService == "BohAntar" || _selectedService == "BohSend" ? _insuranceActive : null,
        specialHandling: _selectedService == "BohAntar" || _selectedService == "BohSend" ? _specialHandlingActive : null,
      );

      if (response['status'] == 'success' && response['order'] != null) {
        final order = response['order'];
        setState(() {
          _orderId = order['id'];
          // Ongkos server yang berlaku, bukan taksiran lokal tadi.
          _fare = (order['fare'] as num?)?.toDouble() ?? _fare;
        });

        // Start polling order status
        _startPollingStatus();
      } else {
        throw Exception("Gagal membuat pesanan: Data order kosong dari server.");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _orderStatus = "input";
      });
      _radarController.stop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  void _startPollingStatus() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_orderId == null) return;

      try {
        final response = await ApiService().getOrderStatus(_orderId!);
        if (response['status'] == 'success' && response['order'] != null) {
          final order = response['order'];
          final status = order['status'];
          final driver = order['driver_name'] ?? '';
          final driverPhone = order['driver_phone'] ?? '';

          if (!mounted) return;

          // Posisi driver sungguhan, dikirim aplikasi driver dan diteruskan
          // backend di sini. Sebelumnya driver ditaruh 0,008° dari penumpang
          // (sekitar 900 m) lalu dianimasikan mendekat, sehingga penanda di peta
          // tidak ada hubungannya dengan keberadaan driver yang sebenarnya.
          final lokasi = order == null ? null : response['driver_location'];
          if (lokasi != null) {
            final lat = (lokasi['lat'] as num?)?.toDouble();
            final lng = (lokasi['lng'] as num?)?.toDouble();
            if (lat != null && lng != null) {
              setState(() => _driverLatLng = LatLng(lat, lng));
            }
          }

          if (status == 'accepted' && _orderStatus != 'accepted') {
            setState(() {
              _orderStatus = 'accepted';
              _driverName = driver;
              _driverPhone = driverPhone;
            });
            _radarController.stop();
          } else if (status == 'picked_up' && _orderStatus != 'picked_up') {
            setState(() => _orderStatus = 'picked_up');
          } else if (status == 'completed') {
            timer.cancel();
            setState(() {
              _orderStatus = 'completed';
              _driverLatLng = null;
            });
          }
        }
      } catch (e) {
        debugPrint("Error polling status: $e");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_orderStatus == "completed") {
      return _buildSuccessScreen(theme, isDark);
    }

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(
          _orderStatus == "input"
              ? (_inputStep == 0
                  ? "Mau antar ke mana?"
                  : _inputStep == 1
                      ? "Detail Barang"
                      : "Estimasi Harga")
              : _orderStatus == "searching"
                  ? "Mencari Driver..."
                  : "Perjalanan Aktif",
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_orderStatus == "input") {
              if (_inputStep > 0) {
                setState(() {
                  _inputStep--;
                });
              } else {
                Navigator.pop(context, true);
              }
            } else if (_orderStatus == "searching") {
              setState(() {
                _orderStatus = "input";
                _inputStep = 0;
              });
              _statusTimer?.cancel();
              _radarController.stop();
            } else {
              Navigator.pop(context, true);
            }
          },
        ),
      ),
      body: Stack(
        children: [
          // Peta OpenStreetMap. Selama masih di langkah memilih tujuan, ketuk
          // peta memindahkan tujuan dan tekan lama memindahkan titik jemput —
          // pengganti pin geser milik Google, yang tidak ada di flutter_map.
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentLatLng,
                initialZoom: 14,
                onMapReady: () => _petaSiap = true,
                onTap: (_, titik) {
                  if (_orderStatus != "input" || _inputStep != 0) return;
                  setState(() {
                    _destinationLatLng = titik;
                    _destinationController.text = "Mengambil alamat tujuan...";
                  });
                  _calculateFareFromDistance();
                  _reverseGeocode(titik, false);
                },
                onLongPress: (_, titik) {
                  if (_orderStatus != "input" || _inputStep != 0) return;
                  setState(() {
                    _currentLatLng = titik;
                    // Menunjuk titik jemput sendiri sama sahnya dengan GPS.
                    _gpsTerbaca = true;
                    _pickupController.text = "Memperbarui lokasi...";
                  });
                  _calculateFareFromDistance();
                  _reverseGeocode(titik, true);
                },
              ),
              children: [
                ubinOSM,
                if (_routePoints.isNotEmpty)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: _routePoints,
                      color: AppTheme.primaryBlue,
                      strokeWidth: 5,
                    ),
                  ]),
                MarkerLayer(markers: _penandaPeta()),
                sumberPeta,
              ],
            ),
          ),

          // Main Interactive Panels
          SafeArea(
            child: Column(
              children: [
                if (_orderStatus == "input") ...[
                  if (_inputStep == 0) _buildDestinationPickerPanel(theme, isDark),
                  if (_inputStep == 1) _buildPackageDetailPanel(theme, isDark),
                  if (_inputStep == 2) _buildPriceEstimatePanel(theme, isDark),
                ],
                const Spacer(),
                if (_orderStatus == "searching") _buildRadarSearchPanel(theme, isDark),
                if (_orderStatus == "accepted") _buildDriverComingPanel(theme, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDestinationPickerPanel(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Column(
                  children: [
                    const Icon(Icons.circle, color: Colors.green, size: 14),
                    Container(width: 2, height: 36, color: Colors.grey.shade300),
                    const Icon(Icons.location_on, color: Colors.red, size: 16),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      // Pickup text input
                      TextFormField(
                        controller: _pickupController,
                        decoration: InputDecoration(
                          hintText: "Pilih lokasi penjemputan",
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.my_location, color: AppTheme.primaryBlue, size: 18),
                            onPressed: _getCurrentLocation,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          filled: true,
                          fillColor: isDark ? AppTheme.bgObsidianDark : Colors.grey.shade50,
                        ),
                      ),
                      const Divider(height: 16),
                      // Dropoff text input
                      TextFormField(
                        controller: _destinationController,
                        decoration: InputDecoration(
                          hintText: "Cari, atau ketuk titiknya di peta",
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          filled: true,
                          fillColor: isDark ? AppTheme.bgObsidianDark : Colors.grey.shade50,
                        ),
                        onChanged: _onDestinationChanged,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    // Swap pickup & destination
                    final tempText = _pickupController.text;
                    _pickupController.text = _destinationController.text;
                    _destinationController.text = tempText;
                    final tempLatLng = _currentLatLng;
                    _currentLatLng = _destinationLatLng ?? _currentLatLng;
                    _destinationLatLng = tempLatLng;
                    _calculateFareFromDistance(); // sudah menjadwalkan _fetchRoute
                  },
                  icon: const Icon(Icons.swap_vert, color: AppTheme.primaryBlue),
                ),
              ],
            ),
            
            // Autocomplete suggestions
            if (_loadingSuggestions)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(color: AppTheme.primaryBlue),
              ),
            if (_suggestions.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                margin: const EdgeInsets.only(top: 12),
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final place = _suggestions[index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.location_on_outlined, color: AppTheme.primaryBlue, size: 18),
                      title: Text(place.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      subtitle: Text(place.address, style: const TextStyle(fontSize: 11, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                      // Koordinat baru diambil di sini, sekali, untuk tempat yang
                      // benar-benar dipilih.
                      onTap: () => _pilihTempat(place),
                    );
                  },
                ),
              ),
              
            const SizedBox(height: 16),
            const Text(
              "Lokasi tersimpan",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            _buildSavedLocationTile("Rumah", "Jl. Merdeka No. 10, Sintang", Icons.home, Colors.orange.shade700),
            const SizedBox(height: 8),
            _buildSavedLocationTile("Kantor", "Jl. Ahmad Yani No. 20, Sintang", Icons.work, AppTheme.primaryBlue),
            const SizedBox(height: 20),
            
            ElevatedButton(
              onPressed: _destinationLatLng != null
                  ? () {
                      setState(() {
                        if (_selectedService == "BohAntar" || _selectedService == "BohSend") {
                          _inputStep = 1;
                        } else {
                          _inputStep = 2;
                        }
                      });
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text("Lanjutkan"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedLocationTile(String type, String address, IconData icon, Color iconColor) {
    return InkWell(
      onTap: () {
        setState(() {
          _destinationController.text = address;
          _destinationLatLng = type == "Rumah"
              ? const LatLng(-0.0700, 111.4980)
              : const LatLng(-0.0650, 111.5050);
          _currentLatLng = const LatLng(-0.0784, 111.4933);
        });
        _calculateFareFromDistance();
        _fitMapBounds();
      },
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: iconColor.withOpacity(0.12), shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Text(address, style: const TextStyle(color: Colors.grey, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPackageDetailPanel(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Detail Barang", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              TextButton(
                onPressed: () => setState(() => _inputStep = 0),
                child: const Text("Kembali", style: TextStyle(color: AppTheme.primaryBlue)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          const Text("Jenis barang", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          DropdownButtonFormField<String>(
            value: _packageType,
            items: ["Dokumen", "Makanan", "Pakaian", "Elektronik", "Lainnya"]
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
            onChanged: (val) => setState(() => _packageType = val ?? _packageType),
            decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Jumlah", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    Row(
                      children: [
                        IconButton(
                          onPressed: _packageQuantity > 1 ? () => setState(() => _packageQuantity--) : null,
                          icon: const Icon(Icons.remove_circle_outline, color: AppTheme.primaryBlue),
                        ),
                        Text(_packageQuantity.toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                        IconButton(
                          onPressed: () => setState(() => _packageQuantity++),
                          icon: const Icon(Icons.add_circle_outline, color: AppTheme.primaryBlue),
                        ),
                      ],
                    )
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Berat (estimasi)", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    DropdownButtonFormField<String>(
                      value: _packageWeight,
                      items: ["1 kg", "2 kg", "3 kg", "5 kg", "10 kg"]
                          .map((w) => DropdownMenuItem(value: w, child: Text(w)))
                          .toList(),
                      onChanged: (val) => setState(() => _packageWeight = val ?? _packageWeight),
                      decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          const Text("Catatan untuk driver", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          TextFormField(
            controller: _packageNotesController,
            decoration: const InputDecoration(
              hintText: "Contoh: Hubungi saya sebelum pickup",
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(height: 16),

          const Text("Layanan tambahan", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Harga dilepas dari label: server tidak menagih tambahan ini.
              const Text("Asuransi barang", style: TextStyle(fontSize: 12)),
              Switch(
                value: _insuranceActive,
                onChanged: (val) => setState(() => _insuranceActive = val),
                activeColor: AppTheme.primaryBlue,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Penanganan khusus", style: TextStyle(fontSize: 12)),
              Switch(
                value: _specialHandlingActive,
                onChanged: (val) => setState(() => _specialHandlingActive = val),
                activeColor: AppTheme.primaryBlue,
              ),
            ],
          ),
          const SizedBox(height: 16),

          ElevatedButton(
            onPressed: () {
              setState(() {
                _inputStep = 2;
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text("Lanjutkan"),
          ),
        ],
      ),
    );
  }

  Widget _buildPriceEstimatePanel(ThemeData theme, bool isDark) {
    // Rincian di bawah harus menjumlah tepat ke angka yang ditagih server.
    //
    // Versi lama justru membalik arahnya: ia menebak jarak dari _fare memakai
    // tarif dasar yang bahkan berbeda dari rumus sebenarnya (10.000/5.000, bukan
    // 16.000/8.000), jatuh ke "4,2 km" kalau rutenya kosong, menambahkan biaya
    // layanan dan asuransi yang tidak pernah ditagih server, lalu menimpa _fare
    // dari dalam build(). Yang dilihat penumpang tidak pernah sama dengan yang
    // dibayarnya.
    final tarif = _rincianTarif();
    final distanceKm = tarif.km;
    final distanceCost = tarif.km * tarif.perKm;

    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Estimasi Harga", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_selectedService == "BohAntar" || _selectedService == "BohSend") {
                      _inputStep = 1;
                    } else {
                      _inputStep = 0;
                    }
                  });
                },
                child: const Text("Kembali", style: TextStyle(color: AppTheme.primaryBlue)),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Ringkasan Pesanan Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.bgObsidianDark : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                _buildSummaryLine(Icons.circle, Colors.green, "Jemput di", _pickupController.text),
                const SizedBox(height: 8),
                _buildSummaryLine(Icons.location_on, Colors.red, "Tujuan", _destinationController.text),
                const Divider(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Text("Jarak: ${distanceKm.toStringAsFixed(1)} km", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    Text("Waktu: ${(distanceKm * 3).toStringAsFixed(0)} menit", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                )
              ],
            ),
          ),
          const SizedBox(height: 16),

          const Text("Rincian Biaya", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 8),
          _buildFareRow("Tarif dasar", tarif.base),
          _buildFareRow("Jarak (${distanceKm.toStringAsFixed(1)} km)", distanceCost),
          // Asuransi dan penanganan khusus tidak muncul di sini karena server
          // tidak menagihnya: keduanya dikirim sebagai permintaan ke driver,
          // bukan sebagai biaya. Kalau memang mau ditagih, tempatnya di tabel
          // tarif bersama base dan per_km, bukan dihitung diam-diam di aplikasi.
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Total", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              Text(
                "Rp ${tarif.total.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}",
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: AppTheme.primaryBlue),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Payment Selector Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _paymentMethod = _paymentMethod == "PayAntar" ? "Tunai" : "PayAntar";
                  });
                },
                child: Row(
                  children: [
                    Icon(
                      _paymentMethod == "PayAntar" ? Icons.wallet : Icons.payments,
                      color: AppTheme.primaryBlue,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(_paymentMethod, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.grey),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          ElevatedButton(
            onPressed: _bookRide,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text("Pesan Sekarang"),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryLine(IconData icon, Color color, String label, String text) {
    return Row(
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: TextStyle(fontSize: 12, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
              children: [
                TextSpan(text: "$label: ", style: const TextStyle(color: Colors.grey)),
                TextSpan(text: text, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFareRow(String label, double cost) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(
            "Rp ${cost.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}",
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildRadarSearchPanel(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
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
                    width: 90 * (1 + _radarController.value),
                    height: 90 * (1 + _radarController.value),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.primaryBlue.withOpacity(0.15 * (1 - _radarController.value)),
                    ),
                  );
                },
              ),
              Container(
                width: 70,
                height: 70,
                decoration: const BoxDecoration(
                  color: AppTheme.primaryBlue,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Text(
                  'b',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'Inter',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            "Mencari driver...",
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            "Kami sedang mencari driver terdekat untuk kamu\nEstimasi waktu: 2 - 5 menit",
            style: TextStyle(color: Colors.grey, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const Divider(height: 32),
          OutlinedButton(
            onPressed: () {
              setState(() {
                _orderStatus = "input";
                _inputStep = 0;
              });
              _statusTimer?.cancel();
            },
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.primaryBlue),
              foregroundColor: AppTheme.primaryBlue,
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text("Batalkan Pesanan"),
          )
        ],
      ),
    );
  }

  Widget _buildDriverComingPanel(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Driver details header
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppTheme.primaryBlue.withOpacity(0.12),
                child: Text(
                  _driverName.isNotEmpty ? _driverName[0].toUpperCase() : 'D',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryBlue),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _driverName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const Text(
                      "Honda Beat • KB 1234 XX",
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.star, color: Colors.amber, size: 14),
                    SizedBox(width: 4),
                    Text("4.9 (120)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber)),
                  ],
                ),
              )
            ],
          ),
          const SizedBox(height: 16),
          
          // Action Buttons: Chat & Telepon
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    if (_orderId != null) {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(
                        orderID: _orderId!,
                        myPhone: widget.riderPhone,
                        myName: widget.riderName,
                        myRole: 'rider',
                        otherName: _driverName.isNotEmpty ? _driverName : "Driver",
                        otherPhone: _driverPhone,
                      )));
                    }
                  },
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: const Text("Chat"),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.primaryBlue),
                    foregroundColor: AppTheme.primaryBlue,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    if (_driverPhone.isNotEmpty) {
                      final uri = Uri.parse('tel:$_driverPhone');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri);
                      }
                    }
                  },
                  icon: const Icon(Icons.phone_outlined, size: 18),
                  label: const Text("Telepon"),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.green),
                    foregroundColor: Colors.green,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          
          // ETA Status
          Row(
            children: [
              const Icon(Icons.directions_run, color: AppTheme.primaryBlue, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text("Driver menuju lokasi kamu • ETA 4 menit", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              )
            ],
          ),
          const SizedBox(height: 16),
          
          // Timeline status tracker
          const Text("Status Pesanan", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 12),
          // Tahapan mengikuti status pesanan yang sesungguhnya. Sebelumnya
          // keempatnya berjam mati "10:20"–"10:23" dan tiga di antaranya selalu
          // tercentang, berapa pun lama penumpang menunggu.
          _buildTimelineItem("Pesanan dibuat", true),
          _buildTimelineItem("Driver ditemukan", _orderStatus == "accepted" || _orderStatus == "picked_up" || _orderStatus == "completed"),
          _buildTimelineItem("Penumpang dijemput", _orderStatus == "picked_up" || _orderStatus == "completed"),
          _buildTimelineItem("Perjalanan selesai", _orderStatus == "completed"),
          // Tombol "Simulasi Selesai (Dev)" dihapus: hanya driver yang boleh
          // menutup pesanan, dan backend memang menolak permintaan dari
          // penumpang — jadi tombol itu tidak pernah bisa berhasil.
        ],
      ),
    );
  }

  // Parameter waktu dilepas: backend hanya menyimpan updated_at terakhir, bukan
  // jam tiap tahapan, jadi tidak ada angka jujur yang bisa ditampilkan di sini.
  Widget _buildTimelineItem(String text, bool isDone) {
    return Row(
      children: [
        Icon(
          isDone ? Icons.check_circle : Icons.radio_button_unchecked,
          color: isDone ? Colors.green : Colors.grey,
          size: 16,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isDone ? FontWeight.bold : FontWeight.normal,
              color: isDone ? Colors.black : Colors.grey,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessScreen(ThemeData theme, bool isDark) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
          child: Column(
            children: [
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  color: Colors.green,
                  size: 80,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                "Pesanan kamu telah selesai",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                "Terima kasih telah menggunakan bohAntar",
                style: TextStyle(color: Colors.grey, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              
              // Total payment box
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.cardObsidianDark : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Total Pembayaran", style: TextStyle(color: Colors.grey, fontSize: 13)),
                    Text(
                      "Rp ${_fare.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')}",
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: AppTheme.primaryBlue),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              
              // Interactive 5 star ratings
              const Text(
                "Beri penilaian untuk driver",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  final starIndex = index + 1;
                  return IconButton(
                    onPressed: () {
                      setState(() {
                        _ratingStars = starIndex;
                      });
                    },
                    icon: Icon(
                      starIndex <= _ratingStars ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                      size: 36,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 20),
              
              // Review input
              TextFormField(
                controller: _reviewController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: "Tulis ulasan (opsional)",
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 32),
              
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context, true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text("Kirim Penilaian"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
