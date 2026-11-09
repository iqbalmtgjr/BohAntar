import 'package:flutter/material.dart';
import 'package:mobile/theme.dart';

/// Pilihan terakhir di [pilihAlasan] yang membuka kolom ketik sendiri.
const alasanLainnya = 'Lainnya';

/// Dialog konfirmasi yang wajib memilih alasan: dipakai saat penumpang
/// membatalkan pesanan yang sudah dapat driver, dan saat driver melepas
/// pesanan. Hasilnya teks alasan, atau null kalau dialog ditutup.
///
/// "Lainnya" boleh dibiarkan tanpa ketikan — memilihnya saja sudah cukup.
Future<String?> pilihAlasan(
  BuildContext context, {
  required String judul,
  required String isi,
  required List<String> pilihan,
  required String tombol,
  String batal = 'Jangan',
}) {
  String? dipilih;
  final ketikan = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, atur) => AlertDialog(
        title: Text(judul),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isi, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in pilihan)
                    ChoiceChip(
                      // Latar terpilih biru tua dari tema: teksnya putih supaya terbaca.
                      label: Text(p, style: TextStyle(color: dipilih == p ? Colors.white : null)),
                      checkmarkColor: Colors.white,
                      selected: dipilih == p,
                      onSelected: (_) => atur(() => dipilih = p),
                    ),
                ],
              ),
              if (dipilih == alasanLainnya) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: ketikan,
                  autofocus: true,
                  maxLength: 150,
                  decoration: const InputDecoration(hintText: 'Tulis alasannya (opsional)', isDense: true),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(batal)),
          TextButton(
            onPressed: dipilih == null
                ? null
                : () => Navigator.pop(ctx, dipilih == alasanLainnya && ketikan.text.trim().isNotEmpty ? ketikan.text.trim() : dipilih),
            child: Text(tombol, style: TextStyle(color: dipilih == null ? null : AppTheme.errorColor, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    ),
  );
  // ponytail: ketikan tidak di-dispose — membuangnya saat dialog masih
  // beranimasi menutup memicu galat "used after disposed", dan controller
  // tanpa pendengar cukup dibereskan GC.
}
