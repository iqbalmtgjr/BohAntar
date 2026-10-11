import 'package:flutter/material.dart';
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
      final hasToken = await apiService.tryAutoLogin();
      
      if (hasToken) {
        // Fetch user profile from backend using persisted token
        final profileResponse = await apiService.getProfile();
        if (profileResponse['status'] == 'success') {
          // Sesi lama dipulihkan: token perangkat ikut didaftarkan ulang, kalau
          // tidak notifikasi berhenti sampai pengguna login manual lagi.
          NotifikasiService().daftarkanPerangkat();
          final user = profileResponse['user'] as Map<String, dynamic>;
          setState(() {
            _targetScreen = DashboardScreen(
              name: user['name'] ?? '',
              role: user['role'] ?? 'rider',
              phone: user['phone_number'] ?? '',
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
