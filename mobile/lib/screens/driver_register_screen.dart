import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/decorative_background.dart';

import 'login_screen.dart';

/// Pengajuan jadi driver, diisi sendiri dari HP. Tidak langsung menghasilkan
/// akun yang bisa dipakai: backend menahan login sampai admin menyetujui
/// dokumennya, karena token driver membuka alamat rumah penumpang sungguhan.
class DriverRegisterScreen extends StatefulWidget {
  const DriverRegisterScreen({super.key});

  @override
  State<DriverRegisterScreen> createState() => _DriverRegisterScreenState();
}

class _DriverRegisterScreenState extends State<DriverRegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _ktpController = TextEditingController();
  final _simController = TextEditingController();
  final _plateController = TextEditingController();
  final _modelController = TextEditingController();

  String _vehicleType = 'motor';
  bool _obscurePassword = true;
  bool _isLoading = false;
  String _errorMessage = '';

  // Berkas yang sudah dipilih, per jenis dokumen.
  final Map<String, File> _dokumen = {};

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _emailController,
      _phoneController,
      _passwordController,
      _ktpController,
      _simController,
      _plateController,
      _modelController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pilihDokumen(String kunci) async {
    final sumber = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
    if (sumber == null) return;

    // Dikecilkan di HP: server menolak berkas di atas 5 MB, dan foto mentah
    // kamera sekarang lewat batas itu sendirian.
    final foto = await ImagePicker().pickImage(
      source: sumber,
      maxWidth: 1600,
      imageQuality: 70,
    );
    if (foto == null) return;
    setState(() => _dokumen[kunci] = File(foto.path));
  }

  Future<void> _kirim() async {
    if (!_formKey.currentState!.validate()) return;
    if (_dokumen.length < 3) {
      setState(() => _errorMessage = 'Scan KTP, SIM, dan STNK wajib dilampirkan.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    try {
      await ApiService().daftarDriver(
        phoneNumber: _phoneController.text.trim(),
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        ktpNumber: _ktpController.text.trim(),
        simNumber: _simController.text.trim(),
        vehiclePlate: _plateController.text.trim().toUpperCase(),
        vehicleType: _vehicleType,
        vehicleModel: _modelController.text.trim(),
        ktpPhotoPath: _dokumen['ktp']!.path,
        simPhotoPath: _dokumen['sim']!.path,
        stnkPhotoPath: _dokumen['stnk']!.path,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.hourglass_top, color: AppTheme.primaryBlue, size: 40),
          title: const Text('Pengajuan terkirim'),
          content: const Text(
            'Dokumen Anda sedang ditinjau admin bohAntar. Anda bisa masuk memakai '
            'email dan password ini setelah pengajuan disetujui.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Mengerti'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      // Ke layar masuk, bukan kembali ke formulir daftar yang baru saja
      // dikirim — dan seluruh tumpukan dibuang supaya tombol kembali tidak
      // memunculkan lagi formulir yang isinya sudah terkirim.
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const LoginScreen(
            pesanInfo: 'Pengajuan driver Anda sedang ditinjau admin. Masuk dengan '
                'email dan password yang tadi Anda buat setelah pengajuan disetujui.',
          ),
        ),
        (route) => false,
      );
    } catch (e) {
      setState(() => _errorMessage = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String? _wajib(String? nilai, String pesan) =>
      (nilai == null || nilai.trim().isEmpty) ? pesan : null;

  Widget _kolom(
    String label,
    TextEditingController controller, {
    required IconData ikon,
    required String hint,
    TextInputType? keyboard,
    String? Function(String?)? validator,
    TextCapitalization capitalization = TextCapitalization.none,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboard,
          textCapitalization: capitalization,
          decoration: InputDecoration(hintText: hint, prefixIcon: Icon(ikon)),
          validator: validator ?? (v) => _wajib(v, '$label tidak boleh kosong'),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _kartuDokumen(String kunci, String judul, String keterangan) {
    final theme = Theme.of(context);
    final berkas = _dokumen[kunci];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: _isLoading ? null : () => _pilihDokumen(kunci),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: berkas == null ? theme.dividerColor : AppTheme.primaryBlue,
              width: berkas == null ? 1 : 2,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: berkas == null
                    ? Container(
                        width: 56,
                        height: 56,
                        color: theme.dividerColor.withValues(alpha: 0.3),
                        child: const Icon(Icons.add_a_photo_outlined),
                      )
                    : Image.file(berkas, width: 56, height: 56, fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(judul, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      berkas == null ? keterangan : 'Foto terlampir — ketuk untuk ganti',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (berkas != null)
                const Icon(Icons.check_circle, color: AppTheme.primaryBlue),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Daftar Jadi Driver')),
      body: Stack(
        children: [
          const DecorativeCircles(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Data diri dan kendaraan Anda diperiksa admin sebelum akun '
                      'driver bisa dipakai. Siapkan KTP, SIM, dan STNK asli.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    _kolom('Nama Lengkap', _nameController,
                        ikon: Icons.person_outline,
                        hint: 'Sesuai KTP',
                        keyboard: TextInputType.name,
                        capitalization: TextCapitalization.words),
                    _kolom('Alamat Email', _emailController,
                        ikon: Icons.mail_outline,
                        hint: 'nama@email.com',
                        keyboard: TextInputType.emailAddress,
                        validator: (v) {
                          final teks = (v ?? '').trim();
                          if (teks.isEmpty) return 'Email tidak boleh kosong';
                          if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(teks)) {
                            return 'Format email tidak valid';
                          }
                          return null;
                        }),
                    _kolom('Nomor Handphone', _phoneController,
                        ikon: Icons.phone_outlined,
                        hint: '0812 3456 7890',
                        keyboard: TextInputType.phone,
                        validator: (v) {
                          final teks = (v ?? '').replaceAll(RegExp(r'\D'), '');
                          if (teks.length < 9) return 'Nomor handphone tidak valid';
                          return null;
                        }),
                    Text('Password',
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        hintText: 'Minimal 8 karakter',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) => (v == null || v.length < 8) ? 'Password minimal 8 karakter' : null,
                    ),
                    const SizedBox(height: 20),
                    _kolom('Nomor KTP', _ktpController,
                        ikon: Icons.badge_outlined,
                        hint: '16 digit',
                        keyboard: TextInputType.number,
                        validator: (v) {
                          final teks = (v ?? '').trim();
                          if (teks.length != 16) return 'Nomor KTP harus 16 digit';
                          return null;
                        }),
                    _kolom('Nomor SIM', _simController,
                        ikon: Icons.credit_card_outlined,
                        hint: 'Sesuai SIM aktif',
                        capitalization: TextCapitalization.characters),
                    _kolom('Plat Nomor', _plateController,
                        ikon: Icons.pin_outlined,
                        hint: 'KB 1234 XY',
                        capitalization: TextCapitalization.characters),
                    Text('Jenis Kendaraan',
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _vehicleType,
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.two_wheeler_outlined)),
                      items: const [
                        DropdownMenuItem(value: 'motor', child: Text('Motor')),
                        DropdownMenuItem(value: 'mobil', child: Text('Mobil')),
                      ],
                      onChanged: (v) => setState(() => _vehicleType = v ?? 'motor'),
                    ),
                    const SizedBox(height: 20),
                    _kolom('Merek & Tipe', _modelController,
                        ikon: Icons.directions_bike_outlined,
                        hint: 'Honda Beat 2020',
                        capitalization: TextCapitalization.words),
                    Text('Dokumen',
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('Foto harus terbaca jelas, tidak terpotong.',
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    _kartuDokumen('ktp', 'Scan KTP', 'Ketuk untuk ambil atau pilih foto'),
                    _kartuDokumen('sim', 'Scan SIM', 'SIM C untuk motor, SIM A untuk mobil'),
                    _kartuDokumen('stnk', 'Scan STNK', 'STNK kendaraan yang dipakai bekerja'),
                    if (_errorMessage.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage,
                        style: const TextStyle(color: AppTheme.errorColor, fontWeight: FontWeight.w500),
                      ),
                    ],
                    const SizedBox(height: 28),
                    ElevatedButton(
                      onPressed: _isLoading ? null : _kirim,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Kirim Pengajuan'),
                    ),
                    const SizedBox(height: 24),
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
