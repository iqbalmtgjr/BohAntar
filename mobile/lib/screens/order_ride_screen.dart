import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/models/food.dart' show rupiah;
import 'package:mobile/widgets/food_widgets.dart' show lebarDekode;
import 'package:mobile/screens/chat_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/status_pesanan.dart';
import 'package:mobile/tarif.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/peta.dart';

class OrderRideScreen extends StatefulWidget {
  final String initialService;
  final String? initialDestination;
  final String riderName;
  final String riderPhone;

  /// Diisi saat penumpang kembali ke pesanan yang sedang berjalan. Kalau ada,
  /// layar ini langsung membuka pelacakan alih-alih formulir pemesanan baru.
  final String? initialOrderId;

  /// Kolom tujuan langsung aktif dengan keyboard terbuka — dari kotak "Diantar
  /// ke mana?" di beranda, yang memang berarti "saya mau mengetik tujuan".
  final bool fokusTujuan;

  /// Tujuan yang sudah dipilih di layar pencarian beranda: langsung dipasang,
  /// penumpang tidak disuruh memilih saran yang sama dua kali.
  final PlaceSuggestion? initialTempat;

  const OrderRideScreen({
    super.key,
    required this.initialService,
    this.initialDestination,
    required this.riderName,
    required this.riderPhone,
    this.initialOrderId,
    this.fokusTujuan = false,
    this.initialTempat,
  });

  @override
  State<OrderRideScreen> createState() => _OrderRideScreenState();
}

class _OrderRideScreenState extends State<OrderRideScreen> with TickerProviderStateMixin {
  // Kosong sampai GPS terbaca, supaya petunjuk "Dijemput di mana?" yang
  // terlihat — dulu "Lokasi saya di Sintang" tertulis seolah sudah pasti.
  final _pickupController = TextEditingController();
  final _destinationController = TextEditingController();
  final _fokusTujuan = FocusNode();
  final _formKey = GlobalKey<FormState>();

  late String _selectedService;
  double _fare = 0.0;
  double _biayaJasa = 0.0;
  // Taksiran dari server. Null berarti belum pernah berhasil diambil untuk
  // tujuan yang sekarang.
  EstimasiTarif? _estimasi;
  bool _estimasiGagal = false;

  int _inputStep = 0; // 0 = address picker, 1 = item details (BohAntar/BohSend), 2 = estimate
  
  // Package shipping details state
  String _packageType = "Dokumen";
  int _packageQuantity = 1;
  String _packageWeight = "1 kg";
  final _packageNotesController = TextEditingController();
  bool _insuranceActive = false;
  bool _specialHandlingActive = false;
  // Siapa yang menerima di tujuan. Kosong = pemesan sendiri.
  final _receiverNameController = TextEditingController();
  final _receiverPhoneController = TextEditingController();
  // Bukti serah-terima dari driver, dibaca saat pesanan selesai.
  String _receivedBy = "";
  String _deliveryPhotoUrl = "";
  // BohFood: uang makanan yang ditagih di atas ongkir, dan nama warungnya.
  double _foodTotal = 0;
  String _merchantName = "";
  // Isi pesanan dan cara bayarnya, supaya penumpang tahu berapa yang harus
  // disiapkan selama menunggu — dulu baru terlihat di layar sukses.
  List<dynamic> _itemsMakanan = const [];
  bool _bayarTunai = true;
  // Motor, plat, dan bintang driver dari server. Kosong = disembunyikan.
  // Plat dipisah supaya bisa ditulis besar: itu yang dicari penumpang di jalan.
  String _driverKendaraan = "";
  String _driverPlat = "";
  double _driverRating = 0;
  int _driverUlasan = 0;

  bool get _kirimBarang => _selectedService == "BohAntar" || _selectedService == "BohSend" || _selectedService == "BohFood";
  bool get _makanan => _selectedService == "BohFood";
  bool get _orang => jenisPesanan(_selectedService) == JenisPesanan.orang;
  IconData get _ikonKendaraan => _selectedService == "BohCar" ? Icons.directions_car : Icons.two_wheeler;
  
  // Interactive rating state
  int _ratingStars = 5;
  final _reviewController = TextEditingController();
  
  // Null sampai peta tergambar; pengambilan GPS memang sering selesai lebih
  // dulu, dan gerakan kamera sebelum itu cukup dilewati.
  GoogleMapController? _mapController;
  // Tengah peta terakhir. Google tidak punya `camera.center` yang bisa dibaca
  // seketika, jadi dicatat dari onCameraMove.
  LatLng? _pusatPeta;
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
  // Kabar di bawah kolom tujuan: tidak ketemu, atau pencariannya gagal. Dulu
  // galatnya ditelan dan penumpang cuma melihat kolom yang diam.
  String _pesanCari = '';
  Timer? _debounceTimer;
  // Rute adalah panggilan ke server OSRM umum, dan _calculateFareFromDistance()
  // dipanggil dari delapan tempat — tiap ketukan di peta memicu satu. Ditahan
  // sampai titiknya berhenti berpindah.
  Timer? _ruteDebounce;

  // Mode geser: pin diam di tengah layar dan petanya yang digeser, seperti
  // pemilih lokasi ojek online. Panel ditutup selama mode ini supaya peta
  // dapat satu layar penuh. Titik ikut ke tengah peta sambil digeser —
  // tombol "Pilih Lokasi" hanya menutup modenya.
  bool _geserPeta = false;
  bool _geserJemput = false; // true = yang digeser titik jemput, bukan tujuan
  Timer? _geserDebounce;

