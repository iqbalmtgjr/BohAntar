import 'package:flutter/material.dart';
import 'package:mobile/theme.dart';

/// Kata-kata dan tampilan status pesanan untuk pemesan, di satu tempat.
///
/// Layar pelacakan, kartu pesanan berjalan di beranda, dan tab Aktivitas dulu
/// menulis teksnya masing-masing — yang satu "Driver menuju lokasi kamu", yang
/// lain "ACCEPTED" mentah dari server. Sekarang ketiganya membaca dari sini.

/// Yang diantar: orangnya sendiri, makanan dari warung, atau paket.
enum JenisPesanan { orang, makanan, barang }

JenisPesanan jenisPesanan(String layanan) => switch (layanan) {
      'BohFood' => JenisPesanan.makanan,
      // BohAntar sudah dilebur ke BohSend; pesanan lama tetap dikenali.
      'BohSend' || 'BohAntar' => JenisPesanan.barang,
      _ => JenisPesanan.orang,
    };

/// Jarak driver ke titik berikutnya yang dianggap "sudah dekat". Knob: naikkan
/// kalau kabarnya terasa telat, turunkan kalau muncul terlalu dini. 300 m kira-
/// kira satu menit motor di jalan kota.
const double jarakDekatMeter = 300;

/// Judul besar dan satu kalimat keterangan untuk keadaan pesanan sekarang.
///
/// [dekat] bukan status server: dihitung di HP dari jarak driver ke titik
/// berikutnya. [warung] nama warung BohFood.
({String judul, String keterangan}) kabarPesanan(
  String layanan,
  String status, {
  bool dekat = false,
  String warung = '',
}) {
  final jenis = jenisPesanan(layanan);
  final namaWarung = warung.isEmpty ? 'warung' : warung;
  switch (status) {
    case 'accepted':
      return switch (jenis) {
        JenisPesanan.orang => dekat
            ? (judul: 'Driver sudah dekat, siap-siap ya!', keterangan: 'Tunggu di titik jemput supaya driver mudah menemukanmu.')
            : (judul: 'Driver menuju ke tempatmu', keterangan: 'Pastikan kamu ada di titik jemput, ya.'),
        JenisPesanan.makanan => dekat
            ? (judul: 'Driver sudah sampai di warung', keterangan: 'Pesananmu sedang disiapkan di $namaWarung.')
            : (judul: 'Driver lagi ke $namaWarung', keterangan: 'Pesananmu dibelikan dan dibayar dulu oleh driver.'),
        JenisPesanan.barang => dekat
            ? (judul: 'Driver sudah dekat, siapkan paketnya ya', keterangan: 'Serahkan paket begitu driver sampai.')
            : (judul: 'Driver menuju lokasi ambil paket', keterangan: 'Siapkan paketnya supaya driver bisa langsung berangkat.'),
      };
    case 'picked_up':
      return switch (jenis) {
        JenisPesanan.orang => dekat
            ? (judul: 'Sebentar lagi sampai', keterangan: 'Siap-siap turun, cek lagi barang bawaanmu.')
            : (judul: 'Driver sedang antar kamu', keterangan: 'Selamat jalan! Pantau perjalananmu di peta.'),
        JenisPesanan.makanan => dekat
            ? (judul: 'Siap-siap ambil pesananmu ya!', keterangan: 'Driver sudah dekat dengan lokasimu.')
            : (judul: 'Pesananmu lagi diantar', keterangan: 'Driver sudah membawa pesananmu dari $namaWarung.'),
        JenisPesanan.barang => dekat
            ? (judul: 'Paket sebentar lagi sampai', keterangan: 'Driver sudah dekat dengan penerima.')
            : (judul: 'Paketmu lagi diantar', keterangan: 'Driver sedang menuju penerima.'),
      };
    case 'completed':
      return switch (jenis) {
        JenisPesanan.orang => (judul: 'Sudah sampai, terima kasih!', keterangan: 'Semoga perjalananmu menyenangkan.'),
        JenisPesanan.makanan => (judul: 'Pesananmu sudah sampai', keterangan: 'Selamat makan! Terima kasih sudah pesan lewat BohFood.'),
        JenisPesanan.barang => (judul: 'Paket sudah diterima', keterangan: 'Terima kasih sudah kirim lewat bohAntar.'),
      };
    case 'cancelled':
      return (judul: 'Pesanan dibatalkan', keterangan: 'Kamu bisa pesan lagi kapan saja.');
    case 'expired':
      return (judul: 'Belum dapat driver', keterangan: 'Driver sedang sibuk semua. Coba pesan lagi sebentar lagi, ya.');
    default: // pending, atau "searching" milik layar pelacakan
      return (judul: 'Tunggu sebentar ya, lagi cari driver', keterangan: 'Biasanya tidak lama. Kamu boleh tinggalkan layar ini, nanti kami kabari.');
  }
}

/// Empat tahap yang dilewati setiap pesanan, ditulis menurut layanannya.
List<String> tahapanPesanan(String layanan) => switch (jenisPesanan(layanan)) {
      JenisPesanan.makanan => const ['Dapat driver', 'Driver beli di warung', 'Diantar ke kamu', 'Pesanan sampai'],
      JenisPesanan.barang => const ['Dapat driver', 'Paket dijemput driver', 'Diantar ke penerima', 'Paket diterima'],
      JenisPesanan.orang => const ['Dapat driver', 'Driver menjemputmu', 'Diantar ke tujuan', 'Sampai tujuan'],
    };

