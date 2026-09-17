import 'package:flutter/material.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/theme.dart';

/// Tiga langkah pemesanan makanan, selalu terlihat di atas layar: pemesan tahu
/// sedang di mana dan tinggal berapa langkah lagi.
class LangkahPesan extends StatelessWidget {
  final int aktif; // 1 = pilih warung, 2 = pilih menu, 3 = konfirmasi
  const LangkahPesan({super.key, required this.aktif});

  static const _judul = ['Pilih warung', 'Pilih menu', 'Konfirmasi'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _judul.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: i < aktif ? AppTheme.primaryBlue : Colors.grey.withOpacity(0.3),
              ),
            ),
          _Langkah(nomor: i + 1, judul: _judul[i], aktif: aktif),
        ],
      ],
    );
  }
}

class _Langkah extends StatelessWidget {
  final int nomor;
  final String judul;
  final int aktif;
  const _Langkah({required this.nomor, required this.judul, required this.aktif});

  @override
  Widget build(BuildContext context) {
    final selesai = nomor < aktif;
    final sekarang = nomor == aktif;
    final warna = selesai || sekarang ? AppTheme.primaryBlue : Colors.grey;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selesai || sekarang ? AppTheme.primaryBlue : Colors.transparent,
            border: Border.all(color: warna, width: 1.5),
          ),
          child: selesai
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Text('$nomor', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: sekarang ? Colors.white : Colors.grey)),
        ),
        const SizedBox(width: 6),
        Text(
          judul,
          style: TextStyle(fontSize: 12, fontWeight: sekarang ? FontWeight.bold : FontWeight.w500, color: sekarang ? null : Colors.grey),
        ),
      ],
    );
  }
}

/// Gambar dari server dengan pengganti yang rapi saat URL kosong atau gagal
/// dimuat — foto warung sering cuma tautan yang sudah mati.
class GambarJaringan extends StatelessWidget {
  final String url;
  final IconData pengganti;
  const GambarJaringan({super.key, required this.url, this.pengganti = Icons.restaurant});

  @override
  Widget build(BuildContext context) {
    final kosong = Container(
      color: AppTheme.primaryBlue.withOpacity(0.08),
      alignment: Alignment.center,
      child: Icon(pengganti, size: 36, color: AppTheme.primaryBlue.withOpacity(0.5)),
    );
    if (url.trim().isEmpty) return kosong;
    return Image.network(
      urlGambar(url),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => kosong,
      loadingBuilder: (_, anak, progres) => progres == null ? anak : kosong,
    );
  }
}

/// Lencana kecil: "Buka", "1,2 km", "Habis".
class Pil extends StatelessWidget {
  final String teks;
  final Color warna;
  final Color? warnaTeks;
  const Pil(this.teks, {super.key, required this.warna, this.warnaTeks});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: warna, borderRadius: BorderRadius.circular(20)),
      child: Text(teks, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: warnaTeks ?? Colors.white)),
    );
  }
}

/// Keadaan kosong atau gagal: ikon, judul, penjelasan, dan tombol kalau ada
/// yang bisa dilakukan.
class PesanKosong extends StatelessWidget {
  final IconData ikon;
  final String judul;
  final String teks;
  final String? tombol;
  final VoidCallback? saatTekan;
  const PesanKosong({super.key, required this.ikon, required this.judul, required this.teks, this.tombol, this.saatTekan});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: AppTheme.primaryBlue.withOpacity(0.08), shape: BoxShape.circle),
            child: Icon(ikon, size: 36, color: AppTheme.primaryBlue),
          ),
          const SizedBox(height: 16),
          Text(judul, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 6),
          Text(teks, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          if (tombol != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: saatTekan, child: Text(tombol!)),
          ],
        ],
      ),
    );
  }
}
