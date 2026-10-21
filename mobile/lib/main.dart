import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/screens/login_screen.dart';
import 'package:mobile/screens/dashboard_screen.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/notifikasi_service.dart';
import 'package:mobile/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Disiapkan sebelum runApp supaya pesan yang membuka aplikasi dari notifikasi
  // tidak hilang. Gagal dengan diam kalau Firebase belum dikonfigurasi.
  await NotifikasiService().mulai();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bohAntar',
      debugShowCheckedModeBanner: false,
      // Dipakai NotifikasiService untuk membuka layar chat dari notifikasi.
      navigatorKey: NotifikasiService.navigatorKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _checkingAuth = true;
  Widget _targetScreen = const LoginScreen();

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    try {
      final apiService = ApiService();
      // Diperiksa sebelum sesi dipulihkan: versi yang sudah tidak dilayani
      // jangan sampai sempat memanggil API yang mungkin sudah berubah.
      if (await apiService.perluPerbarui()) {
        setState(() => _targetScreen = const _LayarPerbarui());
        return;
      }
      final hasToken = await apiService.tryAutoLogin();
      
      if (hasToken) {
        // Fetch user profile from backend using persisted token
        final profileResponse = await apiService.getProfile();
        if (profileResponse['status'] == 'success') {
          // Sesi lama dipulihkan: token perangkat ikut didaftarkan ulang, kalau
          // tidak notifikasi berhenti sampai pengguna login manual lagi.
          NotifikasiService().daftarkanPerangkat();
          // Aplikasi dinyalakan dari notifikasi chat: buka chatnya setelah
          // beranda tergambar, supaya tombol kembali mendarat di beranda.
          WidgetsBinding.instance.addPostFrameCallback((_) => NotifikasiService().bukaChatDariPeluncuran());
          final user = profileResponse['user'] as Map<String, dynamic>;
          final phone = user['phone_number'] ?? '';
          final role = await DashboardScreen.peranTampil(user['role'] ?? 'rider', phone);
          setState(() {
            _targetScreen = DashboardScreen(
              name: user['name'] ?? '',
              role: role,
              phone: phone,
            );
          });
        }
      }
    } catch (e) {
      // If server is offline or token is invalid, fallback to LoginScreen
      debugPrint("Auto login failed: $e");
    } finally {
      setState(() {
        _checkingAuth = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingAuth) {
      // Logo penuh dibalik jadi putih di mode gelap, sama seperti di layar
      // login: tulisan "boh" berwarna navy dan hilang di atas latar gelap.
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/logo.png',
                height: 56,
                color: isDark ? Colors.white : null,
                colorBlendMode: isDark ? BlendMode.srcIn : null,
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(
                color: AppTheme.primaryBlue,
                strokeWidth: 3,
              ),
            ],
          ),
        ),
      );
    }
    return _targetScreen;
  }
}

// Layar buntu untuk versi yang sudah tidak dilayani server. Sengaja tanpa
// tombol "nanti saja": versi ini mungkin memanggil domain atau API yang sudah
// berubah, jadi melanjutkan hanya berujung galat yang membingungkan.
class _LayarPerbarui extends StatelessWidget {
  const _LayarPerbarui();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.system_update, size: 64, color: AppTheme.primaryBlue),
              const SizedBox(height: 24),
              const Text('Perbarui bohAntar',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              const Text(
                'Versi aplikasi ini sudah tidak didukung. Perbarui lewat Google Play untuk melanjutkan.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://play.google.com/store/apps/details?id=com.bohantar.mobile'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Buka Google Play'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
