import 'package:flutter/material.dart';
import 'package:mobile/models/food.dart';
import 'package:mobile/theme.dart';

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
          Text(teks, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.teksRedup(context), fontSize: 13)),
          if (tombol != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: saatTekan, child: Text(tombol!)),
          ],
        ],
      ),
    );
  }
}

/// Tombol −/+ dengan angka di tengah. Tiap tombol 44×44 supaya mudah dikenai
/// jempol; versi lama 28×32 sering meleset ke tombol sebelahnya.
class PengaturJumlah extends StatelessWidget {
  final int jumlah;
  final VoidCallback? saatTambah;
  final VoidCallback? saatKurang;
  const PengaturJumlah({super.key, required this.jumlah, required this.saatTambah, required this.saatKurang});

  @override
  Widget build(BuildContext context) {
    Widget tombol(IconData ikon, VoidCallback? aksi) => InkWell(
          onTap: aksi,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 44, height: 44, child: Icon(ikon, size: 18, color: aksi == null ? Colors.white54 : Colors.white)),
        );
    return Container(
      decoration: BoxDecoration(color: AppTheme.primaryBlue, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tombol(Icons.remove, saatKurang),
          SizedBox(width: 24, child: Text('$jumlah', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14))),
          tombol(Icons.add, saatTambah),
        ],
      ),
    );
  }
}
