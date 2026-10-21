import 'package:flutter/material.dart';

class AppTheme {
  // Brand Colors
  static const Color primaryBlue = Color(0xFF1E7FFF); // Premium bohAntar Blue
  static const Color primaryDarkBlue = Color(0xFF0066FF); // Darker Blue
  static const Color primaryLightBlue = Color(0xFFEFF6FF); // Tailwind Blue 50
  
  static const Color bgObsidianDark = Color(0xFF0F172A); // Slate 900
  static const Color cardObsidianDark = Color(0xFF1E293B); // Slate 800
  static const Color textObsidianDark = Color(0xFFF8FAFC); // Slate 50
  
  static const Color bgLight = Color(0xFFF8FAFC); // Slate 50
  static const Color cardLight = Colors.white;
  static const Color textLight = Color(0xFF0F172A); // Slate 900
  
  static const Color textSecondary = Color(0xFF64748B); // Slate 500
  static const Color errorColor = Color(0xFFEF4444); // Red 500

  // Warna tiap layanan, supaya beranda dan riwayat bisa dibedakan sekali lihat
  // — dulu semuanya biru. Shade 600: ikon putih di atasnya masih di atas 3:1.
  static const Color warnaRide = primaryBlue;
  static const Color warnaCar = Color(0xFF059669); // Emerald 600
  static const Color warnaFood = Color(0xFFEA580C); // Orange 600
  static const Color warnaSend = Color(0xFF7C3AED); // Violet 600
  static const Color warnaRental = Color(0xFF0891B2); // Cyan 600

  static Color warnaLayanan(String layanan) => switch (layanan) {
        'BohCar' => warnaCar,
        'BohFood' => warnaFood,
        'BohSend' || 'BohAntar' => warnaSend,
        'BohRental' => warnaRental,
        _ => warnaRide,
      };

  /// Warna status pesanan. Semuanya di atas 4,5:1 terhadap putih, jadi aman
  /// untuk teks kecil di lencana status.
  static Color warnaStatus(String status) => switch (status) {
        'accepted' => primaryDarkBlue,
        'picked_up' => const Color(0xFF4F46E5), // Indigo 600
        'completed' => const Color(0xFF047857), // Emerald 700
        'cancelled' => const Color(0xFFDC2626), // Red 600
        'expired' => textSecondary,
        _ => const Color(0xFFB45309), // Amber 700: masih mencari driver
      };

  /// Teks keterangan yang tetap terbaca di kedua tema: Slate 500 di atas putih
  /// 4,8:1, Slate 400 di atas kartu gelap 5,7:1. Colors.grey (#9E9E9E) di atas
  /// putih cuma 2,7:1, di bawah batas WCAG 4,5:1 untuk teks kecil.
  static Color teksRedup(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF94A3B8) : textSecondary;

  /// Warna layanan/status sebagai teks. Di mode gelap dicerahkan: shade 600–700
  /// yang terbaca di atas putih tenggelam di atas kartu gelap.
  static Color teksBerwarna(BuildContext context, Color warna) =>
      Theme.of(context).brightness == Brightness.dark ? Color.lerp(warna, Colors.white, 0.45)! : warna;

  // Light Theme Configuration
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      // Satu tempat saja: tanpa ini hanya beberapa gaya di textTheme yang
      // memakai Inter, sisanya jatuh ke font bawaan sistem.
      fontFamily: 'Inter',
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: primaryBlue,
        onPrimary: Colors.white,
        secondary: primaryDarkBlue,
        background: bgLight,
        surface: cardLight,
        error: errorColor,
        // Tanpa dua ini Flutter memakai onBackground (hitam): setiap Divider()
        // dan garis OutlinedButton bawaan tercetak hitam pekat.
        outline: Color(0xFFCBD5E1), // Slate 300
        outlineVariant: Color(0xFFE2E8F0), // Slate 200
      ),
      scaffoldBackgroundColor: bgLight,
      cardTheme: const CardThemeData(
        color: cardLight,
        elevation: 2,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontFamily: 'Inter', fontSize: 32, fontWeight: FontWeight.bold, color: textLight),
        headlineMedium: TextStyle(fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.bold, color: textLight),
        titleLarge: TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.w600, color: textLight),
        bodyLarge: TextStyle(fontFamily: 'Inter', fontSize: 16, color: textLight),
        // bodyMedium jadi gaya bawaan SEMUA Text tanpa warna di dalam Scaffold.
        // Dulu textSecondary (abu-abu), sehingga judul kartu, nama driver, dan
        // judul status sama pucatnya dengan keterangan di bawahnya. Teks yang
        // memang keterangan memakai teksRedup() secara terang-terangan.
        bodyMedium: TextStyle(fontFamily: 'Inter', fontSize: 14, color: textLight),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: errorColor, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            fontFamily: 'Inter',
          ),
          elevation: 0,
        ),
      ),
    );
  }

  // Dark Theme Configuration
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      // Satu tempat saja: tanpa ini hanya beberapa gaya di textTheme yang
      // memakai Inter, sisanya jatuh ke font bawaan sistem.
      fontFamily: 'Inter',
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: primaryBlue,
        onPrimary: Colors.white,
        secondary: primaryLightBlue,
        background: bgObsidianDark,
        surface: cardObsidianDark,
        error: errorColor,
        // Lihat tema terang: bawaannya putih menyala di atas latar gelap.
        outline: Color(0xFF475569), // Slate 600
        outlineVariant: Color(0xFF334155), // Slate 700
      ),
      scaffoldBackgroundColor: bgObsidianDark,
      cardTheme: const CardThemeData(
        color: cardObsidianDark,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontFamily: 'Inter', fontSize: 32, fontWeight: FontWeight.bold, color: textObsidianDark),
        headlineMedium: TextStyle(fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.bold, color: textObsidianDark),
        titleLarge: TextStyle(fontFamily: 'Inter', fontSize: 20, fontWeight: FontWeight.w600, color: textObsidianDark),
        bodyLarge: TextStyle(fontFamily: 'Inter', fontSize: 16, color: textObsidianDark),
        // Lihat catatan di tema terang. Di sini textSecondary malah cuma 3,4:1
        // di atas latar gelap — di bawah batas terbaca untuk teks kecil.
        bodyMedium: TextStyle(fontFamily: 'Inter', fontSize: 14, color: textObsidianDark),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardObsidianDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: errorColor, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            fontFamily: 'Inter',
          ),
          elevation: 0,
        ),
      ),
    );
  }
}
