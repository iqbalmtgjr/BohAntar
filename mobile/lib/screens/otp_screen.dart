import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile/services/api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/decorative_background.dart';
import 'register_screen.dart';
import 'dashboard_screen.dart';

class OtpScreen extends StatefulWidget {
  final String phoneNumber;

  const OtpScreen({
    super.key,
    required this.phoneNumber,
  });

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  static const int otpLength = 6;
  final List<TextEditingController> _controllers = List.generate(otpLength, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(otpLength, (_) => FocusNode());
  
  bool _isLoading = false;
  String _errorMessage = '';
  
  int _secondsRemaining = 60;
  late Timer _timer;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer.cancel();
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  void _startTimer() {
    setState(() {
      _secondsRemaining = 60;
      _canResend = false;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining == 0) {
        setState(() {
          _canResend = true;
        });
        _timer.cancel();
      } else {
        setState(() {
          _secondsRemaining--;
        });
      }
    });
  }

  Future<void> _resendOtp() async {
    if (!_canResend) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      await ApiService().requestOtp(widget.phoneNumber);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kode OTP baru sudah dikirim via SMS.'),
            backgroundColor: AppTheme.primaryDarkBlue,
          ),
        );
        _startTimer();
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

  // Get combined OTP string
  String get _otpString => _controllers.map((c) => c.text).join();

  Future<void> _verifyOtp() async {
    final otp = _otpString;
    if (otp.length < otpLength) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final response = await ApiService().verifyOtp(widget.phoneNumber, otp);
      final isNewUser = response['is_new_user'] ?? false;
      
      if (mounted) {
        if (isNewUser) {
          // Go to Register Screen
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => RegisterScreen(phoneNumber: widget.phoneNumber),
            ),
            (route) => false,
          );
        } else {
          // Exists, go to main dashboard
          final user = response['user'] as Map<String, dynamic>;
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => DashboardScreen(
                name: user['name'] ?? '',
                role: user['role'] ?? 'rider',
                phone: widget.phoneNumber,
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

  void _onOtpFieldChanged(String value, int index) {
    if (value.isNotEmpty) {
      // Auto focus next box
      if (index < otpLength - 1) {
        _focusNodes[index + 1].requestFocus();
      } else {
        // Last box filled, dismiss keyboard and trigger auto submit
        _focusNodes[index].unfocus();
        _verifyOtp();
      }
    } else {
      // Deletion - Auto focus previous box
      if (index > 0) {
        _focusNodes[index - 1].requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: isDark ? Colors.white : Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          const DecorativeCircles(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  Text(
                    'Verifikasi Kode OTP',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15),
                      children: [
                        const TextSpan(text: 'Kami telah mengirimkan 6-digit kode OTP ke '),
                        TextSpan(
                          text: widget.phoneNumber,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  
                  // 6 Box Input Fields
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(
                      otpLength,
                      (index) => SizedBox(
                        width: 50,
                        height: 56,
                        child: TextFormField(
                          controller: _controllers[index],
                          focusNode: _focusNodes[index],
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          maxLength: 1,
                          onChanged: (val) => _onOtpFieldChanged(val, index),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Inter',
                          ),
                          decoration: InputDecoration(
                            counterText: '',
                            contentPadding: EdgeInsets.zero,
                            fillColor: isDark ? AppTheme.cardObsidianDark : Colors.grey.shade100,
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 2.5),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: isDark ? Colors.blueGrey.shade700 : Colors.grey.shade300,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
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
                  
                  // Submit button
                  ElevatedButton(
                    onPressed: _isLoading || _otpString.length < otpLength ? null : _verifyOtp,
                    child: _isLoading
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Text('Verifikasi'),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // Resend code area
                  Center(
                    child: _canResend
                        ? TextButton(
                            onPressed: _isLoading ? null : _resendOtp,
                            child: const Text(
                              'Kirim Ulang Kode OTP',
                              style: TextStyle(
                                color: AppTheme.primaryBlue,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          )
                        : Text(
                            'Kirim ulang kode dalam $_secondsRemaining detik',
                            style: theme.textTheme.bodyMedium,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
