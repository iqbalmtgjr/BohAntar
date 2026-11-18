import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart' show Printing;
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/models/food.dart' show urlGambar, MenuMakanan, Warung;
import 'package:mobile/screens/cari_screen.dart';
import 'package:mobile/screens/chat_screen.dart';
import 'package:mobile/screens/daftar_chat_screen.dart';
import 'package:mobile/screens/food_menu_screen.dart';
import 'package:mobile/screens/food_merchants_screen.dart';
import 'package:mobile/screens/login_screen.dart';
import 'package:mobile/screens/order_ride_screen.dart';
import 'package:mobile/screens/pindai_qr_screen.dart';
import 'package:mobile/screens/rental_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/chat_service.dart';
import 'package:mobile/services/maps_service.dart';
import 'package:mobile/services/notifikasi_service.dart';
import 'package:mobile/status_pesanan.dart';
import 'package:mobile/tarif.dart' show keteranganKelas;
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/banner_beranda.dart';
import 'package:mobile/widgets/dialog_alasan.dart';
import 'package:mobile/widgets/food_widgets.dart' show GambarJaringan, PesanKosong, Pil, lebarDekode;
import 'package:mobile/widgets/kaca.dart';
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

  // Mode terakhir yang dipakai akun driver di HP ini. Perannya di server tetap
  // driver; mode penumpang hanya tampilan, karena token driver juga diterima
  // semua rute penumpang.
  static String _kunciModePenumpang(String phone) => 'mode_penumpang:$phone';

  /// Layar yang dibuka saat sesi dipulihkan: akun driver yang terakhir
  /// beralih ke mode penumpang kembali ke mode penumpang.
  static Future<String> peranTampil(String peranAkun, String phone) async {
    if (peranAkun != 'driver') return peranAkun;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(_kunciModePenumpang(phone)) ?? false) ? 'rider' : 'driver';
  }

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with TickerProviderStateMixin {
  bool _isOnline = false;
  bool _hasIncomingOrder = false;
  
  // Dynamic User State
  double _walletBalance = 0.0;
  // Saldo 0 di atas hanya nilai awal sebelum profil datang dari server; tanpa
  // penanda ini kartu "saldo menipis" berkedip beberapa detik setiap masuk.
  bool _saldoDimuat = false;
  String _userName = "";
  String _userBadge = "Silver";
  String _kendaraan = 'motor'; // driver: 'motor' / 'mobil', dari profil
  String _fotoWajah = ''; // driver: selfie yang dilihat penumpang, /uploads/...
  // Peran akun di server, bisa beda dari widget.role: akun driver yang sedang
  // di mode penumpang. Penentu munculnya tombol beralih mode.
  String _peranAkun = '';
  // Akun driver yang disuspend admin (users.is_driver_active = 0) dan alasannya.
  bool _driverDinonaktifkan = false;
  String _alasanNonaktif = '';
  Map<String, String> _userAddresses = {};
  Map<String, dynamic>? _riderActiveOrder;

  // Active driver states
  Timer? _driverPollTimer;
  Timer? _riderActiveOrderTimer;
  // Lencana Chat: notifikasi yang datang saat aplikasi di latar tidak
  // memanggil apa pun, jadi daftarnya dibaca ulang tiap kembali ke depan.
  AppLifecycleListener? _pantauDepan;
  Map<String, dynamic>? _currentIncomingOrder;
  Map<String, dynamic>? _acceptedOrder;
  // Pesanan yang sudah ditolak driver ini, supaya tidak ditawarkan lagi tiap
  // tiga detik. Cukup bertahan selama sesi — pesanan yang benar-benar dilewatkan
  // semua driver akan kedaluwarsa sendiri di server.
  final Set<String> _pesananDitolak = {};
  bool _menerima = false; // permintaan Terima sedang di jalan

  // Driver map states
  // Null sampai peta tergambar: pesanan bisa masuk sebelum layar petanya
  // terpasang, dan gerakan kamera sebelum itu cukup dilewati.
  GoogleMapController? _driverMapController;
  // Titik awal peta sebelum GPS terbaca. Begitu _mulaiPantauPosisi() jalan,
  // isinya selalu posisi sungguhan.
  LatLng _driverLatLng = const LatLng(0.0785, 111.4940); // Default: pusat kota Sintang (Jl. A. Yani)
  // Sebelum GPS terbaca, _driverLatLng cuma titik awal peta. Penanda motor
  // tidak digambar di sana: lebih baik tidak ada daripada menunjuk tempat lain.
  bool _posisiTerbaca = false;
  StreamSubscription<Position>? _posisiSub;

  void _pakaiPosisi(LatLng titik) {
    final pertama = !_posisiTerbaca;
    setState(() {
      _driverLatLng = titik;
      _posisiTerbaca = true;
    });
    // Kamera menyusul driver sekali saja, saat posisinya pertama terbaca.
    // Sesudah itu driver bebas menggeser peta; pesanan memindahkannya sendiri.
    if (pertama && _acceptedOrder == null && !_hasIncomingOrder) _pindahPeta(titik, 15);
  }

  /// Peta driver dibuka di posisinya sendiri, online atau tidak. Posisi
  /// terakhir yang diingat HP muncul seketika; GPS segar menyusul.
  Future<void> _posisiAwalDriver() async {
    try {
      var izin = await Geolocator.checkPermission();
      // Instalasi baru belum pernah ditanya; tanpa ini peta driver diam di
      // tengah kota sampai tombol Online ditekan.
      if (izin == LocationPermission.denied) izin = await Geolocator.requestPermission();
      if (izin == LocationPermission.denied || izin == LocationPermission.deniedForever) return;
      final terakhir = await Geolocator.getLastKnownPosition();
      if (terakhir != null && mounted) _pakaiPosisi(LatLng(terakhir.latitude, terakhir.longitude));
      final kini = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      if (mounted) _pakaiPosisi(LatLng(kini.latitude, kini.longitude));
    } catch (e) {
      debugPrint('Posisi awal driver gagal: $e');
    }
  }
  // Titik saat rute terakhir digambar, untuk menahan panggilan layanan rute.
  LatLng? _titikRuteTerakhir;

  void _pindahPeta(LatLng titik, double zoom) {
    _driverMapController?.moveCamera(CameraUpdate.newLatLngZoom(titik, zoom));
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
  List<LatLng> _driverRoutePoints = [];         // Driver -> jemput, sesudah dijemput jemput -> tujuan (biru)
  List<LatLng> _dropoffRoutePoints = [];        // Pickup -> Dropoff (hijau), hanya sebelum dijemput
  Rute? _ruteAktif; // sumber estimasi waktu di panel pesanan

  bool get _sudahDijemput => _acceptedOrder?['status'] == 'picked_up';
  LatLng? get _tujuanAktif => _sudahDijemput ? _orderDropoffLatLng : _orderPickupLatLng;

  // Panel pesanan berjalan diciutkan jadi satu bar supaya peta terlihat, sama
  // dengan layar penumpang. Pesanan berikutnya selalu mulai dengan panel penuh.
  // Kartu pesanan masuk memakai penanda yang sama: rinciannya disembunyikan,
  // tombol Terima/Lewatkan tetap ada karena hitung mundurnya terus berjalan.
  bool _panelKecil = false;

  String _arahBerikut(Map<String, dynamic>? o) => _sudahDijemput
      ? 'Ke tujuan'
      : _makanan(o)
          ? 'Ke warung'
          : _kirimBarang(o)
              ? 'Ke titik ambil'
              : 'Ke penumpang';

  bool _menjawabBatal = false;
  // Polling yang berangkat sebelum jawaban dikirim masih membawa pengajuannya;
  // tanpa penanda ini kotak Setujui/Tolak muncul lagi sesaat setelah dijawab.
  DateTime _batalDijawabPada = DateTime(0);

  /// Jawaban atas pengajuan batal BohFood. Driver yang tahu apakah makanannya
  /// sudah dibeli; menolak wajib beralasan supaya pemesan mengerti.
  Future<void> _jawabBatal(bool setuju) async {
    final id = _acceptedOrder?['id'];
    if (id == null) return;
    var alasan = '';
    if (!setuju) {
      final a = await pilihAlasan(
        context,
        judul: 'Tolak pembatalan?',
        isi: 'Pesanan tetap berjalan dan pemesan diberi tahu alasannya.',
        pilihan: const ['Makanan sudah dibeli', 'Makanan sudah dimasak warung', 'Sudah dekat lokasi antar', alasanLainnya],
        tombol: 'Tolak',
        batal: 'Kembali',
      );
      if (a == null || !mounted) return;
      alasan = a;
    }
    setState(() => _menjawabBatal = true);
    _batalDijawabPada = DateTime.now();
    try {
      await ApiService().jawabBatal(id, setuju: setuju, alasan: alasan);
      if (!mounted) return;
      if (setuju) {
        setState(_tutupPesananDriver);
        _beriTahu('Pesanan dibatalkan atas permintaan pemesan.');
        _fetchUserProfile();
      } else {
        setState(() => _acceptedOrder!['minta_batal_at'] = '');
        _beriTahu('Pembatalan ditolak. Lanjutkan pengantaran.');
      }
    } catch (e) {
      if (mounted) _beriTahu(pesanGalat(e));
    } finally {
      if (mounted) setState(() => _menjawabBatal = false);
    }
  }

  Widget _kotakMintaBatal() {
    final alasan = (_acceptedOrder!['alasan_batal'] ?? '').toString();
    final merah = AppTheme.teksBerwarna(context, AppTheme.errorColor);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.errorColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.errorColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pemesan minta pesanan dibatalkan', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: merah)),
          if (alasan.isNotEmpty) Text('Alasan: $alasan', style: TextStyle(fontSize: 12.5, color: AppTheme.teksRedup(context))),
          const SizedBox(height: 4),
          Text('Setujui kalau makanannya belum dibeli. Kalau sudah dibayar di warung, tolak.',
              style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context))),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _menjawabBatal ? null : () => _jawabBatal(false),
                  child: const Text('Tolak', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: _menjawabBatal ? null : () => _jawabBatal(true),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor, foregroundColor: Colors.white),
                  child: const Text('Setujui batal'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Usap ke bawah menciutkan, ke atas membuka.
  void _usapPanelDriver(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() > 150) setState(() => _panelKecil = v > 0);
  }

  // Semua jalan keluar pesanan (selesai, lepas) membersihkan peta lewat sini,
  // supaya pin dan garis pesanan lama tidak tertinggal.
  void _tutupPesananDriver() {
    _panelKecil = false;
    _acceptedOrder = null;
    _driverRoutePoints = [];
    _dropoffRoutePoints = [];
    _ruteAktif = null;
    _orderPickupLatLng = null;
    _orderDropoffLatLng = null;
  }

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
  // Halaman lanjutan riwayat pendapatan, dimuat saat digulir ke ujung.
  List<dynamic> _pendapatanLama = [];
  int _pendapatanHalaman = 1;
  bool _pendapatanAdaLagi = false;
  bool _pendapatanMemuat = false;

  // Riwayat untuk tab Aktivitas. Diisi oleh polling yang memang sudah berjalan
  // tiap 4 detik untuk mencari pesanan aktif, jadi tab ini tidak menembak
  // permintaan sendiri. _riwayatSidik menyimpan sidik jari daftar terakhir
  // (id:status tiap baris) supaya setState hanya dipanggil ketika isinya benar-
  // benar berubah — tanpa itu daftarnya digambar ulang tiap 4 detik dan
  // kelihatan berkedip terus.
  //
  // Polling hanya menarik halaman pertama (20 terbaru); halaman yang lebih
  // lama dimuat saat tab Aktivitas digulir ke ujung, lalu disimpan di bawah
  // halaman pertama.
  List<dynamic> _riwayatPesanan = [];
  String _riwayatSidik = '';
  bool _riwayatSudahDimuat = false;
  int _riwayatHalaman = 1;
  bool _riwayatAdaLagi = false;
  bool _riwayatMemuatLagi = false;
  bool _riwayatGagalLagi = false;
  DateTime _riwayatDitarik = DateTime(0);

  @override
  void initState() {
    super.initState();
    _fetchUserProfile();
    SharedPreferences.getInstance().then(
        (p) => p.setBool(DashboardScreen._kunciModePenumpang(widget.phone), widget.role == 'rider'));
    if (widget.role == 'rider') {
      // Langsung sekali, tidak menunggu tik pertama polling: dulu kartu
      // pesanan berjalan baru muncul 4 detik setelah beranda terbuka.
      _fetchRiderActiveOrder();
      _startRiderActiveOrderPolling();
      _muatBanner();
      _muatMenuLaris();
      _muatVoucher();
      segarkanDaftarChat();
      _pantauDepan = AppLifecycleListener(onResume: () {
        segarkanDaftarChat();
        _fetchRiderActiveOrder(); // polling berhenti selama di latar belakang
      });
    }
    
    // Radar pulse animation
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    muatIkonKendaraan().then((_) {
      if (mounted) setState(() {});
    });

    // Countdown animation for incoming order
    _countdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    );

    // Setelah kedua controller siap: pemulihan memakai keduanya.
    if (widget.role != 'rider') {
      _pulihkanPesananBerjalan();
      _posisiAwalDriver();
      _lanjutkanOnline();
    }
  }

  static const _kunciOnline = 'driver_online';

  /// Driver yang terakhir meninggalkan aplikasi dalam keadaan online langsung
  /// online lagi saat membukanya. Tanpa ini, driver yang membuka aplikasi dari
  /// notifikasi orderan harus menekan saklar dulu, dan orderannya keburu lewat.
  Future<void> _lanjutkanOnline() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getBool(_kunciOnline) ?? false) && mounted && !_isOnline) _toggleOnline(true);
  }

  @override
  void dispose() {
    _radarController.dispose();
    _countdownController.dispose();
    _countdownTimer?.cancel();
    _driverPollTimer?.cancel();
    _riderActiveOrderTimer?.cancel();
    _pantauDepan?.dispose();
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
          _saldoDimuat = true;
          _userName = user['name'] ?? '';
          _userBadge = user['badge'] ?? 'Silver';
          _kendaraan = response['kendaraan'] ?? 'motor';
          _fotoWajah = (response['foto_wajah'] ?? '').toString();
          _peranAkun = user['role'] ?? '';
          _driverDinonaktifkan = user['role'] == 'driver' && user['is_driver_active'] == false;
          _alasanNonaktif = (response['alasan_nonaktif'] ?? '').toString();
          if (user['addresses'] != null) {
            _userAddresses = Map<String, String>.from(user['addresses']);
          }
        });
        // Driver yang disuspend tidak dibiarkan online menunggu orderan yang
        // tak akan datang (server sudah tidak mengirimnya). Pesanan yang sedang
        // berjalan tetap boleh diselesaikan.
        if (_driverDinonaktifkan && _isOnline && _acceptedOrder == null && widget.role != 'rider') {
          _toggleOnline(false);
        }
      }
    } catch (e) {
      debugPrint("Error fetching profile: $e");
      setState(() {
      });
    }
  }

  void _startRiderActiveOrderPolling() {
    _riderActiveOrderTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      // Di latar belakang tidak ada yang melihat (onResume menyegarkan begitu
      // dibuka lagi). Tanpa pesanan berjalan, riwayat hanya berubah oleh
      // pemakai sendiri — yang sudah menyegarkan saat kembali ke beranda —
      // jadi cukup sesekali, untuk berjaga kalau ada pesanan dari HP lain.
      if (!mounted || !_diDepan) return;
      // Layar lain di atas beranda (lacak pesanan punya polling sendiri, chat
      // punya WebSocket): beranda menyusul saat kembali.
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      if (_riderActiveOrder == null && DateTime.now().difference(_riwayatDitarik) < const Duration(seconds: 30)) return;
      _fetchRiderActiveOrder();
    });
  }

  Future<void> _fetchRiderActiveOrder() async {
    _riwayatDitarik = DateTime.now();
    try {
      final response = await ApiService().getOrders();
      if (response['status'] == 'success') {
        // Halaman pertama = 20 pesanan terbaru, jadi semua yang sudah dimuat
        // dari halaman lanjutan pasti lebih lama: ditaruh di bawahnya.
        final List terbaru = response['orders'] ?? [];
        final idTerbaru = {for (final o in terbaru) o['id']};
        final ordersList = [...terbaru, ..._riwayatPesanan.where((o) => !idTerbaru.contains(o['id']))];
        if (_riwayatHalaman == 1) _riwayatAdaLagi = response['ada_lagi'] == true;
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

  /// Halaman riwayat berikutnya, saat tab Aktivitas digulir mendekati ujung.
  Future<void> _muatRiwayatLagi() async {
    if (_riwayatMemuatLagi || !_riwayatAdaLagi) return;
    setState(() {
      _riwayatMemuatLagi = true;
      _riwayatGagalLagi = false;
    });
    try {
      final r = await ApiService().getOrders(page: _riwayatHalaman + 1);
      final List lama = r['orders'] ?? [];
      // Pesanan baru menggeser halaman, jadi bisa ada yang sudah tampil.
      final ada = {for (final o in _riwayatPesanan) o['id']};
      if (!mounted) return;
      setState(() {
        _riwayatPesanan = [..._riwayatPesanan, ...lama.where((o) => !ada.contains(o['id']))];
        _riwayatHalaman++;
        _riwayatAdaLagi = r['ada_lagi'] == true;
        _riwayatMemuatLagi = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _riwayatMemuatLagi = false;
          _riwayatGagalLagi = true;
        });
      }
    }
  }

  /// Nominal terkecil yang diterima server. Disamakan di sini supaya penolakan
  /// terjadi sebelum perjalanan bolak-balik ke server, bukan sesudahnya.
  static const double _topUpMinimal = 10000;

  void _showTopUpDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Isi saldo komisi"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: "Mau isi berapa? Min. 10.000",
                  prefixText: "Rp ",
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [20000, 50000, 100000]
                    .map((n) => ActionChip(
                          label: Text(_rupiah(n.toDouble())),
                          onPressed: () => controller.text = n.toString(),
                        ))
                    .toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () {
                final amount = double.tryParse(controller.text.trim());
                if (amount == null || amount < _topUpMinimal) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(content: Text("Minimal isi ${_rupiah(_topUpMinimal)}, ya")),
                  );
                  return;
                }
                Navigator.pop(dialogContext);
                _mintaQRTopUp(amount);
              },
              style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text("Lanjut bayar"),
            ),
          ],
        );
      },
    );
  }

  /// Mengajukan top up ke server lalu membuka halaman petunjuk transfer.
  ///
  /// Saldo tidak ditambah di sini dan tidak boleh ditambah di sini: yang
  /// menambahkannya adalah admin yang menyetujui di dashboard setelah
  /// transfernya masuk. Aplikasi hanya membaca ulang saldo sesudahnya.
  Future<void> _mintaQRTopUp(double amount) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Menyiapkan halaman bayar…'), duration: Duration(seconds: 2)),
    );
    try {
      final res = await ApiService().topUp(amount);
      final url = res['payment_url'] as String?;
      if (url == null || url.isEmpty) {
        throw Exception('Halaman bayar belum tersedia. Coba lagi sebentar, ya.');
      }
      if (!mounted) return;
      final terbuka = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (!terbuka) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Halaman bayar tidak bisa dibuka. Coba lagi, ya.')),
        );
        return;
      }
      // Server menambah kode unik ke nominal; yang harus dibayar angka server.
      _tungguPembayaran((res['amount'] as num?)?.toDouble() ?? amount);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(pesanGalat(e))),
      );
    }
  }

  /// Layar tunggu setelah halaman pembayaran dibuka.
  ///
  /// Tombolnya membaca ulang saldo dari server, bukan menghitung sendiri:
  /// pembayaran bisa saja belum lunas, dan angka yang benar cuma ada di
  /// database. Tanpa tombol ini driver harus menutup dan membuka aplikasi
  /// untuk melihat saldonya bertambah.
  void _tungguPembayaran(double amount) {
    final saldoSebelum = _walletBalance;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Menunggu pembayaran'),
          content: Text(
            'Bayar ${_rupiah(amount)} lewat QRIS di halaman bayar. Saldo masuk setelah admin mengecek — ketuk "Cek saldo" untuk melihat.',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Nanti saja'),
            ),
            ElevatedButton(
              onPressed: () async {
                // Diambil sebelum await: sesudahnya dialognya bisa saja sudah
                // ditutup, dan mengambil Navigator dari context yang mati itu
                // persis penyebab crash yang dijaga lint use_build_context.
                final navigator = Navigator.of(dialogContext);
                final messenger = ScaffoldMessenger.of(context);
                await _fetchUserProfile();
                if (!mounted) return;
                final naik = _walletBalance > saldoSebelum;
                navigator.pop();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(naik
                        ? 'Saldo masuk! Sekarang ${_rupiah(_walletBalance)}.'
                        : 'Belum disetujui admin. Cek lagi sebentar, ya.'),
                    backgroundColor: naik ? Colors.green : null,
                  ),
                );
              },
              child: const Text('Cek saldo'),
            ),
          ],
        );
      },
    );
  }

  void _toggleOnline(bool online) {
    if (online && _driverDinonaktifkan) {
      _beriTahu('Akun drivermu sedang dinonaktifkan admin. Hubungi admin BohAntar, ya.');
      return;
    }
    SharedPreferences.getInstance().then((p) => p.setBool(_kunciOnline, online));
    setState(() {
      _isOnline = online;
      if (_isOnline) {
        _radarController.repeat();
        _startDriverPolling();
      } else {
        _radarController.stop();
        // Polling tetap hidup selama ada pesanan berjalan, supaya batalnya terdengar.
        if (_acceptedOrder == null) _stopDriverPolling();
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
    // menerima orderan. Kecuali masih ada pesanan berjalan: penumpangnya tetap
    // menatap peta, dan dulu penanda driver membeku di sana. Pelacakannya
    // dihentikan polling begitu pesanan itu tutup (_startDriverPolling).
    if (online) {
      _mulaiPantauPosisi();
    } else if (_acceptedOrder == null) {
      _hentikanPantauPosisi();
      // Server menebak siapa yang siaga dari waktu posisi terakhir, jadi berhenti
      // mengirim posisi saja tidak cukup: tanpa kabar ini, driver yang sudah
      // pulang masih dibangunkan orderan sampai sepuluh menit sesudahnya.
      ApiService().setDriverOffline();
    }
  }

  void _startDriverPolling() {
    _driverPollTimer?.cancel();
    _driverPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      // Offline yang ditekan di tengah pesanan baru berlaku setelah pesanannya
      // selesai, lepas, atau batal — semua jalan keluar itu lewat sini.
      if (!_isOnline && _acceptedOrder == null) {
        _stopDriverPolling();
        _hentikanPantauPosisi();
        ApiService().setDriverOffline();
        return;
      }
      if (_isOnline) _denyutPosisi();
      // Pesanan berjalan dipantau walau driver offline: pembatalannya tetap
      // harus sampai.
      if (_acceptedOrder != null) {
        _checkAcceptedOrderStatus();
      } else {
        _cariOrderan();
      }
    });
  }

  // Aplikasi sedang terlihat. Notification shade yang ditarik (inactive) masih
  // dihitung terlihat.
  bool get _diDepan {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
  }

  // Posisi dikirim tiap 30 m bergerak, jadi driver yang menunggu diam di
  // pangkalan tidak mengirim apa-apa. Server berhenti menganggapnya siaga
  // sepuluh menit kemudian, dan notifikasi orderan berhenti datang. Denyut ini
  // mengirim ulang posisi terakhir dari GPS (bukan posisi ingatan HP).
  DateTime? _posisiTerkirim;
  void _denyutPosisi() {
    final terakhir = _posisiTerkirim;
    if (terakhir == null || DateTime.now().difference(terakhir) < const Duration(minutes: 3)) return;
    _posisiTerkirim = DateTime.now();
    ApiService().sendDriverLocation(_driverLatLng.latitude, _driverLatLng.longitude);
  }

  Future<void> _cariOrderan() async {
      if (!_isOnline) return;
      // Kartu tawaran tidak dimunculkan selagi aplikasi di latar belakang: hitung
      // mundurnya habis tanpa pernah dilihat, dan orderannya hilang tepat saat
      // driver membuka aplikasi dari notifikasinya. Begitu dibuka, polling
      // berikutnya menampilkannya dengan hitung mundur penuh.
      if (!_hasIncomingOrder && !_diDepan) return;

      try {
        final response = await ApiService().getActiveOrders();
        if (response['status'] == 'success') {
          final List semua = response['orders'] as List? ?? [];
          // Kartu tawaran yang pesanannya sudah batal atau diambil driver lain
          // ditutup, bukan dibiarkan menghitung mundur sampai habis.
          if (_hasIncomingOrder) {
            final id = _currentIncomingOrder?['id'];
            // Pesanan yang sedang kita terima juga lenyap dari daftar ini.
            if (!_menerima && !semua.any((o) => o['id'] == id) && mounted) {
              _rejectOrder();
              _beriTahu('Pesanan sudah tidak tersedia.');
            }
            return;
          }
          final List ordersList = semua
              .where((o) => !_pesananDitolak.contains(o['id']))
              .toList();
          if (ordersList.isNotEmpty) {
            final order = ordersList.first;
            setState(() {
              _currentIncomingOrder = order;
              _hasIncomingOrder = true;
              _panelKecil = false;
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
        _rejectOrder(dilihat: _diDepan);
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
      final dimintaPada = DateTime.now();
      final response = await ApiService().getOrderStatus(_acceptedOrder!['id']);
      if (response['status'] == 'success') {
        final order = response['order'];
        // Nomor kasir Kasvo lahir beberapa detik setelah driver menerima.
        final kasir = order['kasvo_pesanan_id'];
        if (kasir != null && kasir != _acceptedOrder!['kasvo_pesanan_id'] && mounted) {
          setState(() => _acceptedOrder!['kasvo_pesanan_id'] = kasir);
        }
        // Pengajuan batal BohFood dari pemesan: kotak Setujui/Tolak di panel.
        final minta = (order['minta_batal_at'] ?? '').toString();
        if (dimintaPada.isAfter(_batalDijawabPada) && minta != (_acceptedOrder!['minta_batal_at'] ?? '').toString() && mounted) {
          setState(() {
            _acceptedOrder!['minta_batal_at'] = minta;
            _acceptedOrder!['alasan_batal'] = order['alasan_batal'];
            if (minta.isNotEmpty) _panelKecil = false; // pengajuan baru harus terlihat
          });
        }
        if (order['status'] == 'completed') {
          setState(() {
            _tutupPesananDriver();
            _hasIncomingOrder = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            // Dulu "Pendapatan telah ditambahkan ke dompet Anda" — keliru: semua
            // pesanan tunai, jadi yang terjadi justru komisi dipotong dari saldo.
            const SnackBar(
              content: Text('Perjalanan selesai, terima kasih! Rincian setorannya ada di tab Pendapatan.'),
              backgroundColor: Colors.teal,
            ),
          );
          _fetchUserProfile();
        } else if (order['status'] == 'cancelled') {
          // Server sudah mengirim push, tapi push bisa telat atau tidak
          // diizinkan. Tanpa ini kartu pesanannya tetap terpampang dan driver
          // menunggu di titik jemput untuk orang yang tidak akan datang.
          setState(_tutupPesananDriver);
          final alasan = (order['alasan_batal'] ?? '').toString();
          _beriTahu(alasan.isEmpty
              ? 'Pesanan dibatalkan. Tidak perlu dilanjutkan.'
              : 'Pesanan dibatalkan pemesan: $alasan. Tidak perlu dilanjutkan.');
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
    Rute? hasil;
    try {
      hasil = await MapsService().rute(start, end);
    } catch (e) {
      debugPrint("Driver routing error: $e");
    }
    // Jawaban telat untuk tujuan lama — rute ke titik jemput yang baru tiba
    // sesudah penumpang naik — jangan menimpa rute ke tujuan. Kalau menimpa,
    // garisnya jadi "driver ke tempat ia berdiri" dan tampak hilang.
    if (!mounted || end != _tujuanAktif) return;
    final ada = hasil != null && hasil.titik.isNotEmpty;
    setState(() {
      _driverRoutePoints = ada ? hasil!.titik : [start, end];
      _ruteAktif = ada ? hasil : null;
    });
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
      //
      // Sesudah dijemput, garisnya perjalanan penumpang: titik jemput ke tujuan,
      // bukan posisi GPS driver. Ponsel driver yang belum sampai di titik jemput
      // (atau GPS yang meleset) membuat garis "driver ke tujuan" pendek sekali
      // dan tertutup ikon. Begitu driver bergerak 2 km dari titik jemput,
      // _mulaiPantauPosisi menggambar ulang dari posisinya.
      final asal = _sudahDijemput ? pickupLatLng : _driverLatLng;
      setState(() {
        _orderPickupLatLng = pickupLatLng;
        _orderDropoffLatLng = dropoffLatLng;
        // Pesanan baru: rutenya digambar sekali tanpa menunggu 2 km pertama.
        _titikRuteTerakhir = _sudahDijemput ? pickupLatLng : null;
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

      // Biru: driver -> jemput, atau jemput -> tujuan begitu sudah dijemput.
      final tujuan = _tujuanAktif;
      if (tujuan != null) _fetchDriverRoute(asal, tujuan);

      // Hijau: gambaran jemput -> tujuan, hanya selagi belum dijemput.
      if (dropoffLatLng != null && !_sudahDijemput) {
        _fetchDropoffRoute(pickupLatLng, dropoffLatLng);
      } else {
        setState(() => _dropoffRoutePoints = []);
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
  // baterai maupun kuota. distanceFilter 15 m: pada 30 km/jam satu posisi tiap
  // ±2 detik, seirama polling penumpang, sehingga penanda di peta penumpang
  // bergeser terus alih-alih melompat tiap blok (dulu 30 m).
  //
  // Tetap jalan saat layar terkunci tanpa izin lokasi latar belakang: stream ini
  // dinyalakan selagi aplikasi terbuka dan memakai foreground service bertipe
  // location (lihat AndroidManifest.xml), yang oleh Android dibiarkan terus
  // menerima GPS dengan izin "saat aplikasi digunakan" saja.
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
        distanceFilter: 15,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'BohAntar aktif',
          notificationText: 'Berbagi posisi supaya penumpang bisa melihatmu.',
          notificationChannelName: 'Status driver',
          enableWakeLock: true,
          setOngoing: true,
        ),
      ),
    ).listen((posisi) {
      if (!mounted) return;
      final titik = LatLng(posisi.latitude, posisi.longitude);
      _pakaiPosisi(titik);

      // Penumpang membaca posisi ini lewat status pesanan. Murah: hanya menulis
      // satu baris di database sendiri.
      ApiService().sendDriverLocation(titik.latitude, titik.longitude);
      _posisiTerkirim = DateTime.now();

      // Rute digambar ulang jauh lebih jarang daripada posisi diperbarui.
      //
      // Setiap penggambaran adalah satu panggilan ke layanan rute umum. Kalau
      // dipanggil pada tiap pembaruan posisi (tiap 30 m), satu perjalanan 5 km
      // jadi sekitar 160 panggilan. Dengan ambang 2 km, jumlahnya turun ke dua
      // atau tiga — dan garis di peta tetap terlihat mengikuti driver karena
      // penandanya sendiri bergerak tiap 30 m.
      final tujuan = _tujuanAktif;
      if (_acceptedOrder != null && tujuan != null && _perluGambarUlangRute(titik)) {
        _titikRuteTerakhir = titik;
        _fetchDriverRoute(titik, tujuan);
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
      _beriTahu('GPS mati. Nyalakan lokasi supaya penumpang bisa melihat posisimu.');
      return false;
    }
    var izin = await Geolocator.checkPermission();
    if (izin == LocationPermission.denied) {
      izin = await Geolocator.requestPermission();
    }
    if (izin == LocationPermission.denied || izin == LocationPermission.deniedForever) {
      _beriTahu('Izin lokasi ditolak. BohAntar tidak bisa mengirim posisimu ke penumpang.');
      return false;
    }
    return true;
  }

  /// Kuitansi untuk klaim ke bendahara: kirim sebagai PDF (bisa dicetak),
  /// sebagai gambar (praktis dilihat di WhatsApp), atau simpan ke galeri.
  void _pilihKuitansi(String orderId) {
    Widget pilihan(BuildContext lembar, IconData ikon, String judul, String keterangan, String jenis) => ListTile(
          leading: Icon(ikon, color: AppTheme.primaryBlue),
          title: Text(judul, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(keterangan),
          onTap: () {
            Navigator.pop(lembar);
            _kirimKuitansi(orderId, jenis);
          },
        );
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (lembar) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Kuitansi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            const SizedBox(height: 8),
            pilihan(lembar, Icons.picture_as_pdf_outlined, 'Kirim PDF', 'Untuk klaim ke bendahara, bisa dicetak', 'pdf'),
            pilihan(lembar, Icons.image_outlined, 'Kirim gambar', 'Praktis untuk dilihat di WhatsApp', 'gambar'),
            pilihan(lembar, Icons.download_outlined, 'Unduh ke galeri', 'Simpan gambar kuitansi di HP', 'galeri'),
          ],
        ),
      ),
    );
  }

  /// jenis: 'pdf' / 'gambar' = menu bagikan (WhatsApp dll.), 'galeri' = simpan
  /// gambarnya ke album BohAntar di galeri HP.
  Future<void> _kirimKuitansi(String orderId, String jenis) async {
    try {
      // Izin hanya ditanyakan di Android 10 ke bawah; Android 11+ langsung boleh.
      if (jenis == 'galeri' && !await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) {
        throw Exception('Izinkan BohAntar menyimpan ke galeri dulu, ya.');
      }
      final k = await ApiService().kuitansi(orderId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Menyiapkan kuitansi…'), duration: Duration(seconds: 2)),
        );
      }
      final pdf = await ApiService().unduhKuitansi(k.url);
      final nama = 'Kuitansi-${k.nomor}';
      final teks = 'Kuitansi BohAntar No. ${k.nomor}';
      if (jenis == 'pdf') {
        await SharePlus.instance.share(ShareParams(files: [XFile.fromData(pdf, mimeType: 'application/pdf', name: '$nama.pdf')], text: teks));
        return;
      }

      // Gambar dibuat dari PDF yang sama (bukan digambar ulang di sini), jadi
      // isinya selalu identik. 150 dpi ≈ 1240×1754 px per halaman A4: tetap
      // terbaca setelah dikecilkan WhatsApp. Kuitansi panjang = beberapa gambar.
      final gambar = <Uint8List>[];
      try {
        // Batas waktu: printing memanggil kanal native tanpa await, jadi galat di
        // tingkat kanal (mis. MissingPluginException) tidak pernah sampai ke
        // stream ini — tanpa batas, "Menyiapkan kuitansi…" menunggu selamanya.
        await for (final halaman in Printing.raster(pdf, dpi: 150).timeout(const Duration(seconds: 20))) {
          gambar.add(await halaman.toPng());
        }
      } catch (_) {
        gambar.clear(); // jangan kirim/simpan sebagian halaman
      }
      if (gambar.isEmpty) {
        throw Exception('Gambar kuitansi gagal dibuat di HP ini. Coba "Kirim PDF", ya.');
      }
      String namaHalaman(int i) => gambar.length == 1 ? nama : '$nama-${i + 1}';

      if (jenis == 'galeri') {
        for (var i = 0; i < gambar.length; i++) {
          await Gal.putImageBytes(gambar[i], album: 'BohAntar', name: namaHalaman(i));
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Kuitansi tersimpan di galeri, album BohAntar.'),
            action: SnackBarAction(label: 'Lihat', onPressed: Gal.open),
          ));
        }
        return;
      }
      await SharePlus.instance.share(ShareParams(
        files: [for (var i = 0; i < gambar.length; i++) XFile.fromData(gambar[i], mimeType: 'image/png', name: '${namaHalaman(i)}.png')],
        text: teks,
      ));
    } on GalException catch (e) {
      _beriTahu(e.type == GalExceptionType.notEnoughSpace
          ? 'Memori HP penuh. Kosongkan sedikit, lalu coba lagi.'
          : 'Kuitansi belum bisa disimpan ke galeri. Coba "Kirim gambar", ya.');
    } catch (e) {
      _beriTahu(pesanGalat(e));
    }
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
    _menerima = true;

    try {
      final response = await ApiService().acceptOrder(_currentIncomingOrder!['id']);
      if (response['status'] == 'success') {
        setState(() {
          _acceptedOrder = response['order'];
          _hasIncomingOrder = false;
          _currentIncomingOrder = null;
          _panelKecil = false; // diterima dari kartu yang diciutkan: buka rincian penumpang
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
          content: Text(pesanGalat(e)),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    } finally {
      _menerima = false;
    }
  }

  /// [dilihat] false: hitung mundurnya habis selagi aplikasi di latar
  /// belakang. Orderan itu tidak dicatat dilewati, jadi ditawarkan lagi saat
  /// aplikasi dibuka.
  void _rejectOrder({bool dilihat = true}) {
    _countdownTimer?.cancel();
    setState(() {
      // Tanpa daftar ini, polling tiga detik berikutnya mengembalikan pesanan
      // yang sama dan kartunya muncul lagi dengan hitung mundur baru. Driver
      // tidak punya cara melewatkan orderan selain offline. Tombol muat ulang
      // mengosongkannya.
      final id = _currentIncomingOrder?['id'];
      if (id != null && dilihat) _pesananDitolak.add(id as String);
      _hasIncomingOrder = false;
      _currentIncomingOrder = null;
      // Pin dan garis pratinjau orderan yang dilepas ikut dibersihkan.
      _tutupPesananDriver();
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
            Text('• Nama, email, dan nomor HP\n'
                '• Alamat tersimpan\n'
                '• Isi percakapan dengan driver',
                style: TextStyle(fontSize: 13, height: 1.6)),
            SizedBox(height: 12),
            Text('Riwayat pesanan tetap disimpan tanpa namamu, karena '
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
      daftarChat.value = null;
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    } catch (e) {
      // Pesan backend sudah jelas: pesanan berjalan, atau komisi belum disetor.
      _beriTahu(pesanGalat(e));
    }
  }

  void _logout() {
    // Token perangkat dilepas duluan, kalau tidak notifikasi orderan tetap
    // menyusul ke HP ini atas nama akun yang sudah keluar.
    NotifikasiService().lupakanPerangkat();
    // Chat akun ini jangan sempat terlihat oleh akun berikutnya di HP ini.
    daftarChat.value = null;
    // Akun berikutnya di HP ini mulai offline, dan server berhenti menganggap
    // akun ini siaga. Dikirim sebelum token dibuang.
    SharedPreferences.getInstance().then((p) => p.remove(_kunciOnline));
    if (widget.role != 'rider') ApiService().setDriverOffline();
    ApiService().clearToken();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  /// Akun driver beralih antara mode driver dan penumpang. Layarnya dibangun
  /// ulang, jadi polling dan pantauan posisi mode lama ikut berhenti di dispose.
  void _gantiMode() {
    final keDriver = widget.role == 'rider';
    if (!keDriver) {
      if (_acceptedOrder != null) {
        _beriTahu('Selesaikan dulu pesanan yang sedang kamu antar.');
        return;
      }
      // Mode penumpang berarti berhenti menerima orderan, bukan cuma ganti
      // tampilan: tanpa ini server tetap mengirim orderan ke HP ini.
      if (_isOnline) _toggleOnline(false);
    }
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => DashboardScreen(
          name: widget.name,
          role: keDriver ? 'driver' : 'rider',
          phone: widget.phone,
        ),
      ),
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

    // Rancangan user 16 Nov 2026 (Stitch "beranda ultra modern"): header putih
    // berisi logo + kolom cari, latar polos, ikon 3D, menu bawah lima tab.
    // Lengkungan biru di pojok kanan atas ikut dibuang.
    return Scaffold(
      backgroundColor: isDark ? AppTheme.bgObsidianDark : AppTheme.bgLight,
      appBar: _buildAppBar(),
      // removeBottom: extendBody menambahkan tinggi menu ke padding bawah, dan
      // tiap daftar bergulir bersarang diam-diam memakainya. Ruangnya dipasang
      // sendiri lewat _ruangNav.
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        child: _buildRiderTabContent(theme, isDark),
      ),
      // Isi halaman lewat di belakang menu kaca; ruangnya lihat _ruangNav.
      extendBody: true,
      bottomNavigationBar: ValueListenableBuilder(
        valueListenable: daftarChat,
        builder: (_, daftar, _) => NavKaca(
          // Tombol bulat besar di tengah ala admin web: Promo, seperti rancangan
          // Stitch (ikon "promo_icon_blue_circle_white_tag").
          tengah: _tabPromo,
          aktif: _currentTabIndex,
          saatPilih: (i) {
            setState(() => _currentTabIndex = i);
            if (i == _tabPromo) _muatVoucher();
          },
          item: [
            (ikon: Icons.home, gambar: 'assets/images/nav_beranda.png', label: 'Beranda', lencana: 0),
            (ikon: Icons.receipt_long, gambar: 'assets/images/nav_aktivitas.png', label: 'Aktivitas', lencana: 0),
            (ikon: Icons.discount_rounded, gambar: null, label: 'Promo', lencana: 0),
            (ikon: Icons.chat_bubble, gambar: 'assets/images/nav_chat.png', label: 'Chat', lencana: jumlahBelumDibaca(daftar)),
            (ikon: Icons.person, gambar: 'assets/images/nav_akun.png', label: 'Akun', lencana: 0),
          ],
        ),
      ),
    );
  }

  /// Ruang bawah tiap daftar bergulir supaya baris terakhirnya tidak tertutup
  /// menu kaca yang mengambang. `context` State ini ada di luar Scaffold.
  double get _ruangNav => NavKaca.ruang(context) + 12;

  // Tab penumpang: 0 Beranda, 1 Aktivitas, 2 Promo, 3 Chat, 4 Akun.
  static const _tabPromo = 2;

  Widget _buildRiderTabContent(ThemeData theme, bool isDark) {
    return switch (_currentTabIndex) {
      0 => _buildRiderHomeBody(theme, isDark),
      1 => _buildAktivitasBody(theme, isDark),
      _tabPromo => _buildPromoBody(isDark),
      3 => DaftarChat(myPhone: widget.phone, myName: _userName, ruangBawah: _ruangNav),
      _ => _buildAkunBody(theme, isDark),
    };
  }

  // Sama dengan rasio gambar banner unggahan (1200×600) di layar ±390 dp.
  static const double _tinggiBanner = 180;

  // Banner beranda dari dashboard; banner bawaan selama server belum menjawab.
  List<Map<String, dynamic>> _banner = bannerBawaan;

  Widget _buildRiderHomeBody(ThemeData theme, bool isDark) {
    return RefreshIndicator(
      onRefresh: () => Future.wait([_fetchUserProfile(), _fetchRiderActiveOrder(), _muatBanner(), _muatMenuLaris(), _muatVoucher()]),
      child: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.only(top: 14, bottom: _ruangNav),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Kolom cari ada di header (app bar), seperti rancangan.
          BannerBeranda(banner: _banner, tinggi: _tinggiBanner, saatTekan: _bukaBanner),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pesanan berjalan di atas layanan: inilah yang paling ingin
                // dilihat penumpang yang sedang menunggu.
                _buildActiveOrderFloatingCard(isDark),
                const SizedBox(height: 16),
                _gridLayanan(isDark),
              ],
            ),
          ),
          // Isi bawah beranda (10 Nov 2026, dulu kosong). Tiap bagian hilang
          // sendiri kalau datanya kosong, supaya tidak berlubang lagi.
          ..._bagianMenuLaris(isDark),
          ..._bagianPromo(isDark),
          ..._bagianTerakhirDipesan(isDark),
          _kartuGabungMitra(isDark),
        ],
      ),
      ),
    );
  }

  /// Judul bagian beranda: label kecil biru berhuruf kapital, judul, keterangan,
  /// dan "Lihat semua ›" di kanan bila [lihatSemua] diisi.
  Widget _judulBagian(String judul, String sub,
          {required String label, VoidCallback? lihatSemua, EdgeInsets pad = const EdgeInsets.fromLTRB(16, 26, 8, 12)}) =>
      Padding(
        padding: pad,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label.toUpperCase(),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: AppTheme.teksBerwarna(context, AppTheme.primaryDarkBlue))),
                  const SizedBox(height: 2),
                  Text(judul, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context))),
                ],
              ),
            ),
            if (lihatSemua != null)
              TextButton(
                onPressed: lihatSemua,
                style: TextButton.styleFrom(foregroundColor: AppTheme.teksBerwarna(context, AppTheme.primaryDarkBlue)),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Lihat semua', style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w700, fontSize: 13)),
                    Icon(Icons.chevron_right_rounded, size: 18),
                  ],
                ),
              ),
          ],
        ),
      );

  /// Tiga pesanan terakhir, kartu yang sama dengan tab Aktivitas (ketuk =
  /// rincian + "Pesan lagi"). Yang masih berjalan sudah tampil di atas grid.
  List<Widget> _bagianTerakhirDipesan(bool isDark) {
    final terakhir = _riwayatPesanan.where((o) => !pesananBerjalan((o['status'] ?? '').toString())).take(3).toList();
    if (terakhir.isEmpty) return const [];
    return [
      _judulBagian('Terakhir kamu pesan', 'Ketuk untuk lihat rincian atau pesan lagi',
          label: 'Riwayat', lihatSemua: () => setState(() => _currentTabIndex = 1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [for (final o in terakhir) _kartuRiwayat(Map<String, dynamic>.from(o as Map), isDark)]),
      ),
    ];
  }

  // Halaman pertama etalase BohFood (server mengurutkan: warung buka →
  // terlaris), hanya dari warung yang sedang buka.
  // ponytail: tanpa posisi, jadi tanpa jarak; kotanya satu (Sintang). Kirim
  // lat/lng kalau BohFood melebar ke kota lain.
  List<(MenuMakanan, Warung)> _menuLaris = const [];

  Future<void> _muatMenuLaris() async {
    try {
      final isi = await ApiService().getEtalaseFood(limit: 10);
      final warung = <String, Warung>{};
      for (final j in (isi['merchants'] as List?) ?? const []) {
        final w = Warung.dariJson(Map<String, dynamic>.from(j as Map));
        warung[w.id] = w;
      }
      final laris = <(MenuMakanan, Warung)>[];
      for (final j in (isi['menus'] as List?) ?? const []) {
        final m = MenuMakanan.dariJson(Map<String, dynamic>.from(j as Map));
        final w = warung[m.idWarung];
        if (w != null && w.buka) laris.add((m, w));
      }
      if (mounted) setState(() => _menuLaris = laris);
    } catch (e) {
      debugPrint('Menu laris gagal dimuat: $e');
    }
  }

  List<Widget> _bagianMenuLaris(bool isDark) {
    if (_menuLaris.isEmpty) return const [];
    // Platform baru: belum ada yang terjual → judulnya jangan mengaku laris.
    final adaLaris = _menuLaris.first.$1.terjual > 0;
    return [
      _judulBagian(
        adaLaris ? 'Lagi banyak dipesan' : 'Lapar? Pesan di BohFood',
        adaLaris ? 'Paling laris 30 hari terakhir' : 'Dari warung yang sedang buka',
        label: adaLaris ? 'Pilihan favorit' : 'BohFood',
        lihatSemua: _bukaBohFood,
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none, // bayangan kartu jangan terpotong
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, (m, w)) in _menuLaris.indexed) ...[
                if (i > 0) const SizedBox(width: 12),
                SizedBox(width: 176, child: _kartuMenuBeranda(m, w, isDark, laris: i == 0 && m.terjual > 0)),
              ],
            ],
          ),
        ),
      ),
    ];
  }

  /// Bingkai kartu beranda: putih, sudut besar, garis tipis, bayangan lembut.
  BoxDecoration _kotakKartu(bool isDark, {double radius = 24}) => BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFF1F5F9)),
        boxShadow: [if (!isDark) BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, 4))],
      );

  /// Kartu menu ala rancangan: foto membulat di dalam kartu, nama, warung,
  /// garis, harga + tombol tambah. Tanpa bintang/ulasan/waktu antar — datanya
  /// belum ada, dan angka karangan dilarang (lihat landing jujur).
  Widget _kartuMenuBeranda(MenuMakanan m, Warung w, bool isDark, {required bool laris}) {
    final redup = AppTheme.teksRedup(context);
    return Container(
      decoration: _kotakKartu(isDark),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => _bukaWarung(w, menuAwal: m.id),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 112,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        GambarJaringan(url: m.gambar, pengganti: Icons.fastfood_outlined),
                        if (m.terjual > 0)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Pil(laris ? 'TERLARIS' : '${m.terjual} terjual', warna: laris ? const Color(0xFFE11D48) : const Color(0xFF059669)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(m.nama, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(w.nama, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: redup)),
                const Spacer(),
                const SizedBox(height: 10),
                Divider(height: 1, color: isDark ? Colors.white12 : const Color(0xFFF1F5F9)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(m.teksHarga, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5)),
                    ),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryDarkBlue,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: AppTheme.primaryDarkBlue.withValues(alpha: 0.28), blurRadius: 12, offset: const Offset(0, 4))],
                      ),
                      child: const Icon(Icons.add_rounded, color: Colors.white, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Voucher yang masih bisa dipakai akun ini (GET /api/voucher). Kosong =
  // tak ada promo, atau server lama yang belum punya rutenya.
  List<Map<String, dynamic>> _voucher = const [];
  bool _voucherDimuat = false;

  Future<void> _muatVoucher() async {
    try {
      final v = await ApiService().getVoucher();
      if (mounted) setState(() => _voucher = v);
    } catch (e) {
      debugPrint('Voucher gagal dimuat: $e');
    } finally {
      if (mounted) setState(() => _voucherDimuat = true);
    }
  }

  /// Layanan tujuan tombol voucher; '' = semua layanan. 'BohAntar' sudah
  /// dilebur ke BohSend.
  static String _layananVoucher(Map<String, dynamic> v) {
    final l = (v['layanan'] ?? '').toString();
    return l == 'BohAntar' ? 'BohSend' : l;
  }

  static const _bulan = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

  /// "35%" atau "Rp5.000".
  String _besarDiskon(Map<String, dynamic> v) {
    final nilai = (v['nilai'] as num?)?.toDouble() ?? 0;
    return v['jenis'] == 'persen' ? '${nilai.toStringAsFixed(nilai % 1 == 0 ? 0 : 1).replaceAll('.', ',')}%' : _rupiah(nilai);
  }

  /// Syarat singkat voucher: layanan, min. belanja, maks. diskon, batas tanggal.
  String _syaratVoucher(Map<String, dynamic> v) {
    final l = _layananVoucher(v);
    final min = (v['min_belanja'] as num?)?.toDouble() ?? 0;
    final maks = (v['maks_diskon'] as num?)?.toDouble() ?? 0;
    final selesai = DateTime.tryParse((v['selesai'] ?? '').toString());
    return [
      l.isEmpty ? 'Semua layanan' : 'Khusus $l',
      if (min > 0) 'min. ${_rupiah(min)}',
      if (maks > 0 && v['jenis'] == 'persen') 'maks. ${_rupiah(maks)}',
      if (selesai != null) 's.d. ${selesai.day} ${_bulan[selesai.month - 1]}',
    ].join(' · ');
  }

  /// Kartu promo (rancangan "Diskon hingga 35%"). Voucher BohAntar terpakai
  /// otomatis saat memesan, jadi tidak ada kode yang perlu disalin.
  Widget _kartuVoucher(Map<String, dynamic> v, bool isDark) {
    final layanan = _layananVoucher(v);
    final biru = AppTheme.teksBerwarna(context, AppTheme.primaryDarkBlue);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1E3A8A).withValues(alpha: 0.45), const Color(0xFF4C1D95).withValues(alpha: 0.35)]
              : const [Color(0xFFEFF6FF), Color(0xFFEEF2FF), Color(0xFFFAF5FF)],
        ),
        border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFDBEAFE)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFBFDBFE)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bolt_rounded, size: 13, color: Color(0xFFF59E0B)),
                      Text('PROMO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6, color: biru)),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text('DISKON ${_besarDiskon(v)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, height: 1.2)),
                const SizedBox(height: 2),
                Text((v['judul'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                Text(_syaratVoucher(v), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: AppTheme.teksRedup(context))),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: () => layanan.isEmpty ? _bukaSemuaLayanan() : _bukaLayanan(layanan),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryDarkBlue,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Pesan sekarang'), Icon(Icons.chevron_right_rounded, size: 16)]),
                    ),
                    Text('Terpakai otomatis', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.teksRedup(context))),
                  ],
                ),
              ],
            ),
          ),
          Transform.rotate(angle: 0.12, child: Image.asset('assets/images/promo_tag.png', width: 84, height: 84, cacheWidth: 252)),
        ],
      ),
    );
  }

  List<Widget> _bagianPromo(bool isDark) {
    if (_voucher.isEmpty) return const [];
    return [
      _judulBagian('Promo buat kamu', 'Diskon langsung terpotong saat kamu pesan',
          label: 'Promo', lihatSemua: _voucher.length > 1 ? () => setState(() => _currentTabIndex = _tabPromo) : null),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _kartuVoucher(_voucher.first, isDark)),
    ];
  }

  /// Tab Promo: semua voucher yang masih bisa dipakai akun ini.
  Widget _buildPromoBody(bool isDark) {
    return RefreshIndicator(
      onRefresh: _muatVoucher,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 16, 16, _ruangNav),
        children: [
          const Text('Promo', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Tanpa kode: diskon terbesar yang cocok langsung terpakai saat kamu pesan.', style: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context))),
          const SizedBox(height: 16),
          if (!_voucherDimuat)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (_voucher.isEmpty)
            const PesanKosong(
              ikon: Icons.local_offer_outlined,
              judul: 'Belum ada promo',
              teks: 'Kalau ada promo, kartunya muncul di sini dan diskonnya langsung terpakai saat kamu pesan.',
            )
          else
            for (final v in _voucher) Padding(padding: const EdgeInsets.only(bottom: 12), child: _kartuVoucher(v, isDark)),
        ],
      ),
    );
  }

  void _bukaWarung(Warung w, {String? menuAwal}) {
    Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FoodMenuScreen(warung: w, menuAwal: menuAwal, riderName: _namaPemesan, riderPhone: widget.phone)),
    ).then((orderId) {
      _fetchUserProfile();
      if (orderId != null && mounted) _lacakBohFood(orderId);
    });
  }

  /// Ajakan jadi driver / mitra. Platform baru masih mencari keduanya. Akun
  /// driver (sedang di mode penumpang) tidak ditawari jadi driver lagi.
  Widget _kartuGabungMitra(bool isDark) {
    // Formulir web langsung dengan ?type= (food/rental); tanpa type ia jatuh ke rental.
    void daftar(String jenis) =>
        launchUrl(Uri.parse('${ApiService.prodUrl}/#/register-partner?type=$jenis'), mode: LaunchMode.externalApplication);
    Widget kartu(String layanan, String judul, String sub, String tombol, VoidCallback tekan) => Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          decoration: _kotakKartu(isDark, radius: 18),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: tekan,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white10 : Colors.white,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: AppTheme.primaryDarkBlue, width: 1.5),
                      ),
                      child: Image.asset(asetLayanan(layanan)!, cacheWidth: 108),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(judul, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: AppTheme.teksRedup(context))),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: tekan,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryDarkBlue,
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [Text(tombol), const Icon(Icons.chevron_right_rounded, size: 15)]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _judulBagian('Gabung jadi mitra kami', 'Tambah penghasilan bersama BohAntar di Sintang', label: 'Peluang usaha'),
        // Akun driver (sedang di mode penumpang) tidak ditawari jadi driver lagi.
        if (_peranAkun != 'driver')
          kartu('BohRide', 'Mitra Driver', 'Antar penumpang & paket, atur waktumu sendiri', 'Daftar Driver', _caraJadiDriver),
        kartu('BohFood', 'Mitra BohFood', 'Jangkau lebih banyak pembeli untuk warungmu', 'Daftar Warung', () => daftar('food')),
        kartu('BohRental', 'Mitra BohRental', 'Sewakan mobil atau motormu lewat BohAntar', 'Daftar Rental', () => daftar('rental')),
      ],
    );
  }

  void _caraJadiDriver() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mau jadi driver?'),
        content: Text(_faq.firstWhere((f) => f.$1 == 'Mau daftar jadi driver?').$2),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Mengerti'))],
      ),
    );
  }

  // Pencarian ala Gojek: satu kolom untuk tujuan BohRide dan warung/menu
  // BohFood. Dulu kotak "Diantar ke mana?" yang cuma membuka BohRide.
  Widget _kolomCari(bool isDark) {
    // Tanpa tombol mikrofon & filter dari rancangan: fiturnya belum ada.
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _bukaPencarian,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.search_rounded, color: AppTheme.teksBerwarna(context, AppTheme.primaryDarkBlue), size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Cari tujuan, warung, atau menu',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppTheme.teksRedup(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _muatBanner() async {
    try {
      final daftar = await ApiService().getBanner();
      // Kosong = tidak ada yang aktif: banner bawaan tetap, supaya beranda
      // tidak berlubang.
      if (mounted && daftar.isNotEmpty) setState(() => _banner = daftar);
    } catch (e) {
      debugPrint('Banner gagal dimuat: $e');
    }
  }

  void _bukaBanner(Map<String, dynamic> b) {
    final tujuan = (b['tujuan'] ?? '').toString();
    if (tujuan == 'url') {
      // Server hanya menerima https; diperiksa lagi sebelum dibuka.
      final url = Uri.tryParse((b['url'] ?? '').toString());
      if (url != null && url.scheme == 'https') launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    // Banner toko mitra (dashboard → Banner Beranda → "Langsung ke ...").
    final target = (b['target'] ?? '').toString();
    if (tujuan == 'BohFood' && target.isNotEmpty) {
      _bukaWarungBanner(target);
    } else if (tujuan == 'BohRental' && target.isNotEmpty) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => RentalScreen(myPhone: widget.phone, mitra: target)));
    } else if (tujuan.isNotEmpty) {
      _bukaLayanan(tujuan);
    }
  }

  bool _memuatWarung = false; // ketukan ganda pada banner jangan membuka dua layar

  /// Warung dicari dari daftar warung BohFood (tanpa posisi, seperti kartu menu
  /// beranda). Warung yang sudah hilang/dicabut jatuh ke halaman BohFood.
  Future<void> _bukaWarungBanner(String id) async {
    if (_memuatWarung) return;
    _memuatWarung = true;
    try {
      final daftar = await ApiService().getFoodMerchants();
      final j = daftar.whereType<Map>().where((m) => m['id'] == id).firstOrNull;
      if (!mounted) return;
      if (j == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Warungnya sedang tidak tersedia. Coba warung lain di BohFood, ya.')),
        );
        _bukaBohFood();
      } else {
        _bukaWarung(Warung.dariJson(Map<String, dynamic>.from(j)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pesanGalat(e))));
    } finally {
      _memuatWarung = false;
    }
  }

  String get _namaPemesan => _userName.isNotEmpty ? _userName : widget.name;

  void _bukaPencarian() {
    Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => CariScreen(riderName: _namaPemesan, riderPhone: widget.phone)),
    ).then((orderId) {
      _fetchUserProfile();
      if (orderId != null && mounted) _lacakBohFood(orderId);
    });
  }

  /// Pelacakan pesanan BohFood yang baru jadi. Layar pemesanan menutup diri dan
  /// mengoper id-nya ke sini, supaya tombol kembali di layar pelacakan
  /// mendarat di beranda.
  void _lacakBohFood(String orderId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OrderRideScreen(initialService: 'BohFood', riderName: _namaPemesan, riderPhone: widget.phone, initialOrderId: orderId),
      ),
    ).then((_) => _kembaliKeBeranda());
  }

  /// Kembali dari layar pesan/lacak: kartu pesanan berjalan langsung
  /// disegarkan, tidak menunggu polling yang melambat saat tak ada pesanan.
  void _kembaliKeBeranda() {
    _fetchUserProfile();
    _fetchRiderActiveOrder();
  }

  /// Membuka formulir pesan untuk layanan antar orang/paket.
  void _bukaPesanan(String layanan, {bool fokusTujuan = false}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => OrderRideScreen(
          initialService: layanan,
          riderName: _userName.isNotEmpty ? _userName : widget.name,
          riderPhone: widget.phone,
          fokusTujuan: fokusTujuan,
        ),
      ),
    ).then((_) => _kembaliKeBeranda());
  }

  void _bukaBohFood() {
    Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => FoodMerchantsScreen(riderName: _namaPemesan, riderPhone: widget.phone)),
    ).then((orderId) {
      _fetchUserProfile();
      if (orderId != null && mounted) _lacakBohFood(orderId);
    });
  }

  void _bukaLayanan(String layanan) {
    switch (layanan) {
      case 'BohFood':
        _bukaBohFood();
      case 'BohRental':
        Navigator.push(context, MaterialPageRoute(builder: (_) => RentalScreen(myPhone: widget.phone)));
      default:
        _bukaPesanan(layanan);
    }
  }

  // Urutan keputusan 16 Okt 2026: BohRide·BohCar·BohFood·BohSend·BohRental·
  // Lainnya (19 Okt: BohMart yang belum ada diganti BohRental). Rancangan 16 Nov:
  // SATU baris enam ikon 3D di ubin putih, dalam kartu putih. BohAntar sudah
  // dilebur ke BohSend; pengenal 'BohAntar' tetap dikenali untuk pesanan lama.
  Widget _gridLayanan(bool isDark) {
    final ubin = isDark ? const Color(0xFF334155) : Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      decoration: _kotakKartu(isDark),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in const ['BohRide', 'BohCar', 'BohFood', 'BohSend', 'BohRental', 'Lainnya'])
            Expanded(
              child: Semantics(
                button: true,
                label: l,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: l == 'Lainnya' ? _bukaSemuaLayanan : () => _bukaLayanan(l),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: ubin,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFF1F5F9)),
                              boxShadow: [if (!isDark) BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 4))],
                            ),
                            child: Image.asset(asetLayanan(l)!, fit: BoxFit.contain, cacheWidth: 168),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // "BohRental" sedikit lebih lebar dari kolomnya di HP 360 dp.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l, maxLines: 1, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// "Lainnya" dulu cuma memunculkan "Membuka seluruh menu layanan..." lalu
  /// tidak membuka apa pun. Sekarang daftar semua layanan.
  void _bukaSemuaLayanan() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        // Ubin putih ikon 3D yang sama dengan grid beranda, versi kecil.
        Widget ubin(String layanan) => _ikonLayanan3D(layanan, Theme.of(ctx).brightness == Brightness.dark, ukuran: 46);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Semua layanan', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final l in const ['BohRide', 'BohCar', 'BohFood', 'BohSend', 'BohRental'])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ubin(l),
                    title: Text(l, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(deskripsiLayanan(l)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(ctx);
                      _bukaLayanan(l);
                    },
                  ),
              ],
            ),
          ),
        );
      },
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
    final judul = Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Aktivitas', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, fontSize: 24)),
          const SizedBox(height: 2),
          Text('Pesanan yang sedang jalan dan riwayatmu', style: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context))),
        ],
      ),
    );
    if (_riwayatPesanan.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetchRiderActiveOrder,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(16, 16, 16, _ruangNav),
          children: [
            judul,
            const SizedBox(height: 60),
            PesanKosong(
              ikon: Icons.receipt_long,
              judul: 'Belum ada pesanan',
              teks: 'Pesanan pertamamu akan muncul di sini. Yuk, coba antar jemput BohRide!',
              tombol: 'Pesan BohRide',
              saatTekan: () => _bukaPesanan('BohRide', fokusTujuan: true),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetchRiderActiveOrder,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 600) _muatRiwayatLagi();
          return false;
        },
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: EdgeInsets.fromLTRB(16, 0, 16, _ruangNav),
          itemCount: _riwayatPesanan.length + (_riwayatAdaLagi ? 2 : 1),
          itemBuilder: (context, index) {
            if (index == 0) return judul;
            if (index > _riwayatPesanan.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _riwayatGagalLagi
                      ? TextButton.icon(onPressed: _muatRiwayatLagi, icon: const Icon(Icons.refresh), label: const Text('Gagal memuat riwayat lama. Coba lagi'))
                      : const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                ),
              );
            }
            return _kartuRiwayat(Map<String, dynamic>.from(_riwayatPesanan[index - 1] as Map), isDark);
          },
        ),
      ),
    );
  }

  /// Satu pesanan di tab Aktivitas. Yang masih berjalan bergaris warna
  /// statusnya dan bertuliskan "Lacak", supaya menonjol dari riwayat.
  /// Ikon layanan 3D di ubin putih kecil — sama dengan ubin grid beranda,
  /// dipakai kartu riwayat penumpang dan driver supaya satu template.
  Widget _ikonLayanan3D(String service, bool isDark, {double ukuran = 42}) {
    final aset = asetLayanan(service);
    return Container(
      width: ukuran,
      height: ukuran,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF334155) : Colors.white,
        borderRadius: BorderRadius.circular(ukuran * 0.3),
        border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFF1F5F9)),
        boxShadow: [if (!isDark) BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: aset == null
          ? Icon(ikonLayanan(service), color: AppTheme.teksBerwarna(context, AppTheme.warnaLayanan(service)), size: ukuran * 0.5)
          : Image.asset(aset, cacheWidth: (ukuran * 3).round()),
    );
  }

  Widget _kartuRiwayat(Map<String, dynamic> order, bool isDark) {
    final service = (order['service'] ?? 'BohRide').toString();
    final status = (order['status'] ?? 'pending').toString();
    // Yang dibayar pemesan: ongkir, biaya jasa, dan (makanan) uang makanan.
    final total = _tagihan(order);
    final waktu = DateTime.tryParse((order['created_at'] ?? '').toString())?.toLocal();
    final berjalan = pesananBerjalan(status);
    final warnaStatus = AppTheme.warnaStatus(status);
    final redup = AppTheme.teksRedup(context);

    Widget alamat(IconData ikon, Color warna, Object? teks) => Row(
          children: [
            Icon(ikon, size: 13, color: warna),
            const SizedBox(width: 8),
            Expanded(
              child: Text((teks ?? '-').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: berjalan ? warnaStatus.withValues(alpha: 0.45) : Colors.grey.withValues(alpha: 0.16),
          width: berjalan ? 1.5 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _bukaAktivitas(order),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ikonLayanan3D(service, isDark),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(service, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          if (waktu != null) Text(_waktuPendek(waktu), style: TextStyle(fontSize: 11.5, color: redup)),
                        ],
                      ),
                    ),
                    _lencanaStatus(status),
                  ],
                ),
                const SizedBox(height: 12),
                alamat(Icons.circle, Colors.green, order['pickup']),
                const SizedBox(height: 5),
                alamat(Icons.location_on, Colors.red, order['dropoff']),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(total > 0 ? _rupiah(total) : ((order['diskon'] as num? ?? 0) > 0 ? 'Gratis' : '-'), style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primaryBlue, fontSize: 14)),
                    const Spacer(),
                    Text(
                      berjalan ? 'Lacak' : 'Rincian',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: berjalan ? AppTheme.teksBerwarna(context, warnaStatus) : redup),
                    ),
                    Icon(Icons.chevron_right, size: 18, color: berjalan ? AppTheme.teksBerwarna(context, warnaStatus) : redup),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lencanaStatus(String status) {
    final warna = AppTheme.warnaStatus(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: warna.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(
        labelStatus(status),
        style: TextStyle(color: AppTheme.teksBerwarna(context, warna), fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }

  static const _namaBulan = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

  /// "Hari ini, 09.15" atau "17 Okt 2026, 20.40" — bukan 17/10/2026.
  String _waktuPendek(DateTime t) {
    final kini = DateTime.now();
    final jam = '${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
    if (t.year == kini.year && t.month == kini.month && t.day == kini.day) return 'Hari ini, $jam';
    return '${t.day} ${_namaBulan[t.month - 1]} ${t.year}, $jam';
  }

  /// Pesanan yang masih berjalan membuka layar pelacakan (peta, status, tombol
  /// chat) — tujuan yang sama dengan kartu pesanan aktif di beranda. Yang sudah
  /// selesai atau batal cukup lembar rincian: tidak ada lagi yang bisa dilacak.
  void _bukaAktivitas(Map<String, dynamic> o) {
    final status = (o['status'] ?? '').toString();
    final service = (o['service'] ?? 'BohRide').toString();
    if (pesananBerjalan(status)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OrderRideScreen(
            initialService: service,
            riderName: _userName.isNotEmpty ? _userName : widget.name,
            riderPhone: widget.phone,
            initialOrderId: o['id'],
          ),
        ),
      ).then((_) {
        _fetchRiderActiveOrder();
        _fetchUserProfile();
      });
      return;
    }

    final waktu = DateTime.tryParse((o['created_at'] ?? '').toString())?.toLocal();
    final barang = jenisPesanan(service) != JenisPesanan.orang;
    final diterima = (o['received_by'] ?? '').toString();
    final fotoSerah = (o['delivery_photo_url'] ?? '').toString();
    // Pesan lagi ke tujuan yang sama: tujuannya jadi kata pencarian, jadi
    // penumpang tetap memilih titiknya sendiri dari saran. BohFood tidak,
    // karena isinya keranjang warung, bukan sekadar tujuan.
    final bisaPesanLagi = jenisPesanan(service) != JenisPesanan.makanan && (o['dropoff'] ?? '').toString().isNotEmpty;
    final items = (o['items'] as List?) ?? const [];
    final ongkir = (o['fare'] as num?)?.toDouble() ?? 0;
    final biayaJasa = (o['biaya_jasa'] as num?)?.toDouble() ?? 0;
    final makanan = (o['food_total'] as num?)?.toDouble() ?? 0;
    final diskon = (o['diskon'] as num?)?.toDouble() ?? 0;
    Widget baris(String label, String nilai, {bool tebal = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 90, child: Text(label, style: TextStyle(fontSize: 13, color: AppTheme.teksRedup(context)))),
              Expanded(child: Text(nilai, style: TextStyle(fontSize: 13, fontWeight: tebal ? FontWeight.bold : FontWeight.normal))),
            ],
          ),
        );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(service, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
                _lencanaStatus(status),
              ],
            ),
            if (waktu != null)
              Text(_waktuPendek(waktu), style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context))),
            const SizedBox(height: 14),
            baris(barang ? 'Diambil' : 'Dijemput', (o['pickup'] ?? '-').toString()),
            baris(barang ? 'Dikirim ke' : 'Diantar ke', (o['dropoff'] ?? '-').toString()),
            if ((o['driver_name'] ?? '').toString().isNotEmpty) baris('Driver', o['driver_name'].toString()),
            // Jawaban untuk "statusnya selesai tapi paketnya belum sampai?":
            // siapa yang menerima dan fotonya, dari driver saat menyerahkan.
            if (diterima.isNotEmpty) baris('Diterima', diterima),
            if (fotoSerah.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: LayoutBuilder(
                    builder: (context, batas) => Image.network(
                      '${ApiService().baseUrl}$fotoSerah',
                      height: 150,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      cacheWidth: lebarDekode(context, batas.copyWith(maxHeight: 150)),
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            // Pesanan kurir untuk pelanggan toko Kasvo: akun pemesannya toko, tapi
            // yang membayar ongkir adalah penerima.
            if (((o['kasvo_pengantaran_id'] as num?)?.toInt() ?? 0) > 0)
              baris('Pembayaran', 'Ongkir dibayar tunai oleh penerima (${o['receiver_name'] ?? '-'})')
            else
              baris('Pembayaran', o['payment_method'] == 'wallet' ? 'Saldo' : 'Tunai'),
            if (items.isNotEmpty) ...[
              const Divider(height: 24),
              for (final it in items)
                baris('${it['qty'] ?? 0}×', [
                  (it['name'] ?? '').toString(),
                  for (final op in (it['options'] as List?) ?? const []) '${op['name']}',
                ].join(' · ')),
            ],
            const Divider(height: 24),
            if (makanan > 0) baris('Makanan', _rupiah(makanan)),
            baris(makanan > 0 ? 'Ongkir' : 'Ongkos', _rupiah(ongkir)),
            if (biayaJasa > 0) baris('Biaya jasa', _rupiah(biayaJasa)),
            if (diskon > 0) baris('Diskon', '-${_rupiah(diskon)}'),
            baris('Total', _rupiah(ongkir + biayaJasa + makanan - diskon), tebal: true),
            // Bukti untuk klaim perjalanan dinas ke bendahara kantor. Lembar
            // ditutup dulu supaya galatnya (SnackBar) tidak tertutup lembar ini.
            // Pengantaran kasir Kasvo tidak: ongkirnya dibayar penerima (lihat
            // bisaDikuitansi di backend/kuitansi.go).
            if (status == 'completed' && ((o['kasvo_pengantaran_id'] as num?)?.toInt() ?? 0) == 0) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _pilihKuitansi(o['id'].toString());
                },
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text('Kuitansi (PDF / gambar)'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 46)),
              ),
            ],
            if (bisaPesanLagi) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => OrderRideScreen(
                        initialService: service == 'BohAntar' ? 'BohSend' : service,
                        initialDestination: (o['dropoff'] ?? '').toString(),
                        riderName: _userName.isNotEmpty ? _userName : widget.name,
                        riderPhone: widget.phone,
                      ),
                    ),
                  ).then((_) => _fetchUserProfile());
                },
                icon: const Icon(Icons.replay, size: 18),
                label: Text(barang ? 'Kirim lagi ke tujuan ini' : 'Pesan lagi ke tujuan ini'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 46)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBantuanBody(ThemeData theme, bool isDark) {
    // ponytail: isinya statis, tarikannya cuma membaca ulang profil supaya
    // gerakannya sama di semua tab.
    return RefreshIndicator(
      onRefresh: _fetchUserProfile,
      child: ListView(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 56),
      children: [
        Text(
          "Pusat Bantuan",
          style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, fontSize: 24),
        ),
        const SizedBox(height: 4),
        Text("Ada kendala? Cek jawabannya di bawah, atau chat CS kami.", style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13)),
        const SizedBox(height: 18),
        // Jalan pintas ke manusia, paling atas. Dulu tiap jawaban menyuruh
        // "hubungi CS melalui tombol bantuan langsung" — tombolnya tidak ada.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF25D366).withValues(alpha: isDark ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(color: Color(0xFF128C7E), shape: BoxShape.circle),
                child: const Icon(Icons.support_agent, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Butuh bantuan cepat?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    SizedBox(height: 2),
                    Text("Chat CS BohAntar lewat WhatsApp", style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              FilledButton(
                onPressed: () => _bukaWhatsApp(ApiService.waCS, pesan: 'Halo CS BohAntar, saya butuh bantuan.'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF128C7E),
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: const Text("Chat CS"),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        const Text("Pertanyaan yang sering ditanya", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 10),
        for (final (tanya, jawab) in _faq) _buildFAQTile(tanya, jawab, isDark),
      ],
      ),
    );
  }

  // Jawaban mengikuti cara kerja aplikasi yang sekarang — ubah bersama kalau
  // alurnya berubah.
  static const _faq = [
    (
      'Ongkos tidak muncul saat memesan?',
      'Ongkos baru dihitung setelah titik jemput dan tujuan pasti. Pilih tujuan dari daftar saran, atau ketuk titiknya di peta. '
          'Pastikan GPS dan internet menyala.',
    ),
    (
      'Bagaimana cara membatalkan pesanan?',
      'Buka pesanan yang sedang berjalan (dari beranda atau tab Aktivitas), lalu ketuk "Batalkan pesanan". '
          'Pembatalan bisa selama driver belum menjemputmu atau belum mengambil paketmu.',
    ),
    (
      'Status selesai, tapi paket belum sampai?',
      'Buka pesanannya di tab Aktivitas untuk melihat nama penerima dan foto bukti serah terima dari driver. '
          'Kalau tetap ada masalah, chat CS lewat tombol di atas dan sebutkan waktu pesanannya.',
    ),
    (
      'Mau daftar jadi driver?',
      'Keluar dari akun, ketuk "Daftar", lalu pilih "Daftar jadi driver". Siapkan foto KTP, SIM, dan STNK. '
          'Akun driver aktif setelah disetujui admin. Sesudah itu kamu tetap bisa memesan: '
          'buka tab Akun, lalu ketuk "Beralih ke mode penumpang".',
    ),
  ];

  Widget _buildFAQTile(String question, String answer, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
      ),
      child: ExpansionTile(
        // Tanpa ini ExpansionTile menggambar garis atas-bawah saat terbuka.
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(question, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedAlignment: Alignment.centerLeft,
        children: [
          Text(answer, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13, height: 1.5)),
        ],
      ),
    );
  }

  Widget _buildAkunBody(ThemeData theme, bool isDark) {
    return RefreshIndicator(
      onRefresh: _fetchUserProfile,
      child: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.fromLTRB(20, 24, 20, _ruangNav),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 36,
                backgroundColor: AppTheme.primaryBlue.withOpacity(0.12),
                foregroundImage: _fotoWajah.isEmpty ? null : ResizeImage(NetworkImage(urlGambar(_fotoWajah)), width: 216),
                // Gagal dimuat (sinyal putus): huruf depan tetap terlihat.
                onForegroundImageError: _fotoWajah.isEmpty ? null : (_, _) {},
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

          // Kartu saldo hanya di mode driver: itu saldo komisi, syarat menarik
          // order. Penumpang tidak punya saldo sejak 24 Okt 2026.
          if (widget.role != 'rider') ...[
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
                    Text(
                      "Saldo",
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.primaryBlue),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _rupiah(_walletBalance),
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
                  child: const Text("Isi saldo", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          ],

          if (_peranAkun == 'driver')
            _buildAkunMenuItem(
              Icons.face_retouching_natural,
              _fotoWajah.isEmpty ? "Pasang foto wajah" : "Foto wajah (terkunci)",
              _pasangFotoWajah,
              isDark,
            ),
          if (_peranAkun == 'driver')
            _buildAkunMenuItem(
              widget.role == 'rider' ? Icons.two_wheeler : Icons.swap_horiz,
              widget.role == 'rider' ? "Beralih ke mode driver" : "Beralih ke mode penumpang",
              _gantiMode,
              isDark,
            ),
          // Layar Akun ini dipakai dua peran. Yang menunjuk tab penumpang akan
          // jadi tombol mati kalau ditekan driver — nomor tabnya tidak ada di
          // sana — jadi tujuannya dipilih, bukan dibiarkan.
          _buildAkunMenuItem(Icons.receipt, "Riwayat pesanan", () {
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
            // Dulu berbunyi "PayAntar (Default)", padahal bawaan pemesanan
            // adalah Tunai.
            _buildAkunMenuItem(Icons.payment, "Metode pembayaran", () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Bayar tunai ke driver saat pesanan sampai.")),
              );
            }, isDark),
            _buildAkunMenuItem(Icons.card_giftcard, "Promo saya", () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Belum ada promo untukmu saat ini. Nanti kami kabari, ya!")),
              );
            }, isDark),
            // Bukan tab lagi sejak slotnya dipakai Chat.
            _buildAkunMenuItem(Icons.help, "Bantuan", () {
              Navigator.push(context, MaterialPageRoute(
                builder: (ctx) => Scaffold(appBar: AppBar(), body: _buildBantuanBody(Theme.of(ctx), isDark)),
              ));
            }, isDark),
          ],
          _buildAkunMenuItem(Icons.lock_reset, "Ganti password", _dialogGantiPassword, isDark),
          // Menu "Pengaturan" dibuang: isinya cuma "sedang dipersiapkan".
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
              "Menghapus datamu secara permanen",
              style: TextStyle(fontSize: 11, color: isDark ? Colors.blueGrey.shade400 : Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.red),
          ),
        ],
      ),
      ),
    );
  }

  /// Selfie langsung dari kamera depan, bukan galeri: yang dilihat penumpang
  /// harus wajah orang yang memegang HP ini, bukan foto siapa saja. Hanya
  /// bisa sekali; sesudahnya server menguncinya sampai admin membukanya.
  Future<void> _pasangFotoWajah() async {
    final pesan = ScaffoldMessenger.of(context);
    // Status kunci bisa basi: admin mungkin baru saja membukanya (driver
    // dapat notifikasi "Ambil ulang foto wajah"). Tanya server dulu, jangan
    // menolak berdasarkan data layar yang dimuat jam lalu.
    if (_fotoWajah.isNotEmpty) await _fetchUserProfile();
    if (!mounted) return;
    if (_fotoWajah.isNotEmpty) {
      pesan.showSnackBar(const SnackBar(
          content: Text("Foto wajah sudah dicek dan dikunci. Hubungi admin BohAntar kalau ingin menggantinya.")));
      return;
    }
    try {
      // Di dalam try: izin kamera yang ditolak melempar PlatformException.
      final foto = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 800,
        imageQuality: 75,
      );
      if (foto == null || !mounted) return;
      final url = await ApiService().pasangFotoWajah(foto.path);
      if (!mounted) return;
      setState(() => _fotoWajah = url);
      pesan.showSnackBar(const SnackBar(content: Text("Foto wajah tersimpan dan dikunci. Penumpang akan melihatnya saat kamu menjemput.")));
    } catch (e) {
      pesan.showSnackBar(SnackBar(content: Text(pesanGalat(e))));
    }
  }

  /// Terutama untuk driver: password awalnya dibuat admin dan cuma
  /// ditampilkan sekali, jadi harus bisa diganti sendiri dari aplikasi.
  void _dialogGantiPassword() {
    // ponytail: controller tidak di-dispose. Dispose saat dialog ditutup
    // menabrak animasi keluarnya ("used after disposed"); tiga controller tanpa
    // listener cukup dibereskan garbage collector.
    final lama = TextEditingController();
    final baru = TextEditingController();
    final ulang = TextEditingController();
    var galat = '';
    var mengirim = false;
    InputDecoration hias(String label) => InputDecoration(labelText: label, isDense: true);

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) {
          Future<void> simpan() async {
            final b = baru.text;
            final pesan = lama.text.isEmpty
                ? 'Isi password lama'
                : b.length < 8
                    ? 'Password baru minimal 8 karakter'
                    : b != ulang.text
                        ? 'Ulangi password baru dengan sama persis'
                        : b == lama.text
                            ? 'Password baru sama dengan yang lama'
                            : '';
            if (pesan.isNotEmpty) {
              setDialog(() => galat = pesan);
              return;
            }
            setDialog(() {
              galat = '';
              mengirim = true;
            });
            try {
              await ApiService().gantiPassword(lama.text, b);
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Password berhasil diganti. Pakai password baru saat masuk berikutnya.')),
              );
            } catch (e) {
              setDialog(() {
                galat = pesanGalat(e);
                mengirim = false;
              });
            }
          }

          return AlertDialog(
            title: const Text('Ganti password'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: lama, obscureText: true, decoration: hias('Password lama')),
                  const SizedBox(height: 8),
                  TextField(controller: baru, obscureText: true, decoration: hias('Password baru (min. 8 karakter)')),
                  const SizedBox(height: 8),
                  TextField(controller: ulang, obscureText: true, decoration: hias('Ulangi password baru'), onSubmitted: (_) => simpan()),
                  if (galat.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(galat, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                  const SizedBox(height: 12),
                  // Akun yang lahir lewat Google tidak punya password lama untuk
                  // diisi; jalannya lewat Lupa password yang memverifikasi Google.
                  Text(
                    'Daftar lewat Google dan belum pernah punya password? Keluar, lalu pakai "Lupa password?" di layar masuk.',
                    style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context)),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: mengirim ? null : () => Navigator.pop(dialogContext), child: const Text('Batal')),
              ElevatedButton(
                onPressed: mengirim ? null : simpan,
                child: mengirim
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Simpan'),
              ),
            ],
          );
        },
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
    final o = _riderActiveOrder;
    if (o == null) return const SizedBox.shrink();

    final service = (o['service'] ?? 'BohRide').toString();
    final status = (o['status'] ?? 'pending').toString();
    final driverName = (o['driver_name'] ?? '').toString();
    // Kalimat yang sama dengan layar pelacakan, jadi tidak ada dua versi.
    final kabar = kabarPesanan(service, status, warung: (o['merchant_name'] ?? '').toString());
    final warna = AppTheme.warnaStatus(status);

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardObsidianDark : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: warna.withValues(alpha: 0.45), width: 1.5),
          boxShadow: [BoxShadow(color: warna.withValues(alpha: isDark ? 0.0 : 0.10), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            // Seluruh kartu bisa diketuk, bukan cuma tombol "Lihat" kecil.
            // Membuka pelacakan, bukan formulir kosong.
            onTap: () => _bukaAktivitas(o),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(color: warna, shape: BoxShape.circle),
                        child: Icon(ikonLayanan(service), color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(kabar.judul, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            const SizedBox(height: 2),
                            Text(
                              [service, if (driverName.isNotEmpty) driverName].join(' · '),
                              style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Text('Lacak', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.teksBerwarna(context, warna))),
                      Icon(Icons.chevron_right, size: 18, color: AppTheme.teksBerwarna(context, warna)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ProgresPesanan(layanan: service, status: status),
                ],
              ),
            ),
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
      backgroundColor: isDark ? AppTheme.bgObsidianDark : AppTheme.bgLight,
      // Header berlogo yang sama dengan penumpang (satu template), kecuali di
      // tab peta: di sana petanya yang harus terlihat penuh.
      appBar: _driverTabIndex == 0 ? null : _buildAppBar(driver: true),
      // IndexedStack, bukan if/else seperti sisi penumpang: peta yang dibuang
      // tiap pindah tab akan mengunduh ubinnya lagi saat kembali — itu kuota
      // driver — dan _driverMapController tertinggal menunjuk peta yang sudah
      // lepas, jadi _pindahPeta berikutnya menembak peta yang tidak ada.
      // Peta dan daftar lewat di belakang menu kaca (lihat _ruangNav).
      // removePadding: tanpa ini Scaffold menambahkan tinggi menu ke padding
      // bawah, dan daftar bersarang tanpa padding sendiri ikut menambah jarak.
      extendBody: true,
      body: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: IndexedStack(
          index: _driverTabIndex,
          children: [
            _buildDriverPeta(theme, isDark),
            _buildPendapatanBody(theme, isDark),
            _buildAkunBody(theme, isDark),
          ],
        ),
      ),
      bottomNavigationBar: NavKaca(
        aktif: _driverTabIndex,
        saatPilih: (index) => setState(() {
          _driverTabIndex = index;
          // Ditarik saat tabnya dibuka, bukan di initState: driver yang tidak
          // pernah membukanya tidak perlu membayar kuotanya.
          if (index == 1) _pendapatanFuture ??= _tarikPendapatan();
        }),
        // Ikon 3D yang sama dengan menu penumpang. Pendapatan = papan klip
        // riwayat (belum ada ikon dompet 3D di set rancangan).
        item: const [
          (ikon: Icons.map, gambar: 'assets/images/nav_beranda.png', label: 'Beranda', lencana: 0),
          (ikon: Icons.account_balance_wallet, gambar: 'assets/images/nav_aktivitas.png', label: 'Pendapatan', lencana: 0),
          (ikon: Icons.person, gambar: 'assets/images/nav_akun.png', label: 'Akun', lencana: 0),
        ],
      ),
    );
  }

  /// Tarik-ke-bawah dan tombol muat ulang di beranda driver: saldo, status
  /// pesanan berjalan (atau yang hilang dari layar), dan orderan yang tadi
  /// terlewat atau dilewati — ditawarkan lagi kalau belum diambil orang.
  Future<void> _segarkanDriver() async {
    _pesananDitolak.clear();
    final profil = _fetchUserProfile();
    if (_acceptedOrder != null) {
      await _checkAcceptedOrderStatus();
    } else {
      await _pulihkanPesananBerjalan();
      if (_acceptedOrder == null) await _cariOrderan();
    }
    await profil;
    if (mounted && _isOnline && _acceptedOrder == null && !_hasIncomingOrder) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Belum ada orderan di sekitarmu.')),
      );
    }
  }

  Widget _buildDriverPeta(ThemeData theme, bool isDark) {
    return Stack(
        children: [
          // Peta driver. Label "Jemput"/"Tujuan" muncul saat penandanya diketuk.
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: _orderPickupLatLng ?? _driverLatLng, zoom: 14),
              // Tombol bawaan Google bertabrakan dengan tombol driver di atas peta.
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              myLocationButtonEnabled: false,
              onMapCreated: (peta) {
                _driverMapController = peta;
                // GPS bisa lebih cepat dari peta; gerakan kameranya tadi terlewat.
                if (_posisiTerbaca && _acceptedOrder == null && !_hasIncomingOrder) _pindahPeta(_driverLatLng, 15);
              },
              polylines: {
                // Ruas 1: driver menuju titik jemput (biru)
                if (_driverRoutePoints.isNotEmpty)
                  Polyline(
                    polylineId: const PolylineId('driver'),
                    points: _driverRoutePoints,
                    color: AppTheme.primaryBlue,
                    width: 5,
                  ),
                // Ruas 2: titik jemput menuju tujuan (hijau)
                if (_dropoffRoutePoints.isNotEmpty)
                  Polyline(
                    polylineId: const PolylineId('antar'),
                    points: _dropoffRoutePoints,
                    color: Colors.green.shade600,
                    width: 4,
                  ),
              },
              markers: {
                if (_orderPickupLatLng != null && !_sudahDijemput)
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
                // zIndex 1 di penandaMotor: tergambar di atas pin lain.
                if (_posisiTerbaca)
                  penandaMotor(
                    titik: _driverLatLng,
                    judul: 'Posisimu',
                    ikon: _kendaraan == 'mobil' ? Icons.directions_car : Icons.two_wheeler,
                  ),
              },
            ),
          ),

          // Tombol di atas peta, tanpa sapaan dan latar: yang perlu terlihat
          // driver adalah petanya. Tiap tombol membawa latarnya sendiri.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                // Gaya tombol header penumpang (putih, sudut 16, garis tipis).
                // Lencana "AKTIF/OFFLINE" terpisah dibuang: pil status sudah
                // menunjukkan keadaannya lewat titik, tulisan, dan sakelar.
                child: Row(
                    children: [
                      _pilStatusDriver(isDark, sakelar: true),
                      const Spacer(),
                      // Pindai QR setoran. Hanya muncul kalau memang ada komisi
                      // yang belum disetor — driver yang tidak berutang tidak
                      // punya QR untuk dipindai, dan tombol yang selalu ada
                      // hanya menambah tebakan di layar yang sudah padat.
                      if (_walletBalance < 0) ...[
                        Tooltip(
                          message: 'Pindai QR setoran komisi',
                          child: _tombolHeader(icon: Icons.qr_code_scanner, isDark: isDark, bertanda: true, onTap: _pindaiSetoran),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Tooltip(
                        message: 'Keluar',
                        child: _tombolHeader(icon: Icons.logout, isDark: isDark, onTap: _logout),
                      ),
                    ],
                  ),
              ),
            ),
          ),

          // Bottom Section (States: Offline, Online-Radar, Incoming Order).
          // Peta tidak bisa ditarik untuk menyegarkan — geser ke bawah di sana
          // menggeser peta — jadi panel inilah yang ditarik.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: RefreshIndicator(
              onRefresh: _segarkanDriver,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  // RefreshIndicator melonggarkan lebarnya; tanpa stretch panel
                  // menyusut selebar isinya dan menempel ke kiri.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_acceptedOrder != null && _panelKecil)
                      _barKecilDriver(isDark)
                    else ...[
                      if (!_panelKecil && (_acceptedOrder != null || _hasIncomingOrder)) _tombolLihatPeta(isDark),
                      if (_saldoMenipis) _kartuSaldoDriver(isDark),
                      _buildBottomPanel(isDark, theme),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
    );
  }

  /// Tombol di atas panel pesanan berjalan: ketuk atau usap ke bawah untuk
  /// menciutkan panel dan melihat peta.
  Widget _tombolLihatPeta(bool isDark) => Center(
        child: GestureDetector(
          onVerticalDragEnd: _usapPanelDriver,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              shape: const StadiumBorder(),
              elevation: 3,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => setState(() => _panelKecil = true),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard_arrow_down, size: 20),
                      SizedBox(width: 4),
                      Text('Lihat peta', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Panel pesanan berjalan yang diciutkan: arah berikutnya, perkiraan tiba,
  /// dan alamatnya. Ketuk atau usap ke atas untuk membuka rincian dan tombol aksi.
  Widget _barKecilDriver(bool isDark) {
    final o = _acceptedOrder!;
    final warna = _sudahDijemput ? Colors.green.shade700 : AppTheme.primaryBlue;
    final alamat = _sudahDijemput ? '${o['dropoff'] ?? ''}' : _cleanPickupAddress(o['pickup']);
    final eta = teksEstimasi(_ruteAktif, _driverLatLng);
    return Semantics(
      button: true,
      label: 'Buka rincian pesanan',
      child: GestureDetector(
        onTap: () => setState(() => _panelKecil = false),
        onVerticalDragEnd: _usapPanelDriver,
        child: Container(
          margin: EdgeInsets.fromLTRB(16, 16, 16, _ruangNav),
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 15)],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: warna, shape: BoxShape.circle),
                child: Icon(_sudahDijemput ? Icons.flag : ikonLayanan('${o['service'] ?? ''}'), color: Colors.white, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eta == null ? _arahBerikut(o) : '${_arahBerikut(o)}: $eta',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: AppTheme.teksBerwarna(context, warna)),
                    ),
                    if (alamat.isNotEmpty)
                      Text(alamat, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context))),
                  ],
                ),
              ),
              const Icon(Icons.keyboard_arrow_up),
            ],
          ),
        ),
      ),
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
  ///
  /// Riwayatnya dimuat 50 pesanan sekali jalan, sisanya saat digulir.
  // ponytail: "hari ini" dijumlah dari yang sudah dimuat; 50 pesanan terbaru
  // menutup sehari penuh driver mana pun. Pindahkan penjumlahan ke server
  // kalau ada driver yang lebih dari 50 pesanan sehari.
  Future<Map<String, dynamic>> _tarikPendapatan() async {
    final r = await ApiService().getOrders(limit: 50);
    _pendapatanLama = [];
    _pendapatanHalaman = 1;
    _pendapatanAdaLagi = r['ada_lagi'] == true;
    return r;
  }

  Future<void> _muatPendapatanLagi(List<dynamic> sudah) async {
    if (_pendapatanMemuat || !_pendapatanAdaLagi) return;
    setState(() => _pendapatanMemuat = true);
    try {
      final r = await ApiService().getOrders(page: _pendapatanHalaman + 1, limit: 50);
      final ada = {for (final o in sudah) o['id']};
      if (!mounted) return;
      setState(() {
        _pendapatanLama = [..._pendapatanLama, ...((r['orders'] as List?) ?? []).where((o) => !ada.contains(o['id']))];
        _pendapatanHalaman++;
        _pendapatanAdaLagi = r['ada_lagi'] == true;
      });
    } catch (_) {
      // Tombol "Muat riwayat lama" tetap ada untuk mencoba lagi.
    } finally {
      if (mounted) setState(() => _pendapatanMemuat = false);
    }
  }

  Widget _buildPendapatanBody(ThemeData theme, bool isDark) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _pendapatanFuture = _tarikPendapatan());
        // Saldo komisi di atas riwayat ikut dibaca ulang.
        await Future.wait([_pendapatanFuture!, _fetchUserProfile()]);
      },
      child: FutureBuilder<Map<String, dynamic>>(
        future: _pendapatanFuture,
        builder: (context, snapshot) {
          if (_pendapatanFuture == null || snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final pesan = snapshot.hasError ? "Riwayat gagal dimuat. Tarik ke bawah untuk mencoba lagi." : null;

          final semua = [...((snapshot.data?['orders'] as List?) ?? []), ..._pendapatanLama];
          final selesai = semua.where((o) => o['driver_phone'] == widget.phone && o['status'] == 'completed').toList()
            ..sort((a, b) => _waktuSelesai(b).compareTo(_waktuSelesai(a)));

          final hariIni = selesai.where((o) => _hariIni(_waktuSelesai(o))).toList();
          final total = hariIni.fold<double>(0, (jumlah, o) => jumlah + _bagianDriver(o));

          return NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 600) _muatPendapatanLagi(semua);
              return false;
            },
            child: ListView(
            // Wajib, kalau tidak daftar yang pendek atau kosong tidak bisa
            // ditarik untuk menyegarkan.
            physics: const AlwaysScrollableScrollPhysics(),
            // Atas cukup 16: header berlogo (app bar) sudah memakan status bar.
            padding: EdgeInsets.fromLTRB(16, 16, 16, _ruangNav),
            children: [
              // Gaya banner beranda penumpang: gradien "biru" banner, sudut 28,
              // bayangan biru, ilustrasi 3D di kanan.
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: bannerWarna['biru']!, begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [BoxShadow(color: const Color(0xFF0066FF).withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 10))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Pendapatan hari ini', style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              Text(
                                _rupiah(total),
                                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900),
                              ),
                            ],
                          ),
                        ),
                        Image.asset(asetLayanan(_kendaraan == 'mobil' ? 'BohCar' : 'BohRide')!, width: 72, height: 72, cacheWidth: 216),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Saldo dan tombol top up ditaruh di sini, bukan cuma di
                    // kartu peringatan: driver yang saldonya masih aman tetap
                    // butuh jalan untuk mengisi sebelum kehabisan di jalan.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Saldo komisi ${_rupiah(_walletBalance)}',
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _showTopUpDialog,
                          icon: const Icon(Icons.add, size: 15, color: Colors.white),
                          label: const Text('Isi saldo', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${hariIni.length} pesanan selesai hari ini · sudah dipotong komisi',
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Kartu yang sama dengan di layar utama, supaya driver tidak
              // membaca dua versi berbeda tentang saldo yang sama.
              if (_saldoMenipis)
                _kartuSaldoDriver(isDark, margin: const EdgeInsets.only(bottom: 20)),
              _judulBagian('Riwayat pesanan', 'Pesanan selesai, sudah dipotong komisi',
                  label: 'Pendapatan', pad: const EdgeInsets.fromLTRB(0, 4, 0, 12)),
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
              if (pesan == null && _pendapatanAdaLagi)
                Center(
                  child: _pendapatanMemuat
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)))
                      : TextButton.icon(onPressed: () => _muatPendapatanLagi(semua), icon: const Icon(Icons.expand_more), label: const Text('Muat riwayat lama')),
                ),
            ],
          ),
          );
        },
      ),
    );
  }

  /// Di bawah nilai ini driver diperingatkan. Bukan angka ajaib: sekitar tiga
  /// sampai empat komisi pesanan pendek, cukup untuk sempat top up sebelum
  /// gerbang saldo di server mulai menolak pesanan tunai.
  static const double _ambangSaldoMenipis = 10000;

  bool get _saldoMenipis => _saldoDimuat && _walletBalance < _ambangSaldoMenipis;

  /// Pita peringatan saldo di layar utama driver.
  ///
  /// Muncul di dua keadaan yang beda akibatnya: saldo menipis masih boleh
  /// narik, saldo minus sudah tidak. Server yang menolak pesanannya, jadi
  /// peringatan ini yang membuat penolakan itu tidak datang mengagetkan.
  Widget _kartuSaldoDriver(bool isDark, {EdgeInsets? margin}) {
    final minus = _walletBalance < 0;
    final warna = minus ? AppTheme.errorColor : Colors.orange;
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.cardObsidianDark : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: warna.withOpacity(0.45)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(minus ? Icons.block : Icons.warning_amber_rounded, color: warna, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  minus
                      ? 'Pesanan tunai ditolak sampai saldo diisi'
                      : 'Saldo menipis — ${_rupiah(_walletBalance)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            minus
                ? 'Komisi ${_rupiah(-_walletBalance)} belum disetor. Isi saldo atau setor tunai ke petugas.'
                : 'Komisi pesanan tunai dipotong dari saldo. Isi saldo supaya tetap bisa menerima pesanan.',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _showTopUpDialog,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Isi saldo'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              if (minus) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pindaiSetoran,
                    icon: const Icon(Icons.qr_code_scanner, size: 16),
                    label: const Text('Setor tunai'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Melepas pesanan yang sudah diterima supaya driver lain bisa mengambilnya.
  ///
  /// Dikonfirmasi dulu karena penumpangnya sudah menunggu, dan karena komisi
  /// pesanan ini menahan saldo driver sampai pesanannya bergerak.
  Future<void> _lepasPesanan() async {
    final orderId = _acceptedOrder?['id'];
    if (orderId == null) return;

    // Alasannya dicatat untuk admin: driver yang sering melepas pesanan
    // (memilih-milih orderan) jadi terlihat.
    final alasan = await pilihAlasan(
      context,
      judul: 'Lepas pesanan ini?',
      isi: 'Pesanan dikembalikan ke papan orderan supaya driver lain bisa mengambilnya, '
          'dan komisinya tidak lagi menahan saldomu. Apa alasannya?',
      pilihan: const ['Kendaraan bermasalah', 'Pemesan tidak bisa dihubungi', 'Lokasi jemput terlalu jauh', 'Pemesan minta dibatalkan', alasanLainnya],
      tombol: 'Lepas',
      batal: 'Batal',
    );
    if (alasan == null || !mounted) return;

    try {
      await ApiService().lepasPesanan(orderId, alasan: alasan);
      if (!mounted) return;
      setState(_tutupPesananDriver);
      // Saldo dibaca ulang: komisi yang tadi tertahan sekarang bebas lagi.
      await _fetchUserProfile();
      if (!mounted) return;
      _beriTahu('Pesanan dikembalikan ke papan orderan');
    } catch (e) {
      if (!mounted) return;
      _beriTahu(pesanGalat(e));
    }
  }

  Future<void> _pindaiSetoran() async {
    final hasil = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => PindaiQRScreen(
          judul: 'Pindai QR Setoran',
          petunjuk: 'Arahkan ke QR di layar petugas',
          onKode: (isi) => ApiService().klaimSetoran(isi),
        ),
      ),
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

    // Bingkai & ikon 3D sama dengan kartu riwayat penumpang (_kartuRiwayat).
    final redup = AppTheme.teksRedup(context);
    final service = (o['service'] ?? 'BohRide').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: _kotakKartu(isDark, radius: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ikonLayanan3D(service, isDark),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(service, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                    Text(
                      _rupiah(_bagianDriver(o)),
                      style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.teksBerwarna(context, AppTheme.primaryDarkBlue), fontSize: 15),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${o['pickup'] ?? '-'} → ${o['dropoff'] ?? '-'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 4),
                Text(
                  '${dua(waktu.day)}/${dua(waktu.month)}/${waktu.year} · ${dua(waktu.hour)}:${dua(waktu.minute)}',
                  style: TextStyle(color: redup, fontSize: 11.5),
                ),
              ],
            ),
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

  /// Yang dibayar pemesan: ongkos + biaya jasa + makanan — angka yang sama
  /// persis dengan layar penumpang. Dulu driver hanya melihat `fare`, menagih
  /// kurang Rp1.000, lalu biaya jasanya tetap dipotong dari saldonya. Pesanan
  /// kurir toko Kasvo menyimpan food_total 0, jadi rumus ini berlaku juga.
  ///
  /// Diskon voucher dikurangkan: pemesan membayar lebih sedikit, dan potongan
  /// saldo driver ikut berkurang sebesar itu — pendapatan driver tetap.
  double _tagihan(dynamic o) =>
      ((o['fare'] as num?)?.toDouble() ?? 0) +
      ((o['biaya_jasa'] as num?)?.toDouble() ?? 0) +
      ((o['food_total'] as num?)?.toDouble() ?? 0) -
      ((o['diskon'] as num?)?.toDouble() ?? 0);

  static String _caraBayar(Map<String, dynamic> o) => o['payment_method'] == 'wallet' ? 'Lunas lewat saldo' : 'Tagih tunai';

  /// Kartu orderan masuk: angka besar yang ditagih, rinciannya, lalu
  /// pendapatan driver terpisah — dulu labelnya "Tarif Bersih" padahal angkanya
  /// belum dipotong komisi, dan notifikasinya menyebut angka ketiga.
  Widget _barisTagihan(Map<String, dynamic> o) {
    final ongkos = (o['fare'] as num?)?.toDouble() ?? 0;
    final jasa = (o['biaya_jasa'] as num?)?.toDouble() ?? 0;
    final makanan = (o['food_total'] as num?)?.toDouble() ?? 0;
    final diskon = (o['diskon'] as num?)?.toDouble() ?? 0;
    final rincian = [
      if (makanan > 0) 'Makanan ${_rupiah(makanan)}',
      '${o['service'] == 'BohFood' ? 'Ongkir' : 'Ongkos'} ${_rupiah(ongkos)}',
      if (jasa > 0) 'biaya jasa ${_rupiah(jasa)}',
    ].join(' + ') + (diskon > 0 ? ' − diskon ${_rupiah(diskon)} (ditanggung BohAntar)' : '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_caraBayar(o), style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
            Text(_rupiah(_tagihan(o)), style: const TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 24)),
          ],
        ),
        Text(rincian, style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
        const SizedBox(height: 4),
        Text(
          'Pendapatanmu ${_rupiah(_bagianDriver(o))} (sudah dipotong komisi)',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.teksBerwarna(context, Colors.green.shade700)),
        ),
      ],
    );
  }

  bool _hariIni(DateTime t) {
    final kini = DateTime.now();
    return t.year == kini.year && t.month == kini.month && t.day == kini.day;
  }

  static String _rupiah(double nilai) =>
      'Rp ${nilai.toStringAsFixed(0).replaceAllMapped(RegExp(r"(\d{1,3})(?=(\d{3})+(?!\d))"), (m) => "${m[1]}.")}';

  /// Layanan yang mengantar barang, bukan orang.
  static bool _kirimBarang(Map<String, dynamic>? o) {
    final s = (o?['service'] ?? '').toString();
    return s == 'BohAntar' || s == 'BohSend' || s == 'BohFood';
  }

  static bool _makanan(Map<String, dynamic>? o) => (o?['service'] ?? '') == 'BohFood';

  static String _labelJemput(Map<String, dynamic>? o) =>
      _makanan(o) ? 'Ambil di warung' : _kirimBarang(o) ? 'Ambil Barang' : 'Jemput Penumpang';

  static String _labelTombolAmbil(Map<String, dynamic>? o) =>
      _makanan(o) ? 'MAKANAN SUDAH DIAMBIL' : _kirimBarang(o) ? 'AMBIL BARANG' : 'AMBIL PENUMPANG';

  /// Isi kiriman, ditampilkan sebelum driver menekan Terima.
  ///
  /// Tanpa ini sebuah kulkas dan sebuah map dokumen terlihat persis sama di
  /// panel driver: cuma dua alamat dan satu angka tarif. Catatan penumpang baru
  /// ikut setelah pesanan diterima — papan orderan memang tidak mengirimnya.
  Widget _detailBarang(Map<String, dynamic> o, {bool tampilkanCatatan = false}) {
    if (!_kirimBarang(o)) return const SizedBox.shrink();
    if (_makanan(o)) return _detailMakanan(o, tampilkanCatatan);

    final jenis = (o['package_type'] ?? '').toString();
    final jumlah = (o['package_quantity'] as num?)?.toInt() ?? 0;
    final berat = (o['package_weight'] ?? '').toString();
    final catatan = tampilkanCatatan ? (o['package_notes'] ?? '').toString().trim() : '';
    // Penerima ikut disembunyikan sebelum diterima, sama seperti nomor pemesan.
    final teleponPenerima = tampilkanCatatan ? (o['receiver_phone'] ?? '').toString().trim() : '';
    final penerima = [
      if (tampilkanCatatan) (o['receiver_name'] ?? '').toString().trim(),
      teleponPenerima,
    ].where((s) => s.isNotEmpty).join(' · ');
    final tanda = [
      // Sama dengan label yang dipilih pemesan. "Diasuransikan" dibuang:
      // tidak ada asuransi apa pun, flag ini cuma minta ekstra hati-hati.
      if (o['special_handling'] == true) '⚠ Mudah pecah',
      if (o['insurance'] == true) '💎 Barang berharga',
    ];

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.inventory_2_outlined, size: 16, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  [
                    jenis.isEmpty ? 'Barang' : jenis,
                    if (jumlah > 0) '$jumlah pcs',
                    if (berat.isNotEmpty) berat,
                  ].join(' · '),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),
          if (tanda.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tanda.join('   '), style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
          if (penerima.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: teleponPenerima.isEmpty ? null : () => launchUrl(Uri.parse('tel:$teleponPenerima')),
                child: Row(
                  children: [
                    const Icon(Icons.person_pin_circle_outlined, size: 16, color: AppTheme.primaryBlue),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Penerima: $penerima', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                    if (teleponPenerima.isNotEmpty) const Icon(Icons.phone, size: 16, color: Colors.green),
                  ],
                ),
              ),
            ),
          if (catatan.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Catatan: $catatan', style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// Pesanan makanan untuk driver: apa yang dibeli, di warung mana, dan berapa
  /// yang harus ia talangi — angka yang menentukan apakah ia sanggup mengambil
  /// orderan ini, jadi tampil sebelum tombol Terima.
  Widget _detailMakanan(Map<String, dynamic> o, bool tampilkanCatatan) {
    final items = (o['items'] as List?) ?? [];
    final talangan = (o['food_total'] as num?)?.toDouble() ?? 0;
    final ongkir = (o['fare'] as num?)?.toDouble() ?? 0;
    // Pada pesanan tunai biaya jasa ikut diterima driver dari pelanggan, lalu
    // disetor lewat saldo. Kalau tidak ikut ditagih, driver yang menanggungnya.
    final biayaJasa = (o['biaya_jasa'] as num?)?.toDouble() ?? 0;
    final tunai = (o['payment_method'] ?? 'cash') != 'wallet';
    final catatan = tampilkanCatatan ? (o['package_notes'] ?? '').toString().trim() : '';
    final noKasir = (o['kasvo_pesanan_id'] as num?)?.toInt() ?? 0;
    // Kurir untuk pelanggan toko Kasvo: makanannya sudah lunas ke toko, driver
    // cuma mengambil dan menagih ongkir ke penerima. Tanpa pembeda ini panel
    // menyuruhnya "Beli di warung" dan "Bayar ke warung Rp0".
    final kurirToko = ((o['kasvo_pengantaran_id'] as num?)?.toInt() ?? 0) > 0;
    // Penerima ikut disembunyikan sebelum diterima, sama seperti BohAntar.
    final hpPenerima = tampilkanCatatan ? (o['receiver_phone'] ?? '').toString().trim() : '';

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.restaurant, size: 16, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${kurirToko ? 'Ambil di' : 'Beli di'} ${o['merchant_name'] ?? 'warung'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ],
          ),
          // Pesanan toko Kasvo sudah dikirim ke kasirnya. Tanpa pesan ini driver
          // memesan ulang di loket dan dapur memasak dua kali.
          if (noKasir > 0)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(
                kurirToko
                    ? 'Pesanan toko No. $noKasir · sudah dibayar pelanggan\nSebutkan nomor ini ke kasir untuk mengambilnya.'
                    : 'Sudah masuk kasir warung · No. $noKasir\nSebutkan nomor ini ke kasir lalu bayar — tidak perlu pesan ulang.',
                style: TextStyle(fontSize: 12, color: Colors.green.shade800, fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 8),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 30, child: Text('${it['qty'] ?? 0}×', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  // Varian ikut tampil: driver memesan di kasir persis sesuai
                  // daftar ini, jadi "Kopi" saja tidak cukup.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((it['name'] ?? '').toString(), style: const TextStyle(fontSize: 12)),
                        if ((it['options'] as List?)?.isNotEmpty ?? false)
                          Text(
                            [for (final o in it['options'] as List) '${o['group']}: ${o['name']}'].join(' · '),
                            style: TextStyle(fontSize: 11, color: Colors.orange.shade900, fontWeight: FontWeight.w600),
                          ),
                      ],
                    ),
                  ),
                  if (!kurirToko)
                    Text(
                      _rupiah(((it['price'] as num?)?.toDouble() ?? 0) * ((it['qty'] as num?)?.toDouble() ?? 0)),
                      style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context)),
                    ),
                ],
              ),
            ),
          const Divider(height: 16),
          if (kurirToko) ...[
            Text('Makanan sudah dibayar pelanggan ke toko — kamu tidak membayar apa pun di kasir.',
                style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Tagih ke penerima (tunai)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                Text(_rupiah(ongkir + biayaJasa), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.orange.shade800)),
              ],
            ),
            Text('Ongkir${biayaJasa > 0 ? ' + biaya jasa' : ''}', style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
            if (tampilkanCatatan)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(Icons.person_pin_circle_outlined, size: 16, color: AppTheme.primaryBlue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Penerima: ${(o['receiver_name'] ?? '').toString().trim()} · $hpPenerima',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                    if (hpPenerima.isNotEmpty) ...[
                      IconButton(
                        tooltip: 'WhatsApp penerima',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.chat, size: 18, color: Color(0xFF128C7E)),
                        onPressed: () => _bukaWhatsApp(hpPenerima),
                      ),
                      IconButton(
                        tooltip: 'Telepon penerima',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.phone, size: 18, color: Colors.green),
                        onPressed: () => launchUrl(Uri.parse('tel:$hpPenerima')),
                      ),
                    ],
                  ],
                ),
              ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Bayar ke warung', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                Text(_rupiah(talangan), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.orange.shade800)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              tunai
                  ? 'Tagih ke pelanggan ${_rupiah(_tagihan(o))} (makanan + ongkir${biayaJasa > 0 ? ' + biaya jasa' : ''}${(o['diskon'] as num? ?? 0) > 0 ? ' − diskon' : ''})'
                  : 'Sudah lunas: uang makanan + ongkir masuk saldo kamu setelah selesai',
              style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context)),
            ),
          ],
          if (catatan.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Catatan: $catatan', style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// wa.me menuntut nomor internasional tanpa "+", jadi 08… diubah ke 628….
  /// [pesan] mengisi kolom ketik di WhatsApp lebih dulu.
  Future<void> _bukaWhatsApp(String nomor, {String? pesan}) async {
    var n = nomor.replaceAll(RegExp(r'\D'), '');
    if (n.startsWith('0')) n = '62${n.substring(1)}';
    final teks = pesan == null ? '' : '?text=${Uri.encodeComponent(pesan)}';
    if (!await launchUrl(Uri.parse('https://wa.me/$n$teks'), mode: LaunchMode.externalApplication)) {
      _beriTahu('WhatsApp tidak bisa dibuka');
    }
  }

  /// Memotret lalu mengunggah bukti serah-terima. Null kalau driver membatalkan
  /// atau unggahannya gagal — pemanggil berhenti, bukan melanjutkan tanpa bukti.
  Future<String?> _unggahFotoBukti(String judul) async {
    final sumber = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(judul, style: const TextStyle(fontWeight: FontWeight.bold))),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Ambil foto'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pilih dari galeri'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (sumber == null) return null;
    // Dikecilkan di HP: server menolak berkas di atas 5 MB.
    final foto = await ImagePicker().pickImage(source: sumber, maxWidth: 1600, imageQuality: 70);
    if (foto == null) return null;
    try {
      return await ApiService().uploadFoto(foto.path);
    } catch (e) {
      _beriTahu('Foto gagal diunggah: ${pesanGalat(e)}');
      return null;
    }
  }

  /// Nama orang yang menerima barang. Terisi awal dari nama penerima yang
  /// ditulis pemesan; driver tinggal membetulkan kalau yang menerima orang lain.
  /// Null kalau dibatalkan; boleh kosong kalau penerima tidak mau menyebut nama.
  Future<String?> _tanyaNamaPenerima() {
    var nama = (_acceptedOrder?['receiver_name'] ?? '').toString();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diterima oleh siapa?'),
        content: TextFormField(
          initialValue: nama,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Nama penerima'),
          onChanged: (v) => nama = v,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, nama.trim()), child: const Text('Lanjut foto')),
        ],
      ),
    );
  }

  Widget _buildBottomPanel(bool isDark, ThemeData theme) {
    // Perjalanan yang sedang berlangsung diperiksa lebih dulu daripada status
    // online. Driver yang mematikan tombolnya di tengah jalan tetap harus bisa
    // menekan Selesai — kalau tidak, pesanannya tidak pernah bisa ditutup.
    if (!_isOnline && _acceptedOrder == null) {
      // 1. OFFLINE PANEL
      return Container(
        padding: EdgeInsets.fromLTRB(24, 24, 24, _ruangNav + 4),
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
          children: _driverDinonaktifkan
              ? [
                  const Icon(Icons.block, size: 48, color: AppTheme.errorColor),
                  const SizedBox(height: 12),
                  const Text(
                    'Akun Driver Dinonaktifkan',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_alasanNonaktif.isEmpty ? '' : 'Alasan: $_alasanNonaktif\n'}'
                    'Kamu belum bisa menerima orderan. Hubungi admin BohAntar untuk mengaktifkan kembali.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                ]
              : [
                  // Kendaraan 3D driver (set ikon yang sama dengan penumpang).
                  _ikonLayanan3D(_kendaraan == 'mobil' ? 'BohCar' : 'BohRide', isDark, ukuran: 68),
                  const SizedBox(height: 12),
                  const Text(
                    'Kamu sedang offline',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Aktifkan tombol online di atas untuk mulai menerima orderan pelanggan.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                ],
        ),
      );
    }

    if (_acceptedOrder != null) {
      // 4. ACTIVE ORDER DRIVER PANEL
      return Container(
        padding: EdgeInsets.fromLTRB(24, 24, 24, _ruangNav + 4),
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
            if ((_acceptedOrder!['minta_batal_at'] ?? '').toString().isNotEmpty) _kotakMintaBatal(),
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
                        [_acceptedOrder!['service'] ?? 'Layanan', keteranganKelas(_acceptedOrder)].where((s) => s.isNotEmpty).join(' · '),
                        style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                // Sama dengan "Siapkan uang tunai" di layar penumpang.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _rupiah(_tagihan(_acceptedOrder!)),
                      style: const TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 18),
                    ),
                    Text(_caraBayar(_acceptedOrder!), style: TextStyle(fontSize: 11, color: AppTheme.teksRedup(context))),
                  ],
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
                      Text("📍 ${_labelJemput(_acceptedOrder)}: ${_cleanPickupAddress(_acceptedOrder!['pickup'])}", overflow: TextOverflow.ellipsis, maxLines: 2, style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 12),
                      Text("🏁 Antar ke: ${_acceptedOrder!['dropoff']}", overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                )
              ],
            ),
            _detailBarang(_acceptedOrder!, tampilkanCatatan: true),
            if (teksEstimasi(_ruteAktif, _driverLatLng) case final eta?) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.schedule, size: 16, color: AppTheme.primaryBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_arahBerikut(_acceptedOrder)}: $eta',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
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
                    // Barang difoto saat diambil: satu-satunya bukti kondisi
                    // awalnya kalau nanti ada sengketa.
                    String? foto;
                    if (_kirimBarang(_acceptedOrder)) {
                      foto = await _unggahFotoBukti('Foto barang saat diambil');
                      if (foto == null) return;
                    }
                    final res = await ApiService().pickupOrder(orderId, photoUrl: foto);
                    if (!mounted) return;
                    if (res['status'] == 'success') {
                      setState(() {
                        _acceptedOrder = res['order'];
                      });
                      // Rute pindah: dari posisi driver ke tujuan penumpang.
                      _setupDriverOrderRouting();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            service == "BohFood"
                                ? "Makanan sudah di tangan. Antar ke pelanggan!"
                                : _kirimBarang(_acceptedOrder)
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
                      SnackBar(content: Text(pesanGalat(e))),
                    );
                  }
                } else {
                  try {
                    String? foto;
                    String? penerima;
                    // ponytail: BohFood cukup tombol selesai — makanan diterima
                    // langsung oleh pemesan, nama+foto cuma menahan driver.
                    if (_kirimBarang(_acceptedOrder) && !_makanan(_acceptedOrder)) {
                      penerima = await _tanyaNamaPenerima();
                      if (penerima == null) return;
                      foto = await _unggahFotoBukti('Foto barang saat diserahkan');
                      if (foto == null) return;
                    }
                    final res = await ApiService().completeOrder(orderId, photoUrl: foto, receivedBy: penerima);
                    if (!mounted) return;
                    if (res['status'] == 'success') {
                      setState(_tutupPesananDriver);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Perjalanan berhasil diselesaikan!"), backgroundColor: Colors.green),
                      );
                      _fetchUserProfile();
                    }
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(pesanGalat(e))),
                    );
                  }
                }
              },
              icon: Icon(
                (_acceptedOrder!['status'] ?? 'accepted') == 'picked_up'
                    ? Icons.check_circle_outline
                    : _makanan(_acceptedOrder)
                        ? Icons.restaurant
                        : _kirimBarang(_acceptedOrder)
                            ? Icons.local_shipping
                            : Icons.person_pin_circle,
              ),
              label: Text(
                (_acceptedOrder!['status'] ?? 'accepted') == 'picked_up'
                    ? (_kirimBarang(_acceptedOrder) ? "SELESAIKAN PENGANTARAN" : "SELESAIKAN PERJALANAN")
                    : _labelTombolAmbil(_acceptedOrder),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: (_acceptedOrder!['status'] ?? 'accepted') == 'picked_up' ? Colors.green.shade700 : AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            // Hanya sebelum penumpang atau barangnya diambil. Sesudah itu driver
            // sudah memegang sesuatu milik orang lain dan harus lewat admin.
            if ((_acceptedOrder!['status'] ?? 'accepted') != 'picked_up')
              TextButton(
                onPressed: _lepasPesanan,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey,
                  minimumSize: const Size(double.infinity, 40),
                ),
                child: const Text(
                  'Tidak bisa melanjutkan? Lepas pesanan ini',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      );
    }

    if (_hasIncomingOrder && _currentIncomingOrder != null) {
      // 2. INCOMING ORDER BOTTOM OVERLAY
      return Container(
        padding: EdgeInsets.fromLTRB(24, 24, 24, _ruangNav + 4),
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
            // Ketuk atau usap kepala kartu untuk menyembunyikan/membuka rincian.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _panelKecil = !_panelKecil),
              onVerticalDragEnd: _usapPanelDriver,
              child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(ikonLayanan((_currentIncomingOrder!['service'] ?? '').toString()), color: AppTheme.primaryBlue),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('PESANAN MASUK!', style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryBlue, fontSize: 12, letterSpacing: 1)),
                        Text('Layanan ${_currentIncomingOrder!['service']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        // Driver bermobil kecil harus tahu sebelum menerima.
                        if (keteranganKelas(_currentIncomingOrder).isNotEmpty)
                          Text(keteranganKelas(_currentIncomingOrder), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppTheme.teksBerwarna(context, AppTheme.primaryBlue))),
                      ],
                    ),
                    ),
                  ],
                ),
                ),
                Icon(_panelKecil ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: AppTheme.teksRedup(context)),
                const SizedBox(width: 6),
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
            ),
            if (_panelKecil)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pendapatanmu ${_rupiah(_bagianDriver(_currentIncomingOrder!))}',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: AppTheme.teksBerwarna(context, Colors.green.shade700)),
                    ),
                    Text(
                      '${_labelJemput(_currentIncomingOrder)}: ${_cleanPickupAddress(_currentIncomingOrder!['pickup'])}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: AppTheme.teksRedup(context)),
                    ),
                  ],
                ),
              )
            else ...[
            const Divider(height: 32),

            _barisTagihan(_currentIncomingOrder!),
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
                        '📍 ${_labelJemput(_currentIncomingOrder)}: ${_cleanPickupAddress(_currentIncomingOrder!['pickup'])}',
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
            _detailBarang(_currentIncomingOrder!),
            const SizedBox(height: 24),
            ],

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
      padding: EdgeInsets.fromLTRB(24, 24, 24, _ruangNav + 4),
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
            'Pastikan GPS-mu aktif, lalu coba berkeliling ke area ramai.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          // Orderan yang terlewat hitung mundurnya atau dilewati tidak muncul
          // lagi sendiri; tombol ini menawarkannya lagi kalau belum diambil.
          OutlinedButton.icon(
            onPressed: _segarkanDriver,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Muat ulang orderan', style: TextStyle(fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primaryBlue,
              side: const BorderSide(color: AppTheme.primaryBlue),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  AppBar _buildAppBar({bool driver = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppBar(
      // Header putih bergaris bawah tipis seperti rancangan 16 Nov 2026.
      backgroundColor: isDark ? AppTheme.cardObsidianDark : Colors.white,
      elevation: 0,
      // Material 3 mewarnai app bar dengan surfaceTint begitu isinya tergulir di
      // bawahnya. Dua baris ini mematikannya.
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: isDark ? Colors.white10 : const Color(0xFFF1F5F9))),
      toolbarHeight: 66,
      // Kolom cari menempel di header (ikut diam saat beranda digulir), hanya di
      // tab Beranda penumpang. _currentTabIndex driver selalu 0, jadi dicek dulu.
      bottom: !driver && _currentTabIndex == 0
          ? PreferredSize(
              preferredSize: const Size.fromHeight(58),
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: _kolomCari(isDark)),
            )
          : null,
      // Logo resmi (B kapital, 10 Nov 2026), BUKAN logo di folder rancangan
      // yang masih "bohAntar". cacheHeight: berkasnya 864×288, slotnya 44 px.
      title: Image.asset(
        // Mode gelap: logo_gelap.png = logo.png dengan "Boh" + slogan navy jadi
        // putih (navy hilang di latar gelap); ikon & "Antar" tetap biru.
        isDark ? 'assets/images/logo_gelap.png' : 'assets/images/logo.png',
        height: 44,
        cacheHeight: 132,
        semanticLabel: 'BohAntar',
      ),
      actions: [
        // Driver: status online di tempat lonceng; ketuk = kembali ke peta.
        if (driver)
          _pilStatusDriver(isDark, saatTekan: () => setState(() => _driverTabIndex = 0))
        else
          _tombolHeader(
            icon: Icons.notifications_none,
            isDark: isDark,
            // Titik merah hanya menyala kalau memang ada yang perlu dilihat.
            // Lencana yang menyala terus berhenti berarti setelah sehari.
            bertanda: _riderActiveOrder != null,
            onTap: () => setState(() => _currentTabIndex = 1),
          ),
        // Tombol keluar dulu ada di sini, sebelah lonceng: satu ketukan
        // meleset dan penumpang terlempar ke layar masuk. Tempatnya di tab Akun.
        const SizedBox(width: 16),
      ],
    );
  }

  /// Pil status driver bergaya tombol header (putih, sudut 16, garis tipis):
  /// titik hijau/abu + "Online"/"Offline". Dengan [sakelar] ikut tombol
  /// geser untuk menyalakan; tanpa itu bisa diketuk ([saatTekan]).
  Widget _pilStatusDriver(bool isDark, {bool sakelar = false, VoidCallback? saatTekan}) {
    return Material(
      color: isDark ? AppTheme.cardObsidianDark : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: saatTekan,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 46,
          padding: EdgeInsets.only(left: 14, right: sakelar ? 4 : 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
            boxShadow: [if (!isDark) BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: _isOnline ? const Color(0xFF10B981) : const Color(0xFF94A3B8), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(_isOnline ? 'Online' : 'Offline', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              if (sakelar) Switch.adaptive(value: _isOnline, activeTrackColor: AppTheme.primaryDarkBlue, onChanged: _toggleOnline),
            ],
          ),
        ),
      ),
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
      // Pekat, bukan tembus: tombol yang sama dipakai di atas peta driver.
      color: isDark ? AppTheme.cardObsidianDark : Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isDark ? Colors.white12 : const Color(0xFFE2E8F0)),
            boxShadow: [if (!isDark) BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))],
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
