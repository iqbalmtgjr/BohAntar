import 'package:flutter/material.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/services/notifikasi_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/decorative_background.dart';
import 'dashboard_screen.dart';
import 'driver_register_screen.dart';

class RegisterScreen extends StatefulWidget {
  // Kosong berarti nomor HP diisi di layar ini. Diisi hanya kalau pendaftaran
  // datang dari alur yang sudah tahu nomornya (mis. OTP, kalau dihidupkan lagi).
  final String phoneNumber;

  const RegisterScreen({
    super.key,
    this.phoneNumber = '',
  });

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Pendaftaran dari aplikasi selalu menghasilkan penumpang; backend menolak
  // role lain dari endpoint publik ini.
  static const _role = 'rider';
  bool _isLoading = false;
  bool _obscurePassword = true;
  String _errorMessage = '';

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Backend juga menormalkan, ini hanya supaya nomor yang dikirim ke dashboard
  // setelah daftar sama persis dengan yang tersimpan.
  String get _phone {
    if (widget.phoneNumber.isNotEmpty) return widget.phoneNumber;
    var raw = _phoneController.text.trim();
    if (raw.startsWith('0')) raw = raw.substring(1);
    if (!raw.startsWith('+62')) raw = '+62$raw';
    return raw;
  }

  Future<void> _submitRegistration() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final phone = _phone;
      final response = await ApiService().register(
        phoneNumber: phone,
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        role: _role,
        password: _passwordController.text,
      );

      if (response['status'] == 'success') {
        NotifikasiService().daftarkanPerangkat();
        if (mounted) {
          // Navigate to main dashboard
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(
                name: _nameController.text.trim(),
                role: _role,
                phone: phone,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          const DecorativeCircles(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    Text(
                      widget.phoneNumber.isEmpty ? 'Buat Akun Baru' : 'Lengkapi Profil Anda',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tinggal satu langkah lagi sebelum Anda bisa menggunakan bohAntar.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 32),
                    
                    // Name Field
                    Text(
                      'Nama Lengkap',
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      keyboardType: TextInputType.name,
                      decoration: const InputDecoration(
                        hintText: 'Masukkan nama lengkap Anda',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Nama tidak boleh kosong';
                        }
                        if (value.trim().length < 3) {
                          return 'Nama terlalu pendek';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    
                    // Email Field
                    Text(
                      'Alamat Email',
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        hintText: 'name@email.com',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Email tidak boleh kosong';
                        }
                        final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                        if (!emailRegex.hasMatch(value.trim())) {
                          return 'Format email tidak valid';
                        }
                        return null;
                      },
                    ),

                    // Nomor HP hanya ditanyakan kalau belum diketahui.
                    if (widget.phoneNumber.isEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        'Nomor Handphone',
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          hintText: '0812 3456 7890',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Nomor handphone tidak boleh kosong';
                          }
                          if (value.trim().length < 9) {
                            return 'Nomor handphone terlalu pendek';
                          }
                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 24),

                    // Password Field
                    Text(
                      'Password',
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofillHints: const [AutofillHints.newPassword],
                      decoration: InputDecoration(
                        hintText: 'Minimal 8 karakter',
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
                        if (value.length < 8) {
                          return 'Password minimal 8 karakter';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 32),

                    // Pilihan "Daftar Sebagai Driver" dibuang dari sini: dulu
                    // memilihnya langsung membuat akun driver tanpa verifikasi apa
                    // pun, dan orang itu seketika menerima pesanan berisi alamat
                    // rumah penumpang sungguhan. Pendaftaran driver kini lewat
                    // pengajuan berdokumen yang disetujui admin, dan backend
                    // menolak role driver dari endpoint publik ini.
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.15 : 0.08),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.sports_motorsports_outlined, color: AppTheme.primaryBlue, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Mau jadi driver bohAntar?',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Ajukan lewat formulir berdokumen. Akun driver aktif setelah KTP, SIM, dan STNK Anda disetujui admin.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                    color: isDark ? Colors.blueGrey.shade300 : Colors.grey.shade700,
                                  ),
                                ),
                                TextButton(
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 32),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const DriverRegisterScreen()),
                                  ),
                                  child: const Text('Daftar jadi driver'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (_errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        _errorMessage,
                        style: const TextStyle(color: AppTheme.errorColor, fontWeight: FontWeight.w500),
                      ),
                    ],

                    const SizedBox(height: 40),
                    
                    // Submit Button
                    ElevatedButton(
                      onPressed: _isLoading ? null : _submitRegistration,
                      child: _isLoading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Text('Daftar Sekarang'),
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
}
