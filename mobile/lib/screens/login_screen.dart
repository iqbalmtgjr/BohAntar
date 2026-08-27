import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/notifikasi_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/decorative_background.dart';
import 'register_screen.dart';
import 'dashboard_screen.dart';


// Web Client ID dari Google Cloud — bukan Android Client ID. Android tetap butuh
// OAuth client sendiri (didaftarkan dengan SHA-1), tapi id_token yang dikirim ke
// backend harus beraudiens Web Client ID, karena backend mencocokkannya dengan
// GOOGLE_CLIENT_ID. Nilai ini bukan rahasia, aman ditaruh di dalam APK.
const String kGoogleServerClientId = 'GANTI_DENGAN_WEB_CLIENT_ID.apps.googleusercontent.com';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String _errorMessage = '';
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    // Inisialisasi GoogleSignIn v7 (singleton, konfigurasi via initialize)
    GoogleSignIn.instance.initialize(serverClientId: kGoogleServerClientId);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final response = await ApiService().login(
        _emailController.text.trim(),
        _passwordController.text,
      );
      if (response['status'] == 'success') {
        NotifikasiService().daftarkanPerangkat();
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(
                name: response['name'] ?? '',
                role: response['role'] ?? 'rider',
                phone: response['phone'] ?? '',
              ),
            ),
            (route) => false,
          );
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _goToRegister() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const RegisterScreen()),
    );
  }

  Future<void> _loginWithGoogle() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    try {
      // GoogleSignIn v7: gunakan authenticate() bukan signIn()
      final GoogleSignInAccount googleUser =
          await GoogleSignIn.instance.authenticate();

      final String? idToken = googleUser.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Google tidak mengembalikan id_token.');
      }

      await _authenticateGoogle(idToken);
    } on GoogleSignInException catch (e) {
      setState(() {
        _errorMessage = 'Gagal masuk dengan Google: ${e.description ?? e.code.name}';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Gagal masuk dengan Google: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _authenticateGoogle(String idToken, {String? phoneNumber}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    try {
      final response = await ApiService().googleLogin(idToken, phoneNumber: phoneNumber);
      if (response['status'] == 'success') {
        NotifikasiService().daftarkanPerangkat();
        final user = response['user'] as Map<String, dynamic>;
        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(
                name: user['name'] ?? '',
                role: user['role'] ?? 'rider',
                phone: user['phone_number'] ?? '',
              ),
            ),
            (route) => false,
          );
        }
      } else if (response['status'] == 'need_phone') {
        if (mounted) {
          final String? inputPhone = await _showPhoneInputDialog(context);
          if (inputPhone != null && inputPhone.isNotEmpty) {
            await _authenticateGoogle(idToken, phoneNumber: inputPhone);
          }
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<String?> _showPhoneInputDialog(BuildContext context) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        return AlertDialog(
          title: const Text('Lengkapi Nomor Handphone'),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Email Google Anda belum terdaftar. Silakan lengkapi nomor handphone aktif untuk membuat akun baru:',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: controller,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 16),
                  decoration: InputDecoration(
                    prefixIcon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: isDark ? Colors.blueGrey.shade700 : Colors.grey.shade300,
                            width: 1,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('🇮🇩', style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 6),
                          Text(
                            '+62',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ),
                    hintText: '812 3456 7890',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Nomor handphone tidak boleh kosong';
                    }
                    if (value.trim().length < 9) {
                      return 'Nomor handphone terlalu pendek';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              style: TextButton.styleFrom(foregroundColor: Colors.grey),
              child: const Text('Batal'),
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  String num = controller.text.trim();
                  if (num.startsWith('0')) num = num.substring(1);
                  if (!num.startsWith('+62')) num = '+62$num';
                  Navigator.pop(context, num);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Simpan & Daftar'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      // ponytail: splash dibuat putih polos biar menyatu dengan bg_login.png
      backgroundColor: _showSplash && !isDark ? Colors.white : null,
      body: Stack(
        children: [
          if (!_showSplash || isDark) const DecorativeCircles(),
          SafeArea(
            child: _showSplash
                ? _buildSplashLayout(theme, isDark)
                : _buildLoginInputLayout(theme, isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildSplashLayout(ThemeData theme, bool isDark) {
    return Column(
      children: [
        const SizedBox(height: 40),
        // Logo Image
        Image.asset(
          'assets/images/logo.png',
          height: 64,
          color: isDark ? Colors.white : null,
          colorBlendMode: isDark ? BlendMode.srcIn : null,
        ),
        
        // Scooter Illustration
        Expanded(
          child: Transform.scale(
            scale: 1.35,
            child: Image.asset(
              'assets/images/bg_login.png',
              fit: BoxFit.contain,
            ),
          ),
        ),
        
        // Welcome and Buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              Text(
                'Selamat datang di',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'bohAntar',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.primaryBlue,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _showSplash = false;
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text('Masuk'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _goToRegister,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.primaryBlue, width: 2),
                  foregroundColor: AppTheme.primaryBlue,
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, fontFamily: 'Inter'),
                ),
                child: const Text('Daftar'),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLoginInputLayout(ThemeData theme, bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Back Arrow Button
            IconButton(
              onPressed: () {
                setState(() {
                  _showSplash = true;
                });
              },
              icon: const Icon(Icons.arrow_back_ios, size: 20),
              color: isDark ? Colors.white : Colors.black87,
            ),
            const SizedBox(height: 20),
            
            // Header Logo
            Align(
              alignment: Alignment.centerLeft,
              child: Image.asset(
                'assets/images/logo.png',
                height: 44,
                color: isDark ? Colors.white : null,
                colorBlendMode: isDark ? BlendMode.srcIn : null,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Selamat Datang!',
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Masuk dengan email dan password akun bohAntar Anda.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 40),

            // Email Input
            Text(
              'Alamat Email',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(
                hintText: 'nama@email.com',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Email tidak boleh kosong';
                }
                return null;
              },
            ),
            const SizedBox(height: 24),

            // Password Input
            Text(
              'Password',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => _isLoading ? null : _submitLogin(),
              decoration: InputDecoration(
                hintText: 'Masukkan password Anda',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Password tidak boleh kosong';
                }
                return null;
              },
            ),

            if (_errorMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                _errorMessage,
                style: const TextStyle(color: AppTheme.errorColor, fontWeight: FontWeight.w500),
              ),
            ],

            const SizedBox(height: 40),
            
            // Submit Button
            ElevatedButton(
              onPressed: _isLoading ? null : _submitLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text('Masuk'),
            ),

            const SizedBox(height: 16),
            Center(
              child: TextButton(
                onPressed: _isLoading ? null : _goToRegister,
                child: const Text.rich(
                  TextSpan(
                    text: 'Belum punya akun? ',
                    children: [
                      TextSpan(
                        text: 'Daftar di sini',
                        style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryBlue),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: Divider(color: isDark ? Colors.blueGrey.shade700 : Colors.grey.shade300)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text("Atau masuk dengan", style: TextStyle(color: Colors.grey, fontSize: 13)),
                ),
                Expanded(child: Divider(color: isDark ? Colors.blueGrey.shade700 : Colors.grey.shade300)),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _loginWithGoogle,
              icon: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Text(
                  'G',
                  style: TextStyle(
                    color: Color(0xFF4285F4),
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              label: const Text('Masuk dengan Google'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
                side: BorderSide(color: isDark ? Colors.blueGrey.shade700 : Colors.grey.shade300),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                foregroundColor: isDark ? Colors.white : Colors.black87,
              ),
            ),

            const SizedBox(height: 24),
            // Dulu ini teks mati: pengguna diminta menyetujui dokumen yang tidak
            // bisa dibuka dan memang belum ada. Sekarang menuju halaman
            // kebijakan privasi yang sungguhan.
            Center(
              child: TextButton(
                onPressed: () async {
                  final url = Uri.parse(ApiService().privacyUrl);
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                },
                style: TextButton.styleFrom(
                  foregroundColor: isDark ? Colors.blueGrey.shade300 : Colors.grey.shade700,
                ),
                child: const Text(
                  'Dengan melanjutkan, Anda menyetujui Kebijakan Privasi kami.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, decoration: TextDecoration.underline),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