/// Indeks tahap yang sedang berjalan. Sama dengan panjang daftar tahapan
/// berarti semuanya sudah lewat.
int tahapAktif(String status) => switch (status) {
      'accepted' => 1,
      'picked_up' => 2,
      'completed' => 4,
      _ => 0, // pending / searching
    };

/// Lencana status di daftar riwayat. Berlaku untuk semua layanan.
String labelStatus(String status) => switch (status) {
      'pending' || 'searching' => 'Mencari driver',
      'accepted' => 'Driver di jalan',
      'picked_up' => 'Sedang diantar',
      'completed' => 'Selesai',
      'cancelled' => 'Dibatalkan',
      'expired' => 'Tidak dapat driver',
      _ => status,
    };

bool pesananBerjalan(String status) => status == 'pending' || status == 'accepted' || status == 'picked_up';

IconData ikonLayanan(String layanan) => switch (layanan) {
      'BohFood' => Icons.restaurant,
      'BohSend' || 'BohAntar' => Icons.local_shipping,
      'BohCar' => Icons.directions_car,
      'BohRental' => Icons.car_rental,
      _ => Icons.two_wheeler,
    };

/// Ilustrasi layanan (assets/images/layanan_*.png; sumber dan cara membuatnya
/// di mobile/branding/ikon-layanan). BohAntar lama = BohSend.
String? asetLayanan(String layanan) => switch (layanan) {
      'BohRide' => 'assets/images/layanan_bohride.png',
      'BohCar' => 'assets/images/layanan_bohcar.png',
      'BohFood' => 'assets/images/layanan_bohfood.png',
      'BohSend' || 'BohAntar' => 'assets/images/layanan_bohsend.png',
      'BohRental' => 'assets/images/layanan_bohrental.png',
      'Lainnya' => 'assets/images/layanan_lainnya.png',
      _ => null,
    };

String deskripsiLayanan(String layanan) => switch (layanan) {
      'BohCar' => 'Antar jemput mobil',
      'BohFood' => 'Pesan makanan',
      'BohSend' || 'BohAntar' => 'Kirim paket & dokumen',
      'BohRental' => 'Sewa mobil & motor',
      _ => 'Ojek motor',
    };

/// Tahapan bergaris: yang sudah lewat dicentang hijau, yang sedang berjalan
/// berwarna status dan tebal, sisanya abu-abu.
class TimelinePesanan extends StatelessWidget {
  final String layanan;
  final String status;

  /// Keterangan kecil di bawah tahap yang sedang berjalan, mis. perkiraan tiba.
  final String? keteranganAktif;

  const TimelinePesanan({super.key, required this.layanan, required this.status, this.keteranganAktif});

  static const _hijau = Color(0xFF10B981);

  @override
  Widget build(BuildContext context) {
    final tahap = tahapanPesanan(layanan);
    final aktif = tahapAktif(status);
    final warna = AppTheme.warnaStatus(status);
    final abu = Colors.grey.withValues(alpha: 0.35);
    final redup = AppTheme.teksRedup(context);

    return Column(
      children: [
        for (var i = 0; i < tahap.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 22,
                  child: Column(
                    children: [
                      _bulatan(selesai: i < aktif, berjalan: i == aktif, warna: warna, abu: abu),
                      if (i < tahap.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            color: i < aktif ? _hijau : abu,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: 1, bottom: i < tahap.length - 1 ? 14 : 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tahap[i],
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: i == aktif ? FontWeight.w800 : (i < aktif ? FontWeight.w600 : FontWeight.normal),
                            color: i == aktif ? AppTheme.teksBerwarna(context, warna) : (i < aktif ? null : redup),
                          ),
                        ),
                        if (i == aktif && (keteranganAktif ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(keteranganAktif!, style: TextStyle(fontSize: 12, color: redup)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bulatan({required bool selesai, required bool berjalan, required Color warna, required Color abu}) {
    if (selesai) {
      return Container(
        width: 20,
        height: 20,
        decoration: const BoxDecoration(color: _hijau, shape: BoxShape.circle),
        child: const Icon(Icons.check, size: 13, color: Colors.white),
      );
    }
    if (berjalan) {
      // Lingkaran samar dengan titik di tengah: "di sini sekarang".
      return Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: warna.withValues(alpha: 0.18), shape: BoxShape.circle),
        child: Container(width: 10, height: 10, decoration: BoxDecoration(color: warna, shape: BoxShape.circle)),
      );
    }
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: abu, width: 2)),
    );
  }
}

/// Bilah kemajuan empat ruas untuk kartu pesanan berjalan di beranda.
class ProgresPesanan extends StatelessWidget {
  final String layanan;
  final String status;
  const ProgresPesanan({super.key, required this.layanan, required this.status});

  @override
  Widget build(BuildContext context) {
    final jumlah = tahapanPesanan(layanan).length;
    final aktif = tahapAktif(status);
    final warna = AppTheme.warnaStatus(status);
    return Row(
      children: [
        for (var i = 0; i < jumlah; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i < aktif
                    ? warna
                    : i == aktif
                        ? warna.withValues(alpha: 0.4)
                        : Colors.grey.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