  // Routing points
  List<LatLng> _routePoints = [];
  // Rute jalan jemput→tujuan, sumber perkiraan waktu di panel ongkos. Dulu
  // waktunya dikarang dari jarak × 3 menit.
  Rute? _ruteJalan;
  // Rute driver selama pesanan berjalan, lihat _perbaruiRuteDriver().
  Rute? _ruteDriver;
  LatLng? _titikRuteDriver;
  String? _ruteDriverUntuk;
  bool _ambilRuteDriver = false;

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
    if (widget.initialOrderId != null) {
      // Langsung ke radar, bukan formulir alamat yang berkedip sekejap
      // sebelum pesanannya termuat.
      _orderStatus = "searching";
      _muatPesananBerjalan(widget.initialOrderId!);
    } else {
      // Pesanan berjalan membawa titik jemputnya sendiri; pesanan baru
      // dimulai dari posisi penumpang.
      _lokasiAwal();
    }
    if (widget.initialTempat case final tempat?) {
      _destinationController.text = tempat.name;
      // Setelah bingkai pertama: _pilihTempat memanggil setState.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pilihTempat(tempat);
      });
    } else if (widget.initialDestination != null) {
      _destinationController.text = widget.initialDestination!;
      // Tujuan yang dibawa dari layar lain cuma teks, belum punya koordinat.
      // Cari sarannya supaya penumpang tinggal memilih, bukan ditebakkan.
      _searchPlaces(widget.initialDestination!);
    }

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    muatIkonKendaraan().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _destinationController.dispose();
    _fokusTujuan.dispose();
    _packageNotesController.dispose();
    _receiverNameController.dispose();
    _receiverPhoneController.dispose();
    _reviewController.dispose();
    _statusTimer?.cancel();
    _radarController.dispose();
    _debounceTimer?.cancel();
    _ruteDebounce?.cancel();
    _geserDebounce?.cancel();
    super.dispose();
  }

  /// Dipanggil di dalam setState. Server hanya mengirim `driver` selama ada
  /// driver yang sedang bertugas.
  void _bacaInfoDriver(dynamic d) {
    if (d is! Map) return;
    _driverKendaraan = (d['kendaraan'] ?? '').toString();
    _driverPlat = (d['plat'] ?? '').toString();
    _driverRating = (d['rating'] as num?)?.toDouble() ?? 0;
    _driverUlasan = (d['jumlah_ulasan'] as num?)?.toInt() ?? 0;
  }

  /// Membuka kembali pesanan yang sedang berjalan, bukan formulir kosong.
  ///
  /// Penumpang yang menutup layar ini kehilangan peta, status, dan tombol chat
  /// sekaligus — padahal drivernya sedang di jalan menuju dia.
  Future<void> _muatPesananBerjalan(String id) async {
    try {
      final res = await ApiService().getOrderStatus(id);
      final o = res['order'];
      if (o == null || !mounted) return;

      final tujuanLat = (o['dropoff_lat'] as num?)?.toDouble();
      final tujuanLng = (o['dropoff_lng'] as num?)?.toDouble();
      final jemputLat = (o['pickup_lat'] as num?)?.toDouble();
      final jemputLng = (o['pickup_lng'] as num?)?.toDouble();

      setState(() {
        _orderId = id;
        _orderStatus = o['status'] == 'pending' ? 'searching' : o['status'];
        _selectedService = o['service'] ?? _selectedService;
        _fare = (o['fare'] as num?)?.toDouble() ?? 0;
        _biayaJasa = (o['biaya_jasa'] as num?)?.toDouble() ?? 0;
        _driverName = o['driver_name'] ?? '';
        _driverPhone = o['driver_phone'] ?? '';
        _foodTotal = (o['food_total'] as num?)?.toDouble() ?? 0;
        _merchantName = (o['merchant_name'] ?? '').toString();
        _itemsMakanan = (o['items'] as List?) ?? const [];
        _bayarTunai = o['payment_method'] != 'wallet';
        _bacaInfoDriver(res['driver']);
        _pickupController.text = o['pickup'] ?? '';
        _destinationController.text = o['dropoff'] ?? '';
        if (jemputLat != null && jemputLng != null) {
          _currentLatLng = LatLng(jemputLat, jemputLng);
          _gpsTerbaca = true;
        }
        if (tujuanLat != null && tujuanLng != null) {
          _destinationLatLng = LatLng(tujuanLat, tujuanLng);
        }
      });

      if (_orderStatus == 'searching') _radarController.repeat();
      _fitMapBounds();
      _fetchRoute();
      _startPollingStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(pesanGalat(e))),
      );
    }
  }

  /// Mengirim bintang dan ulasan ke server.
  ///
  /// Dulu tombolnya hanya menutup layar — bintangnya tidak pernah sampai ke mana
  /// pun, dan rating setiap driver tetap 5,0 selamanya.
  Future<void> _kirimPenilaian() async {
    final id = _orderId;
    if (id == null) {
      Navigator.pop(context, true);
      return;
    }
    try {
      await ApiService().rateOrder(id, _ratingStars, _reviewController.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Terima kasih, penilaianmu sudah terkirim.')),
      );
    } catch (e) {
      if (!mounted) return;
      // Penilaian yang gagal terkirim bukan alasan menahan penumpang di layar
      // ini; perjalanannya sendiri sudah selesai dan terbayar.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(pesanGalat(e))),
      );
    }
    if (mounted) Navigator.pop(context, true);
  }

  /// Membatalkan pesanan atas permintaan penumpang. Backend menolak setelah
  /// penumpang naik — sesudah titik itu drivernya sudah bekerja.
  Future<void> _batalkanPesanan() async {
    final id = _orderId;
    if (id == null) return;

    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Batalkan pesanan?'),
        // Selagi mencari belum ada driver yang perlu diberi tahu.
        content: Text(_orderStatus == 'searching'
            ? 'Pesananmu belum dapat driver. Kalau dibatalkan, pencarian dihentikan.'
            : 'Driver yang sedang menuju ke tempatmu akan langsung diberi tahu.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Jangan')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya, batalkan', style: TextStyle(color: AppTheme.errorColor)),
          ),
        ],
      ),
    );
    if (yakin != true) return;

    try {
      await ApiService().cancelOrder(id);
      if (!mounted) return;
      _statusTimer?.cancel();
      _radarController.stop();
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pesanGalat(e)),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  /// Peta penumpang dibuka di posisinya sendiri, bukan di tengah kota. Posisi
  /// terakhir yang diingat HP muncul seketika (bisa basi, jadi _gpsTerbaca
  /// tetap false); GPS segar menyusul lewat jalur yang sama dengan tombol
  /// "Pakai GPS", dan baru itu yang dianggap titik jemput sungguhan.
  Future<void> _lokasiAwal() async {
    try {
      final izin = await Geolocator.checkPermission();
      if (izin == LocationPermission.whileInUse || izin == LocationPermission.always) {
        final terakhir = await Geolocator.getLastKnownPosition();
        if (terakhir != null && mounted && !_gpsTerbaca) {
          setState(() => _currentLatLng = LatLng(terakhir.latitude, terakhir.longitude));
          _pindahPeta(_currentLatLng, 15);
        }
      }
    } catch (e) {
      debugPrint('Posisi terakhir penumpang gagal: $e');
    }
    if (mounted) await _getCurrentLocation(senyap: true);
  }

  Future<void> _getCurrentLocation({bool senyap = false}) async {
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
                Text("GPS belum nyala"),
              ],
            ),
            content: const Text(
              "Nyalakan GPS supaya titik jemputmu terpasang otomatis. Bisa juga geser peta ke lokasimu."
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Nanti"),
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
                child: const Text("Nyalakan GPS"),
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
            content: Text("Tanpa izin lokasi, geser peta ke titik jemputmu ya."),
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
            title: const Text("Izin lokasi masih ditolak"),
            content: const Text(
              "Buka pengaturan, lalu izinkan bohAntar membaca lokasi supaya titik jemputmu terpasang otomatis."
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Nanti"),
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
                child: const Text("Buka pengaturan"),
              ),
            ],
          );
        },
      );
      return;
    }

    // When we reach here, permissions are granted and we can fetch coordinates
    setState(() {
      _pickupController.text = "Mencari lokasimu…";
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

      // Saat layar dibuka, alamat di kolom jemput sudah cukup jadi kabar.
      if (!mounted || senyap) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Titik jemput dipindah ke lokasimu sekarang."),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint("GPS gagal: $e");
      // Kosong, bukan "Sintang, Kalimantan Barat": tulisan kota terbaca seolah
      // titik jemputnya sudah pasti, padahal _gpsTerbaca masih false.
      setState(() {
        _pickupController.text = "";
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Lokasimu belum terbaca. Geser peta ke titik jemput, atau coba lagi."),
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
          const SnackBar(content: Text("Pilih tujuan dari daftar, atau ketuk titiknya di peta untuk lihat ongkos.")),
        );
      }
      return;
    }
    _calculateFareFromDistance();
  }

  /// Tombol × di kolom tujuan: kosong sekaligus, tidak perlu menghapus huruf
  /// satu per satu, lalu keyboard siap untuk tujuan baru.
  void _hapusTujuan() {
    _destinationController.clear();
    _onDestinationChanged(''); // titik, rute, dan ongkos lama ikut dibuang
    setState(() => _suggestions = []);
    _fokusTujuan.requestFocus();
  }

  void _onDestinationChanged(String query) {
    // Tulisan tujuan diubah tangan: titik lama tidak lagi sesuai tulisannya.
    // Tanpa ini pesanan bisa berangkat ke tujuan sebelumnya dengan nama yang
    // baru diketik. Tombol Lanjutkan menunggu sampai satu saran dipilih atau
    // titiknya digeser di peta.
    if (_destinationLatLng != null || _pesanCari.isNotEmpty) {
      setState(() {
        _destinationLatLng = null;
        _routePoints = [];
        _estimasi = null;
        _estimasiGagal = false;
        _pesanCari = '';
      });
    }
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
        _pesanCari = hasil.isEmpty ? 'Tempatnya belum ketemu. Coba nama lain, atau geser peta ke tujuan.' : '';
      });
    } catch (e) {
      debugPrint("Suggestions fetch error: $e");
      if (!mounted) return;
      setState(() {
        _suggestions = [];
        _loadingSuggestions = false;
        _pesanCari = pesanGalat(e);
      });
    }
  }

  // Taksiran ongkos datang dari server, bukan dihitung di sini. Rumus dan
  // jaraknya harus sama persis dengan yang dipakai saat pesanan dibuat —
  // aplikasi ini pernah menyimpan salinan rumusnya sendiri, dan salinan itu
  // tidak pernah ikut berubah saat tarif diubah dari dashboard.
  Future<void> _ambilEstimasi(LatLng tujuan, String layanan) async {
    try {
      final hasil = await ApiService().estimasiTarif(
        layanan: layanan,
        dariLat: _currentLatLng.latitude,
        dariLng: _currentLatLng.longitude,
        keLat: tujuan.latitude,
        keLng: tujuan.longitude,
      );
      // Tujuan atau layanan bisa sudah berganti selama permintaan berjalan;
      // balasan yang sudah basi tidak boleh menimpa angka yang sedang tampil.
      if (!mounted || _destinationLatLng != tujuan || _selectedService != layanan) return;
      setState(() {
        _estimasi = hasil;
        // _fare adalah ongkos perjalanan saja, sama seperti kolom `fare` di
        // server. Biaya jasa disimpan terpisah supaya rinciannya bisa
        // ditampilkan dan supaya angka yang dibandingkan dengan balasan server
        // tetap sepadan.
        _fare = hasil.ongkos;
        _biayaJasa = hasil.biayaJasa;
        _estimasiGagal = false;
      });
    } catch (e) {
      debugPrint("Estimasi tarif gagal: $e");
      if (!mounted || _destinationLatLng != tujuan) return;
      setState(() {
        _estimasi = null;
        _fare = 0;
        _estimasiGagal = true;
      });
    }
  }

  void _calculateFareFromDistance() {
    final tujuan = _destinationLatLng;
    if (tujuan == null) return;
    final layanan = _selectedService;
    setState(() {
      _estimasi = null;
      _estimasiGagal = false;
    });
    // Estimasi dan rute sama-sama panggilan jaringan, jadi keduanya ditahan
    // sampai titiknya berhenti berpindah.
    _ruteDebounce?.cancel();
    _ruteDebounce = Timer(const Duration(milliseconds: 500), () {
      _ambilEstimasi(tujuan, layanan);
      _fetchRoute();
    });
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
          const SnackBar(content: Text("Lokasi tempat ini belum tersedia. Pilih yang lain, atau ketuk titiknya di peta.")),
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
        SnackBar(content: Text(pesanGalat(e))),
      );
    }
  }

  void _pindahPeta(LatLng titik, double zoom) {
    _pusatPeta = titik;
    _mapController?.moveCamera(CameraUpdate.newLatLngZoom(titik, zoom));
  }

  // Penanda di peta. Pemindahannya lewat peta, bukan pin `draggable`: ketuk
  // untuk memindahkan tujuan, tekan lama untuk memindahkan titik jemput —
  // lebih mudah dikenai jempol daripada menyeret pin kecil.
  Set<Marker> _penandaPeta() {
    final tujuan = _destinationLatLng;
    final driver = _driverLatLng;

    return {
      // Titik yang sedang digeser diwakili pin tetap di tengah layar, jadi
      // penandanya disembunyikan supaya tidak ada dua pin di tempat sama.
      if (!(_geserPeta && _geserJemput) && _orderStatus != "picked_up")
        penandaPeta(titik: _currentLatLng, warna: Colors.green, judul: 'Titik jemput'),
      if (tujuan != null && !(_geserPeta && !_geserJemput))
        penandaPeta(titik: tujuan, warna: Colors.red, judul: 'Tujuan'),
      // Penanda driver tetap tampil sampai penumpang diantar, bukan hilang
      // begitu status berpindah dari "accepted" ke "picked_up".
      if (driver != null && (_orderStatus == "accepted" || _orderStatus == "picked_up"))
        penandaMotor(titik: driver, judul: _driverName.isEmpty ? 'Driver' : _driverName, ikon: _ikonKendaraan),
    };
  }

  // Memuat kotak batasnya langsung, jadi zoom tidak ditebak dengan angka tetap
  // 13 yang dulu memotong tujuan jauh di luar layar.
  void _fitMapBounds() {
    final tujuan = _destinationLatLng;
    final peta = _mapController;
    if (tujuan == null || peta == null) return;

    final a = _currentLatLng;
    // Google tidak punya maxZoom untuk kotak batas: dua titik yang nyaris
    // berimpit (±100 m) membuatnya zoom sampai batas teratas, jadi dipusatkan
    // saja di zoom 17.
    if ((a.latitude - tujuan.latitude).abs() < 1e-3 && (a.longitude - tujuan.longitude).abs() < 1e-3) {
      peta.moveCamera(CameraUpdate.newLatLngZoom(tujuan, 17));
      return;
    }
    // LatLngBounds Google menuntut sudut barat daya dan timur laut yang benar.
    peta.moveCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(min(a.latitude, tujuan.latitude), min(a.longitude, tujuan.longitude)),
        northeast: LatLng(max(a.latitude, tujuan.latitude), max(a.longitude, tujuan.longitude)),
      ),
      60,
    ));
  }

  Future<void> _fetchRoute() async {
    final tujuan = _destinationLatLng;
    if (tujuan == null) {
      setState(() {
        _routePoints = [];
        _ruteJalan = null;
      });
      return;
    }
    try {
      final hasil = await MapsService().rute(_currentLatLng, tujuan);
      if (!mounted) return;
      if (hasil != null && hasil.titik.isNotEmpty) {
        setState(() {
          _routePoints = hasil.titik;
          _ruteJalan = hasil;
        });
        return;
      }
    } catch (e) {
      debugPrint("Routing error: $e");
    }
    if (!mounted) return;
    // Garis lurus sebagai jalan terakhir supaya peta tidak kosong. Ini jelas
    // bukan rute sungguhan, tapi lebih jujur daripada tidak menggambar apa pun
    // saat layanan rute sedang tidak bisa dihubungi. Waktunya ikut kosong.
    setState(() {
      _routePoints = [_currentLatLng, tujuan];
      _ruteJalan = null;
    });
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
        const SnackBar(content: Text("Isi dulu titik jemput dan tujuannya, ya.")),
      );
      return;
    }
    if (!_gpsTerbaca) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Titik jemput belum pasti. Nyalakan GPS, atau tekan lama lokasimu di peta.")),
      );
      return;
    }
    // Server menolak order tanpa koordinat tujuan, jadi jangan sampai terkirim.
    final tujuan = _destinationLatLng;
    if (tujuan == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pilih tujuan dari daftar, atau ketuk titiknya di peta.")),
      );
      return;
    }
    if (_fare <= 0) {
      _calculateFare();
      return;
    }

    setState(() {
      _orderStatus = "searching";
      // Kotak "siapkan uang" di layar pelacakan membaca ini.
      _bayarTunai = true;
    });
    _radarController.repeat();

    try {
      final response = await ApiService().createOrder(
        pickup: _pickupController.text,
        dropoff: _destinationController.text,
        service: _selectedService,
        // Penumpang hanya bayar tunai sejak 24 Okt 2026: bohAntar tidak boleh
        // menampung uang pelanggan (kasus ojol Sintang di Polda Kalbar).
        paymentMethod: "cash",
        pickupLat: _currentLatLng.latitude,
        pickupLng: _currentLatLng.longitude,
        dropoffLat: tujuan.latitude,
        dropoffLng: tujuan.longitude,
        packageType: _kirimBarang ? _packageType : null,
        packageQuantity: _kirimBarang ? _packageQuantity : null,
        packageWeight: _kirimBarang ? _packageWeight : null,
        packageNotes: _kirimBarang ? _packageNotesController.text : null,
        insurance: _kirimBarang ? _insuranceActive : null,
        specialHandling: _kirimBarang ? _specialHandlingActive : null,
        receiverName: _kirimBarang ? _receiverNameController.text.trim() : null,
        receiverPhone: _kirimBarang ? _receiverPhoneController.text.trim() : null,
      );

      if (response['status'] == 'success' && response['order'] != null) {
        final order = response['order'];
        setState(() {
          _orderId = order['id'];
          // Ongkos server yang berlaku, bukan taksiran lokal tadi.
          _fare = (order['fare'] as num?)?.toDouble() ?? _fare;
          // Angka server yang berlaku, bukan taksiran lokal: super admin bisa
          // saja sudah mengubah biaya jasa sejak aplikasi ini dipasang.
          _biayaJasa = (order['biaya_jasa'] as num?)?.toDouble() ?? _biayaJasa;
        });

        // Start polling order status
        _startPollingStatus();
      } else {
        throw Exception("Pesanan belum terkirim. Coba lagi sebentar, ya.");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _orderStatus = "input";
      });
      _radarController.stop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pesanGalat(e)),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  void _startPollingStatus() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_orderId == null) return;
      // Di latar belakang tidak ada yang menatap peta; kabar penting tetap
      // datang lewat notifikasi, dan tik pertama setelah dibuka lagi menyusul.
      final s = WidgetsBinding.instance.lifecycleState;
      if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) return;

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

          if (response['driver'] != null) setState(() => _bacaInfoDriver(response['driver']));

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
              _ruteDriver = null;
              _receivedBy = (order['received_by'] ?? '').toString();
              _deliveryPhotoUrl = (order['delivery_photo_url'] ?? '').toString();
              _foodTotal = (order['food_total'] as num?)?.toDouble() ?? _foodTotal;
            });
          } else if (status == 'cancelled' || status == 'expired') {
            // Bisa datang dari admin yang menutup pesanan tersangkut, atau dari
            // batas 15 menit tanpa driver. Radar yang berputar selamanya lebih
            // buruk daripada kabar buruk yang jelas.
            timer.cancel();
            _radarController.stop();
            if (!mounted) return;
            final kabar = kabarPesanan(_selectedService, status);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${kabar.judul}. ${kabar.keterangan}')),
            );
            Navigator.pop(context, true);
          }
          _perbaruiRuteDriver();
        }
      } catch (e) {
        debugPrint("Error polling status: $e");
      }
    });
  }

  // Rute dari posisi driver ke titik jemput, lalu ke tujuan sesudah dijemput —
  // sama dengan yang dilihat driver. Diambil ulang hanya saat statusnya berganti
  // atau driver sudah bergerak sejauh ambang driver (dashboard_screen.dart,
  // _jarakGambarUlangRuteMeter); di antaranya estimasinya disusutkan sendiri
  // oleh teksEstimasi(). Gagal pun dicatat, supaya polling 2 detik tidak
  // berubah jadi tembakan ke layanan rute tiap 2 detik.
  Future<void> _perbaruiRuteDriver() async {
    final driver = _driverLatLng;
    final tujuan = _orderStatus == 'picked_up'
        ? _destinationLatLng
        : _orderStatus == 'accepted'
            ? _currentLatLng
            : null;
    if (driver == null || tujuan == null) {
      if (_ruteDriver != null) setState(() => _ruteDriver = null);
      return;
    }
    final terakhir = _titikRuteDriver;
    if (_ambilRuteDriver ||
        (_ruteDriverUntuk == _orderStatus &&
            terakhir != null &&
            Geolocator.distanceBetween(terakhir.latitude, terakhir.longitude, driver.latitude, driver.longitude) < 2000)) {
      return;
    }
    _ambilRuteDriver = true;
    _titikRuteDriver = driver;
    _ruteDriverUntuk = _orderStatus;
    try {
      final hasil = await MapsService().rute(driver, tujuan);
      if (mounted) setState(() => _ruteDriver = hasil);
    } catch (e) {
      debugPrint('Rute driver gagal: $e');
    } finally {
      _ambilRuteDriver = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_orderStatus == "completed") {
      return _buildSuccessScreen(theme, isDark);
    }

    // Tombol kembali di app bar dan gestur kembali Android lewat jalur yang
    // sama. Dulu gestur kembali menutup layar di langkah mana pun, dan tombol
    // kembali selagi mencari driver memunculkan formulir lagi padahal pesanannya
    // tetap hidup di server — penumpang bisa memesan dua kali. Sekarang layar
    // pelacakan cukup ditutup; pesanannya tetap tampil di beranda.
    return PopScope(
      canPop: !_geserPeta && (_orderStatus != "input" || _inputStep == 0),
      onPopInvokedWithResult: (sudahKeluar, _) {
        if (!sudahKeluar) _mundurSelangkah();
      },
      child: Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(_judulLayar, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: Stack(
        children: [
          // Selama masih di langkah memilih tujuan, ketuk peta memindahkan
          // tujuan dan tekan lama memindahkan titik jemput.
          Positioned.fill(
            child: GoogleMap(
                initialCameraPosition: CameraPosition(target: _currentLatLng, zoom: 14),
                // Tombol bawaan Google bertabrakan dengan panel di atas peta.
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                myLocationButtonEnabled: false,
                onMapCreated: (peta) {
                  _mapController = peta;
                  // GPS dan pesanan berjalan bisa lebih cepat dari peta;
                  // gerakan kameranya tadi terlewat.
                  if (_destinationLatLng != null) {
                    _fitMapBounds();
                  } else {
                    _pindahPeta(_currentLatLng, 15);
                  }
                },
                onTap: (titik) {
                  if (_orderStatus != "input" || _inputStep != 0) return;
                  setState(() {
                    _destinationLatLng = titik;
                    _destinationController.text = "Mengambil alamat tujuan...";
                  });
                  _calculateFareFromDistance();
                  _reverseGeocode(titik, false);
                },
                onLongPress: (titik) {
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
                // Sambil digeser, titiknya ikut tengah peta. Alamatnya ditahan
                // sampai peta berhenti, supaya satu geseran tidak jadi puluhan
                // panggilan geocode.
                onCameraMove: (kamera) {
                  final titik = kamera.target;
                  _pusatPeta = titik;
                  if (!_geserPeta) return;
                  if (_geserJemput) {
                    _currentLatLng = titik;
                    _gpsTerbaca = true;
                  } else {
                    _destinationLatLng = titik;
                  }
                  _geserDebounce?.cancel();
                  _geserDebounce = Timer(const Duration(milliseconds: 600), () {
                    if (!mounted || !_geserPeta) return;
                    _calculateFareFromDistance();
                    _reverseGeocode(titik, _geserJemput);
                  });
                },
                polylines: {
                  if ((_ruteDriver?.titik ?? _routePoints).isNotEmpty)
                    Polyline(
                      polylineId: const PolylineId('rute'),
                      points: _ruteDriver?.titik ?? _routePoints,
                      color: AppTheme.primaryBlue,
                      width: 5,
                    ),
                },
                markers: _penandaPeta(),
            ),
          ),

          if (_geserPeta) ..._pinTengah(),

          // Main Interactive Panels
          SafeArea(
            child: Column(
              children: [
                if (_orderStatus == "input" && !_geserPeta) ...[
                  if (_inputStep == 0) _buildDestinationPickerPanel(theme, isDark),
                  if (_inputStep == 1) _buildPackageDetailPanel(theme, isDark),
                  if (_inputStep == 2) _buildPriceEstimatePanel(theme, isDark),
                ],
                const Spacer(),
                if (_orderStatus == "searching") _panelBawah(_buildRadarSearchPanel(theme, isDark)),
                // Ikut tampil saat picked_up: justru saat barang sudah di tangan
                // driver, penumpang paling butuh chat, telepon, dan status.
                if (_orderStatus == "accepted" || _orderStatus == "picked_up") _panelBawah(_buildDriverComingPanel(theme, isDark)),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  String get _judulLayar {
    if (_orderStatus == "input") {
      if (_inputStep == 1) return "Detail paket";
      if (_inputStep == 2) return "Cek ongkos";
      return _kirimBarang ? "Kirim paket ke mana?" : "Mau ke mana?";
    }
    if (_orderStatus == "searching") return "Mencari driver";
    return _orang ? "Perjalananmu" : "Pesananmu";
  }

  void _mundurSelangkah() {
    if (_geserPeta) {
      // Keluar dari mode geser dulu, jangan langsung tutup layarnya.
      _geserDebounce?.cancel();
      setState(() => _geserPeta = false);
    } else if (_orderStatus == "input" && _inputStep > 0) {
      // Layanan penumpang melompati langkah 1 (detail paket), jadi mundurnya
      // juga melompat.
      setState(() => _inputStep = _inputStep == 2 && !_kirimBarang ? 0 : _inputStep - 1);
    }
  }

  /// Panel pelacakan bisa lebih tinggi dari layar HP kecil (makanan banyak,
  /// timeline, tombol). Dibatasi lalu digulung supaya petanya tetap kelihatan
  /// dan tidak ada galat luber.
  Widget _panelBawah(Widget panel) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.66),
        child: SingleChildScrollView(child: panel),
      );

  // Ukuran pin tengah. Dengan Center + padding bawah setinggi pinnya, ujung
  // bawah pin jatuh persis di titik tengah peta — tidak ada angka ajaib.
  static const double _tinggiPin = 44;
  static const double _tinggiTombolPin = 44;

  void _mulaiGeser(bool jemput) {
    setState(() {
      _geserPeta = true;
      _geserJemput = jemput;
      // Pencarian ditinggalkan: kabar dan sarannya tidak berlaku lagi.
      _pesanCari = '';
      _suggestions = [];
    });
    // Pin mulai dari titik yang sedang dipilih, bukan dari tengah peta yang
    // kebetulan sedang terlihat.
    _pindahPeta(jemput ? _currentLatLng : (_destinationLatLng ?? _currentLatLng), 17);
  }

  void _selesaiGeser() {
    _geserDebounce?.cancel();
    final jemput = _geserJemput;
    // Peta yang tidak sempat bergerak sama sekali belum pernah memanggil
    // onCameraMove; _pindahPeta di _mulaiGeser sudah mencatat titik awalnya.
    final titik = _pusatPeta ?? _currentLatLng;
    setState(() {
      _geserPeta = false;
      if (jemput) {
        _currentLatLng = titik;
        _gpsTerbaca = true;
      } else {
        _destinationLatLng = titik;
      }
    });
    _calculateFareFromDistance();
    _reverseGeocode(titik, jemput);
  }

  // Pin diam di tengah layar + tombol di atasnya. Yang digeser petanya, jadi
  // pin tidak perlu jadi widget yang bisa ditarik.
  List<Widget> _pinTengah() {
    return [
      IgnorePointer(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: _tinggiPin),
            child: Icon(
              Icons.location_on,
              size: _tinggiPin,
              color: _geserJemput ? Colors.green : Colors.red,
            ),
          ),
        ),
      ),
      Center(
        child: Padding(
          // Tinggi tombol + 2 × (jarak ke pin + tinggi pin): menaruh dasar
          // tombol 8px di atas kepala pin.
          padding: const EdgeInsets.only(bottom: _tinggiTombolPin + 2 * (_tinggiPin + 8)),
          child: SizedBox(
            height: _tinggiTombolPin,
            child: ElevatedButton.icon(
              onPressed: _selesaiGeser,
              icon: const Icon(Icons.check, size: 18),
              label: Text(_geserJemput ? (_kirimBarang ? "Ambil paket di sini" : "Jemput di sini") : (_kirimBarang ? "Kirim ke sini" : "Antar ke sini")),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _buildDestinationPickerPanel(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      // Panel ini dulu memakan separuh layar lebih dan peta cuma kebagian sisa.
      // Dibatasi 45% tinggi layar lalu digulung ke dalam.
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
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
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Column(
                  children: [
                    const Icon(Icons.circle, color: Colors.green, size: 14),
                    Container(width: 2, height: 44, color: Colors.grey.shade300),
                    const Icon(Icons.location_on, color: Colors.red, size: 18),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      // Pickup text input
                      // Tidak bisa diketik: tulisan jemput yang diubah tangan
                      // tidak memindahkan titiknya, jadi driver datang ke titik
                      // lama dengan alamat baru. Mengetuknya membuka mode geser.
                      // Label berupa pertanyaan: kosong ia jadi petunjuk, terisi
                      // ia naik jadi judul jawabannya.
                      TextFormField(
                        controller: _pickupController,
                        readOnly: true,
                        onTap: () => _mulaiGeser(true),
                        decoration: _hiasKolomAlamat(
                          isDark,
                          label: _kirimBarang ? "Paket diambil di mana?" : "Dijemput di mana?",
                          // Satu ikon saja: mengetuk kolomnya sudah membuka
                          // mode geser peta, dan ikon pin kedua dulu memotong
                          // alamatnya jadi tinggal belasan huruf.
                          aksi: IconButton(
                            tooltip: "Pakai lokasiku sekarang",
                            icon: const Icon(Icons.my_location, color: AppTheme.primaryBlue, size: 18),
                            onPressed: _getCurrentLocation,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Dropoff text input
                      TextFormField(
                        controller: _destinationController,
                        focusNode: _fokusTujuan,
                        autofocus: widget.fokusTujuan,
                        textInputAction: TextInputAction.search,
                        decoration: _hiasKolomAlamat(
                          isDark,
                          label: _kirimBarang ? "Dikirim ke mana?" : "Diantar ke mana?",
                          petunjuk: "Ketik nama tempat, mis. RSUD atau pasar",
                          // Dibangun ulang sendiri tiap ketikan supaya tombol
                          // hapus muncul/hilang tanpa menggambar ulang layar.
                          aksi: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _destinationController,
                            builder: (_, nilai, _) => Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (nilai.text.isNotEmpty)
                                  IconButton(
                                    tooltip: "Hapus tujuan",
                                    visualDensity: VisualDensity.compact,
                                    icon: Icon(Icons.close, size: 18, color: AppTheme.teksRedup(context)),
                                    onPressed: _hapusTujuan,
                                  ),
                                IconButton(
                                  tooltip: "Pilih di peta",
                                  icon: const Icon(Icons.pin_drop_outlined, color: Colors.red, size: 18),
                                  onPressed: () => _mulaiGeser(false),
                                ),
                              ],
                            ),
                          ),
                        ),
                        onChanged: _onDestinationChanged,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: "Tukar titik jemput dan tujuan",
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
                      subtitle: Text(place.address, style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context)), maxLines: 1, overflow: TextOverflow.ellipsis),
                      // Koordinat baru diambil di sini, sekali, untuk tempat yang
                      // benar-benar dipilih.
                      onTap: () => _pilihTempat(place),
                    );
                  },
                ),
              ),
            if (_pesanCari.isNotEmpty && !_loadingSuggestions)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_pesanCari, style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context))),
                    ),
                    TextButton(
                      onPressed: () => _mulaiGeser(false),
                      child: const Text('Pilih di peta'),
                    ),
                  ],
                ),
              ),

            // Ketuk dan tekan-lama peta tidak kelihatan dari mana pun; tanpa
            // kalimat ini penumpang tidak tahu peta bisa dipakai memilih.
            if (_destinationLatLng == null && _suggestions.isEmpty && _pesanCari.isEmpty && !_loadingSuggestions)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.touch_app_outlined, size: 16, color: AppTheme.teksRedup(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        "Bisa juga ketuk peta untuk pilih tujuan, atau tekan lama untuk pindah titik jemput.",
                        style: TextStyle(fontSize: 11.5, color: AppTheme.teksRedup(context)),
                      ),
                    ),
                  ],
                ),
              ),

            // "Lokasi tersimpan" Rumah/Kantor dibuang 9 Okt 2026: alamatnya
            // karangan, dan mengetuknya diam-diam memindahkan titik jemput ke
            // koordinat tetap. Pasang lagi kalau user_addresses sudah
            // menyimpan koordinat, bukan cuma tulisan.
            const SizedBox(height: 18),

            ElevatedButton(
              onPressed: _destinationLatLng != null
                  ? () {
                      setState(() {
                        if (_kirimBarang) {
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
              // Menyebut langkah berikutnya, bukan sekadar "Lanjutkan".
              child: Text(_kirimBarang ? "Lanjut isi detail paket" : "Lihat ongkos"),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// Kolom alamat jemput dan tujuan: kotak membulat tanpa garis, label berupa
  /// pertanyaan.
  InputDecoration _hiasKolomAlamat(bool isDark, {required String label, String? petunjuk, Widget? aksi}) {
    final tanpaGaris = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none);
    return InputDecoration(
      labelText: label,
      hintText: petunjuk,
      labelStyle: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context)),
      floatingLabelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.teksRedup(context)),
      hintStyle: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context)),
      suffixIcon: aksi,
      isDense: true,
      contentPadding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
      border: tanpaGaris,
      enabledBorder: tanpaGaris,
      focusedBorder: tanpaGaris,
      filled: true,
      fillColor: isDark ? AppTheme.bgObsidianDark : const Color(0xFFF1F5F9),
    );
  }

  Widget _buildPackageDetailPanel(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      // Dibatasi lalu digulung: isian penerima membuat panel ini lebih tinggi
      // dari layar HP kecil, apalagi saat keyboard terbuka.
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 16)],
      ),
      child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Paket & penerima", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              TextButton(
                onPressed: () => setState(() => _inputStep = 0),
                child: const Text("Kembali", style: TextStyle(color: AppTheme.primaryBlue)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          const Text("Isi paket", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
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
                    const Text("Perkiraan berat", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
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
              hintText: "Mis. telepon dulu, ya",
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(height: 12),

          // Driver yang sampai di tujuan menelepon nomor ini, bukan nomor
          // pemesan. Kosong berarti pemesan sendiri yang menerima.
          const Text("Siapa yang terima?", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          // Keterangan di luar kolom: di dalam petunjuk kolom kalimatnya
          // terpotong di layar HP biasa.
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Text(
              "Kosongkan kalau kamu sendiri. Nomornya dipakai driver untuk menghubungi penerima.",
              style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context)),
            ),
          ),
          TextFormField(
            controller: _receiverNameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              hintText: "Nama penerima",
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _receiverPhoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              hintText: "No. HP penerima",
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          const SizedBox(height: 16),

          const Text("Perlu perhatian khusus?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          // Dulu berlabel "Asuransi barang", padahal server tidak mengasuransikan
          // apa pun — keduanya cuma pesan untuk driver. Labelnya sekarang
          // menyebut yang benar-benar terjadi. Nama kolomnya (insurance,
          // special_handling) sengaja tetap supaya API tidak berubah.
          SwitchListTile(
            value: _insuranceActive,
            onChanged: (val) => setState(() => _insuranceActive = val),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text("Barang berharga", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text("Driver diminta ekstra menjaga paketmu", style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
          ),
          SwitchListTile(
            value: _specialHandlingActive,
            onChanged: (val) => setState(() => _specialHandlingActive = val),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text("Mudah pecah", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text("Jangan dibanting atau ditumpuk", style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
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
            child: const Text("Lihat ongkos"),
          ),
        ],
      ),
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
    final tarif = _estimasi;
    final distanceKm = tarif?.km ?? 0;

    return Container(
      padding: const EdgeInsets.all(20),
      margin: const EdgeInsets.all(16),
      // Digulung: kartu cara bayar membuat panel ini lebih tinggi dari HP kecil.
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16)],
      ),
      child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Rincian ongkos", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_kirimBarang) {
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
                _buildSummaryLine(Icons.circle, Colors.green, _kirimBarang ? "Diambil" : "Dijemput", _pickupController.text),
                const SizedBox(height: 8),
                _buildSummaryLine(Icons.location_on, Colors.red, _kirimBarang ? "Dikirim ke" : "Diantar ke", _destinationController.text),
                const Divider(height: 16),
                Row(
                  children: [
                    Icon(Icons.route_outlined, size: 15, color: AppTheme.teksRedup(context)),
                    const SizedBox(width: 6),
                    Text("${distanceKm.toStringAsFixed(1).replaceAll('.', ',')} km", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    // Dari rute jalan sungguhan, bukan jarak × 3 menit seperti
                    // dulu. Tanpa rute (layanan rute gagal) waktunya tidak
                    // ditulis daripada dikarang.
                    if ((_ruteJalan?.detik ?? 0) > 0) ...[
                      const SizedBox(width: 16),
                      Icon(Icons.schedule, size: 15, color: AppTheme.teksRedup(context)),
                      const SizedBox(width: 6),
                      Text("± ${(_ruteJalan!.detik / 60).round().clamp(1, 999)} menit perjalanan", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ],
                )
              ],
            ),
          ),
          const SizedBox(height: 16),

          const Text("Rincian biaya", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 8),
          if (tarif == null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _estimasiGagal ? "Ongkos belum bisa dihitung. Cek koneksi internetmu." : "Menghitung ongkos…",
                    style: TextStyle(fontSize: 13, color: _estimasiGagal ? AppTheme.errorColor : AppTheme.teksRedup(context)),
                  ),
                ),
                if (_estimasiGagal)
                  TextButton(onPressed: _calculateFareFromDistance, child: const Text("Coba lagi")),
              ],
            )
          else ...[
            // Ongkos ditampilkan sebagai satu angka, bukan dipecah jadi tarif
            // dasar ditambah jarak: sejak ada jarak dasar dan pembulatan ke
            // atas, dua baris itu tidak lagi menjumlah tepat ke yang ditagih.
            _buildFareRow("Ongkos perjalanan (${distanceKm.toStringAsFixed(1).replaceAll('.', ',')} km)", tarif.ongkos),
            // Ditampilkan terpisah, bukan dilebur ke ongkos: penumpang berhak
            // tahu mana yang untuk driver dan mana yang untuk aplikasi.
            if (tarif.biayaJasa > 0) _buildFareRow("Biaya jasa aplikasi", tarif.biayaJasa),
          ],
          // Asuransi dan penanganan khusus tidak muncul di sini karena server
          // tidak menagihnya: keduanya dikirim sebagai permintaan ke driver,
          // bukan sebagai biaya. Kalau memang mau ditagih, tempatnya di tabel
          // tarif bersama base dan per_km, bukan dihitung diam-diam di aplikasi.
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Total bayar", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              Text(
                tarif == null ? "-" : rupiah(tarif.total),
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: AppTheme.primaryBlue),
              ),
            ],
          ),
          const SizedBox(height: 18),

          Row(
            children: [
              const Icon(Icons.payments_outlined, size: 18, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              Text("Bayar tunai ke driver", style: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context))),
            ],
          ),
          const SizedBox(height: 16),

          ElevatedButton(
            onPressed: _bookRide,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            // Total ikut di tombol: yang ditekan sama dengan yang dibayar.
            child: Text(tarif == null ? "Pesan $_selectedService" : "Pesan $_selectedService · ${rupiah(tarif.total)}"),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSummaryLine(IconData icon, Color color, String label, String text) {
    return Row(
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 8),
        Expanded(
          // Text.rich, bukan RichText: RichText tidak mewarisi gaya bawaan
          // tema, jadi hurufnya jatuh ke font sistem, bukan Inter.
          child: Text.rich(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            TextSpan(
              children: [
                TextSpan(text: "$label: ", style: TextStyle(color: AppTheme.teksRedup(context))),
                TextSpan(text: text, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            style: const TextStyle(fontSize: 12),
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
          Text(label, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12)),
          Text(rupiah(cost), style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  BoxDecoration _hiasPanel(bool isDark) => BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 20, offset: const Offset(0, 6))],
      );

  Widget _buildRadarSearchPanel(ThemeData theme, bool isDark) {
    final kabar = kabarPesanan(_selectedService, 'searching');
    final warna = AppTheme.warnaLayanan(_selectedService);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      margin: const EdgeInsets.all(16),
      decoration: _hiasPanel(isDark),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Kotak setinggi tetap: lingkaran radar membesar dua kali lipat, dan
          // tanpa kotak ini seluruh panel ikut naik-turun setiap denyut.
          SizedBox(
            height: 116,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: _radarController,
                  builder: (context, child) {
                    return Container(
                      width: 64 * (1 + _radarController.value),
                      height: 64 * (1 + _radarController.value),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: warna.withValues(alpha: 0.22 * (1 - _radarController.value)),
                      ),
                    );
                  },
                ),
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: warna,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: warna.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 5))],
                  ),
                  child: Icon(ikonLayanan(_selectedService), color: Colors.white, size: 30),
                ),
              ],
            ),
          ),
          Text(
            kabar.judul,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          // Tanpa "Estimasi waktu: 2 - 5 menit" — tidak ada yang menghitungnya.
          Text(
            kabar.keterangan,
            style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12.5, height: 1.4),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          _ringkasanBayar(isDark),
          const SizedBox(height: 8),
          // Dulu tombol ini hanya mengembalikan layar ke formulir dan
          // menghentikan polling — pesanannya tetap hidup di server, tetap
          // ditawarkan ke driver, dan penumpang tidak tahu apa-apa.
          TextButton(
            onPressed: _batalkanPesanan,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.errorColor,
              minimumSize: const Size(double.infinity, 44),
            ),
            child: const Text("Batalkan pesanan", style: TextStyle(fontWeight: FontWeight.w600)),
          )
        ],
      ),
    );
  }

  /// Driver sudah dekat titik berikutnya: titik jemput (atau warung) sebelum
  /// dijemput, tujuan sesudahnya. Hanya untuk kata-kata di layar — status
  /// pesanannya tetap milik server.
  bool get _driverDekat {
    final d = _driverLatLng;
    final titik = _orderStatus == 'picked_up' ? _destinationLatLng : _currentLatLng;
    if (d == null || titik == null) return false;
    return Geolocator.distanceBetween(d.latitude, d.longitude, titik.latitude, titik.longitude) <= jarakDekatMeter;
  }

  /// Plat ditulis besar seperti pelat nomor putih: itu yang dicocokkan
  /// penumpang dengan motor yang datang.
  Widget _platNomor() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.bgObsidianDark, width: 1.5),
        ),
        child: Text(
          _driverPlat.toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.8, color: AppTheme.bgObsidianDark),
        ),
      );

  Widget _buildDriverComingPanel(ThemeData theme, bool isDark) {
    final dekat = _driverDekat;
    final kabar = kabarPesanan(_selectedService, _orderStatus, dekat: dekat, warung: _merchantName);
    final warna = AppTheme.warnaStatus(_orderStatus);
    // Dari rute jalan sungguhan, bukan angka tetap; kosong selama posisi
    // driver atau rutenya belum terbaca.
    final eta = teksEstimasi(_ruteDriver, _driverLatLng);
    final ikonKabar = dekat
        ? Icons.near_me
        : _makanan && _orderStatus == 'accepted'
            ? Icons.storefront
            : _ikonKendaraan;

    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.all(16),
      decoration: _hiasPanel(isDark),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Kabar utama, paling besar: menjawab "pesananku lagi di mana?".
          // Warnanya ikut status — biru menuju jemput, nila sedang diantar.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: warna.withValues(alpha: isDark ? 0.22 : 0.08),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: warna, shape: BoxShape.circle),
                  child: Icon(ikonKabar, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kabar.judul,
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, height: 1.25, color: AppTheme.teksBerwarna(context, warna)),
                      ),
                      const SizedBox(height: 3),
                      Text(kabar.keterangan, style: TextStyle(fontSize: 12, height: 1.35, color: AppTheme.teksRedup(context))),
                      if (eta != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.bgObsidianDark : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.schedule, size: 14, color: AppTheme.teksBerwarna(context, warna)),
                              const SizedBox(width: 4),
                              Text(
                                _orderStatus == "picked_up" ? "Tiba di tujuan $eta" : "Tiba $eta",
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.teksBerwarna(context, warna)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Driver: nama, bintang, kendaraan, dan plat yang besar.
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.12),
                child: Text(
                  _driverName.isNotEmpty ? _driverName[0].toUpperCase() : 'D',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryBlue),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Nama dapat satu baris penuh; bintang turun ke baris
                    // kendaraan supaya nama tidak terpotong oleh plat.
                    Text(
                      _driverName.isEmpty ? 'Driver' : _driverName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    // Dulu "Honda Beat • KB 1234 XX" dan "4.9 (120)" tertulis
                    // mati untuk semua driver — penumpang bisa menunggu motor
                    // yang salah.
                    if (_driverUlasan > 0 || _driverKendaraan.isNotEmpty)
                      Row(
                        children: [
                          if (_driverUlasan > 0) ...[
                            Icon(Icons.star_rounded, color: Colors.amber.shade700, size: 15),
                            Text(
                              "${_driverRating.toStringAsFixed(1).replaceAll('.', ',')}${_driverKendaraan.isNotEmpty ? ' · ' : ''}",
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.teksRedup(context)),
                            ),
                          ],
                          Flexible(
                            child: Text(
                              _driverKendaraan,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (_driverPlat.isNotEmpty) ...[
                const SizedBox(width: 8),
                _platNomor(),
              ],
            ],
          ),
          const SizedBox(height: 14),

          // Action Buttons: Chat & Telepon. Chat yang utama: bisa dibaca
          // sambil jalan dan tidak perlu pulsa.
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
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
                  label: const Text("Chat driver"),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final uri = Uri.parse('tel:$_driverPhone');
                    if (_driverPhone.isNotEmpty && await canLaunchUrl(uri)) {
                      await launchUrl(uri);
                    } else if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Nomor driver belum bisa ditelepon. Coba lewat chat, ya.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.phone_outlined, size: 18),
                  label: const Text("Telepon"),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    side: BorderSide(color: Colors.green.shade600),
                    foregroundColor: Colors.green.shade700,
                    textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ringkasanBayar(isDark),
          const SizedBox(height: 16),

          // Tahapan mengikuti status pesanan yang sesungguhnya. Dulu keempatnya
          // berjam mati "10:20"–"10:23" dan tiga di antaranya selalu tercentang.
          // Jam per tahap tetap tidak ditulis: backend hanya menyimpan
          // updated_at terakhir, bukan jam tiap tahapan.
          const Text("Status pesanan", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 10),
          TimelinePesanan(layanan: _selectedService, status: _orderStatus),
          // Tombol "Simulasi Selesai (Dev)" dihapus: hanya driver yang boleh
          // menutup pesanan, dan backend memang menolak permintaan dari
          // penumpang — jadi tombol itu tidak pernah bisa berhasil.

          // Hanya sampai sebelum dijemput. Sesudah penumpang naik, drivernya
          // sudah bekerja, dan backend memang menolak pembatalannya.
          if (_orderStatus == "accepted") ...[
            const SizedBox(height: 6),
            TextButton(
              onPressed: _batalkanPesanan,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.errorColor,
                minimumSize: const Size(double.infinity, 40),
              ),
              child: const Text("Batalkan pesanan", style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }

  /// Isi pesanan (BohFood) dan uang yang harus disiapkan, terlihat sepanjang
  /// menunggu — dulu hanya untuk makanan; penumpang BohRide baru tahu jumlah
  /// tunainya di layar selesai. Pada BohFood driver menalangi makanan ke
  /// warung, jadi totalnya termasuk makanan, ongkir, dan biaya jasa.
  Widget _ringkasanBayar(bool isDark) {
    final total = _fare + _biayaJasa + _foodTotal;
    final warna = AppTheme.teksBerwarna(context, AppTheme.warnaLayanan(_selectedService));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warnaLayanan(_selectedService).withValues(alpha: isDark ? 0.16 : 0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_makanan)
          for (final it in _itemsMakanan)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${it['qty'] ?? 0}× ', style: const TextStyle(fontWeight: FontWeight.bold)),
                  TextSpan(text: (it['name'] ?? '').toString()),
                  if ((it['options'] as List?)?.isNotEmpty ?? false)
                    TextSpan(
                      text: ' · ${[for (final o in it['options'] as List) o['name']].join(', ')}',
                      style: TextStyle(color: AppTheme.teksRedup(context)),
                    ),
                ]),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (_makanan && _itemsMakanan.isNotEmpty) const Divider(height: 14),
          Row(
            children: [
              Icon(_bayarTunai ? Icons.payments_outlined : Icons.account_balance_wallet_outlined, size: 18, color: warna),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _bayarTunai ? 'Siapkan uang tunai untuk driver' : 'Dipotong dari saldo BohPay',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              // Pesanan berjalan yang baru dibuka belum membawa angka selama
              // sekejap; "Rp 0" di situ menyesatkan.
              if (total > 0) Text(rupiah(total), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: warna)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessScreen(ThemeData theme, bool isDark) {
    final kabar = kabarPesanan(_selectedService, 'completed');
    // Rincian yang menjumlah tepat ke total. Dulu baris makanan hanya menyebut
    // makanan + ongkir, sehingga biaya jasa hilang dan angkanya tidak cocok.
    final rincian = [
      if (_foodTotal > 0) 'Makanan ${rupiah(_foodTotal)}',
      '${_foodTotal > 0 ? 'Ongkir' : 'Ongkos'} ${rupiah(_fare)}',
      if (_biayaJasa > 0) 'Biaya jasa ${rupiah(_biayaJasa)}',
    ].join(' · ');
    const labelBintang = ['', 'Kecewa', 'Kurang', 'Biasa saja', 'Bagus', 'Mantap!'];

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                kabar.judul,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                kabar.keterangan,
                style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 14, height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Total dan cara bayarnya. Pesanan tunai diingatkan sekali lagi:
              // driver menekan selesai, uangnya belum tentu sudah berpindah.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.cardObsidianDark : Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Total bayar", style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13)),
                        Text(
                          rupiah(_fare + _biayaJasa + _foodTotal),
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: AppTheme.primaryBlue),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(rincian, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 11)),
                    ),
                    const Divider(height: 22),
                    Row(
                      children: [
                        Icon(
                          _bayarTunai ? Icons.payments_outlined : Icons.account_balance_wallet_outlined,
                          size: 18,
                          color: AppTheme.teksBerwarna(context, _bayarTunai ? AppTheme.warnaStatus('pending') : AppTheme.warnaStatus('completed')),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _bayarTunai ? 'Bayar tunai ke driver, ya' : 'Sudah dipotong dari saldo BohPay',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Bukti serah-terima dari driver, kalau ada.
              if (_receivedBy.isNotEmpty || _deliveryPhotoUrl.isNotEmpty) ...[
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text("Bukti serah terima", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.teksRedup(context))),
                ),
                const SizedBox(height: 6),
                if (_receivedBy.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text("Diterima oleh $_receivedBy", style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                if (_deliveryPhotoUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: LayoutBuilder(
                      builder: (context, batas) => Image.network(
                        '${ApiService().baseUrl}$_deliveryPhotoUrl',
                        height: 160,
                        fit: BoxFit.cover,
                        cacheWidth: lebarDekode(context, batas.copyWith(maxHeight: 160)),
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 28),

              // Interactive 5 star ratings
              Text(
                _driverName.isEmpty ? "Gimana pengalamanmu?" : "Gimana pengalamanmu bareng $_driverName?",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  final starIndex = index + 1;
                  return IconButton(
                    tooltip: '$starIndex bintang',
                    onPressed: () {
                      setState(() {
                        _ratingStars = starIndex;
                      });
                    },
                    icon: Icon(
                      starIndex <= _ratingStars ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: Colors.amber.shade600,
                      size: 40,
                    ),
                  );
                }),
              ),
              // Kata di bawah bintang: angka saja tidak bilang apa artinya.
              Text(
                labelBintang[_ratingStars],
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Colors.amber.shade800),
              ),
              const SizedBox(height: 16),

              // Review input
              TextFormField(
                controller: _reviewController,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: "Ceritakan pengalamanmu (opsional)",
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _kirimPenilaian,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text("Kirim penilaian"),
              ),
              // Dulu satu-satunya jalan keluar adalah mengirim bintang 5 bawaan.
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text("Lewati", style: TextStyle(color: AppTheme.teksRedup(context))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
