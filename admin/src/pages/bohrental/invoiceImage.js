import logoImg from "../../assets/logo_b_icon.png";
import { fileURL } from "../../api";
import { rupiah, waktu, labelNomor } from "./invoice";
import { pdfSatuGambar } from "./pdf";
import { terbilangRupiah } from "./schedule";

/*
 * Invoice digambar langsung ke <canvas>. Sengaja tanpa html2canvas/jsPDF:
 * keluaran PNG-nya sama persis di semua perangkat (tidak ikut tema gelap atau
 * font sistem penyewa), ukurannya kecil, dan nol dependensi baru.
 * Tema putih–biru mengikuti warna utama bohAntar.
 */

const W = 760;          // lebar logis; PNG akhir dua kali ini
const PAD = 40;
const SCALE = 2;        // tetap 2x, bukan devicePixelRatio, supaya hasilnya konsisten

const BIRU = "#1D4ED8";
const BIRU_TERANG = "#3B82F6";
const BIRU_MUDA = "#EFF6FF";
const BIRU_GARIS = "#BFDBFE";
const GARIS = "#E2E8F0";
const TEKS = "#0F172A";
const LEMBUT = "#64748B";
const FONT = "Inter, 'Segoe UI', system-ui, sans-serif";

const f = (size, weight = 400) => `${weight} ${size}px ${FONT}`;

const PITA_Y = 150;     // pita "INVOICE" di bawah kop mitra
const PITA_H = 60;
const KEPALA = PITA_Y + PITA_H + 24;

function muatGambar(src) {
  return new Promise((resolve) => {
    if (!src) return resolve(null);
    const img = new Image();
    // Logo mitra datang dari /uploads/ (di dev beda origin dengan halaman). Tanpa
    // mode CORS canvas jadi "tercemar" dan toBlob melempar galat; dengan mode ini
    // gambar yang tidak diizinkan cuma gagal dimuat.
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null); // logo gagal dimuat bukan alasan invoice batal
    img.src = src;
  });
}

// Pecah teks ke beberapa baris selebar maxWidth; sisa yang tidak muat di baris
// terakhir dipotong dengan "…".
function bungkus(ctx, text, maxWidth, maxBaris) {
  const baris = [];
  let cur = "";
  for (const kata of String(text || "").split(/\s+/).filter(Boolean)) {
    const coba = cur ? `${cur} ${kata}` : kata;
    if (cur && ctx.measureText(coba).width > maxWidth) { baris.push(cur); cur = kata; }
    else cur = coba;
  }
  if (cur) baris.push(cur);
  if (baris.length > maxBaris) baris.splice(maxBaris - 1, Infinity, baris.slice(maxBaris - 1).join(" "));
  return baris.map((b) => potong(ctx, b, maxWidth));
}

// Potong teks yang kepanjangan supaya tidak menabrak kolom nominal di kanan.
function potong(ctx, text, maxWidth) {
  let t = String(text ?? "");
  if (ctx.measureText(t).width <= maxWidth) return t;
  while (t.length > 1 && ctx.measureText(t + "…").width > maxWidth) t = t.slice(0, -1);
  return t + "…";
}

// Bea meterai Rp10.000 untuk dokumen penerimaan uang di atas Rp5 juta (UU 10/2020).
const BATAS_METERAI = 5000000;

// Sisa tagihan ditampilkan di invoice hanya kalau sebagian sudah dibayar (DP).
// Invoice tidak pernah menulis "sudah dibayar penuh / sisa Rp 0" — itu tugas
// kuitansi (masukan mitra 9 Nov).
const adaCicilan = (d) => !d.lunas && d.dibayar > 0 && d.sisa > 0;

// Baris rekening pembayaran mitra; hanya di invoice dan hanya yang diisi.
const barisRekening = (d) => (d.lunas ? [] : [
  ["Nama rek", d.rekNama], ["Bank", d.rekBank], ["No rek", d.rekNomor],
].filter(([, v]) => v));

function tinggiInvoice(d) {
  const rek = barisRekening(d).length;
  const kaki = (d.paymentMethod || d.statusLabel ? 34 : 0) + (rek ? 34 + rek * 28 + 18 : 0) + 104;
  if (d.lunas) {
    return KEPALA
      + 30 + 74 + 52 + 10                    // terima dari, uang sejumlah, untuk pembayaran
      + 34 + d.lines.length * 28 + 18        // rincian biaya
      + 100                                  // kotak jumlah + cap LUNAS
      + 150                                  // tanda tangan penerima
      + kaki;
  }
  const baris = 2 + 4 + d.lines.length;      // penyewa + kendaraan + rincian
  return KEPALA                              // kop + pita INVOICE + jarak
    + 3 * 34                                 // tiga judul bagian
    + baris * 28                             // isi
    + 3 * 18                                 // jarak antar bagian
    + (adaCicilan(d) ? 152 : 100)            // kotak total
    + kaki;
}

// PNG untuk pratinjau dan dibagikan ke WhatsApp.
export async function invoiceBlob(d) {
  const canvas = await gambarInvoice(d);
  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}

// PDF A4 siap cetak (mis. kuitansi yang perlu ditempel meterai). JPEG di dalam
// PDF jauh lebih kecil dari PNG untuk gambar yang sama.
export async function invoicePdf(d) {
  const canvas = await gambarInvoice(d);
  const jpg = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.92));
  const bytes = new Uint8Array(await jpg.arrayBuffer());
  return new Blob([pdfSatuGambar(bytes, canvas.width, canvas.height)], { type: "application/pdf" });
}

async function gambarInvoice(d) {
  // Inter dimuat lewat Google Fonts; tanpa menunggu, canvas bisa terlanjur
  // menggambar dengan font cadangan.
  if (document.fonts?.ready) await document.fonts.ready;
  const [logo, logoMitra] = await Promise.all([
    muatGambar(logoImg),
    muatGambar(d.rentalLogo ? fileURL(d.rentalLogo) : ""),
  ]);

  const H = tinggiInvoice(d);
  const canvas = document.createElement("canvas");
  canvas.width = W * SCALE;
  canvas.height = H * SCALE;
  const ctx = canvas.getContext("2d");
  ctx.scale(SCALE, SCALE);
  ctx.textBaseline = "alphabetic";

  // Latar
  ctx.fillStyle = "#FFFFFF";
  ctx.fillRect(0, 0, W, H);

  // Garis aksen biru di paling atas
  const grad = ctx.createLinearGradient(0, 0, W, 0);
  grad.addColorStop(0, BIRU);
  grad.addColorStop(1, BIRU_TERANG);
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, W, 6);

  // Kop mitra — kiri: logo + nama usaha. Logo dimuat utuh dalam kotak 84×84
  // tanpa dipotong, karena bentuk logo tiap rental berbeda-beda.
  const KANAN_W = 270;
  let teksX = PAD;
  if (logoMitra) {
    const k = Math.min(84 / logoMitra.width, 84 / logoMitra.height);
    const lw = logoMitra.width * k, lh = logoMitra.height * k;
    ctx.drawImage(logoMitra, PAD, 30 + (84 - lh) / 2, lw, lh);
    teksX = PAD + lw + 16;
  }
  const namaW = W - PAD - KANAN_W - 20 - teksX;
  ctx.fillStyle = TEKS;
  ctx.font = f(22, 800);
  ctx.fillText(potong(ctx, d.rentalName || "Rental Kendaraan", namaW), teksX, 70);
  ctx.fillStyle = LEMBUT;
  ctx.font = f(12, 500);
  ctx.fillText("Agen Sewa/Rental Kendaraan", teksX, 90);

  // Kanan: alamat dan No. HP mitra
  ctx.textAlign = "right";
  let ky = 52;
  ctx.fillStyle = LEMBUT;
  ctx.font = f(12, 500);
  for (const b of bungkus(ctx, d.rentalAddress, KANAN_W, 3)) {
    ctx.fillText(b, W - PAD, ky);
    ky += 17;
  }
  if (d.rentalPhone) {
    ctx.fillStyle = TEKS;
    ctx.font = f(12, 700);
    ctx.fillText(`Telp/WA ${d.rentalPhone}`, W - PAD, ky + 2);
  }
  ctx.textAlign = "left";

  ctx.strokeStyle = GARIS;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(PAD, 134.5);
  ctx.lineTo(W - PAD, 134.5);
  ctx.stroke();

  // Pita judul: INVOICE (tagihan, bertanggal hari ini) atau KUITANSI
  // (bukti terima uang, bertanggal pelunasan).
  ctx.beginPath();
  ctx.roundRect(PAD, PITA_Y, W - PAD * 2, PITA_H, 12);
  ctx.fillStyle = BIRU_MUDA;
  ctx.fill();
  ctx.fillStyle = BIRU;
  ctx.font = f(24, 800);
  ctx.fillText(d.jenis.toUpperCase(), PAD + 20, PITA_Y + 39);
  ctx.textAlign = "right";
  ctx.fillStyle = TEKS;
  ctx.font = f(13, 700);
  ctx.fillText(potong(ctx, labelNomor(d), W / 2 - PAD), W - PAD - 20, PITA_Y + 26);
  ctx.fillStyle = LEMBUT;
  ctx.font = f(12, 500);
  ctx.fillText(waktu(d.lunas ? d.lunasAt : new Date()), W - PAD - 20, PITA_Y + 45);
  ctx.textAlign = "left";

  let y = KEPALA;

  const judul = (teks) => {
    ctx.fillStyle = BIRU;
    ctx.font = f(11, 800);
    ctx.fillText(teks.toUpperCase(), PAD, y + 12);
    ctx.strokeStyle = GARIS;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(PAD, y + 22.5);
    ctx.lineTo(W - PAD, y + 22.5);
    ctx.stroke();
    y += 34;
  };

  const baris = (label, nilai, tebal = false) => {
    ctx.fillStyle = LEMBUT;
    ctx.font = f(13, 500);
    ctx.fillText(potong(ctx, label, W - PAD * 2 - 220), PAD, y + 14);
    ctx.fillStyle = TEKS;
    ctx.font = f(13, tebal ? 700 : 600);
    ctx.textAlign = "right";
    ctx.fillText(potong(ctx, nilai, 240), W - PAD, y + 14);
    ctx.textAlign = "left";
    y += 28;
  };

  if (d.lunas) {
    // Kuitansi: kalimat baku "sudah terima dari … uang sejumlah … untuk pembayaran …"
    const nilaiX = PAD + 150, nilaiW = W - PAD - nilaiX;
    const label = (teks, dy) => {
      ctx.fillStyle = LEMBUT;
      ctx.font = f(13, 500);
      ctx.fillText(teks, PAD, y + dy);
    };

    label("Sudah terima dari", 16);
    ctx.fillStyle = TEKS;
    ctx.font = f(15, 700);
    ctx.fillText(potong(ctx, [d.customerName || "-", d.customerPhone].filter(Boolean).join(" · "), nilaiW), nilaiX, y + 16);
    y += 30;

    label("Uang sejumlah", 34);
    ctx.beginPath();
    ctx.roundRect(nilaiX, y, nilaiW, 56, 10);
    ctx.fillStyle = BIRU_MUDA;
    ctx.fill();
    ctx.fillStyle = BIRU;
    ctx.font = `italic 600 14px ${FONT}`;
    const kata = bungkus(ctx, `# ${terbilangRupiah(d.total)} #`, nilaiW - 28, 2);
    kata.forEach((b, i) => ctx.fillText(b, nilaiX + 14, y + (kata.length === 1 ? 33 : 24 + i * 20)));
    y += 56 + 18;

    label("Untuk pembayaran", 14);
    ctx.fillStyle = TEKS;
    ctx.font = f(13, 600);
    const untuk = `Sewa ${d.carLabel}${d.plate ? ` (${d.plate})` : ""}, ${waktu(d.start)} s/d ${waktu(d.end)} (${d.days} hari)`;
    bungkus(ctx, untuk, nilaiW, 2).forEach((b, i) => ctx.fillText(b, nilaiX, y + 14 + i * 20));
    y += 52 + 10;
  } else {
    judul("Data Penyewa");
    baris("Nama", d.customerName || "-");
    baris("No. HP", d.customerPhone || "-");
    y += 18;

    judul("Kendaraan");
    baris("Unit", d.carLabel + (d.plate ? ` · ${d.plate}` : ""));
    baris("Mulai", waktu(d.start));
    baris("Selesai", waktu(d.end));
    baris("Durasi", `${d.days} hari`);
    y += 18;
  }

  judul("Rincian Biaya");
  d.lines.forEach((l) => baris(l.label, rupiah(l.amount)));
  y += 18;

  // Kotak total
  const kotakH = adaCicilan(d) ? 134 : 82;
  ctx.beginPath();
  ctx.roundRect(PAD, y, W - PAD * 2, kotakH, 14);
  ctx.fillStyle = BIRU_MUDA;
  ctx.fill();
  ctx.strokeStyle = BIRU_GARIS;
  ctx.lineWidth = 1;
  ctx.stroke();

  // Kotak satu baris: total di tengah tinggi kotak; kotak ber-DP: total di baris atas.
  const [labelY, angkaY] = adaCicilan(d) ? [34, 40] : [47, 51];
  ctx.fillStyle = BIRU;
  ctx.font = f(13, 800);
  ctx.fillText(d.lunas ? "JUMLAH DITERIMA" : "TOTAL TAGIHAN", PAD + 20, y + labelY);
  ctx.textAlign = "right";
  ctx.font = f(26, 800);
  ctx.fillText(rupiah(d.total), W - PAD - 20, y + angkaY);
  ctx.textAlign = "left";

  if (d.lunas) {
    // Cap LUNAS, sedikit miring seperti stempel basah.
    const HIJAU = "#059669";
    ctx.save();
    ctx.translate(W / 2 - 10, y + 41);
    ctx.rotate(-0.14);
    ctx.strokeStyle = HIJAU;
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.roundRect(-66, -26, 132, 52, 8);
    ctx.stroke();
    ctx.fillStyle = HIJAU;
    ctx.textAlign = "center";
    ctx.font = f(24, 800);
    ctx.fillText("LUNAS", 0, 6);
    ctx.font = f(10, 700);
    ctx.fillText(waktu(d.lunasAt).split(",")[0], 0, 20);
    ctx.restore();
  }

  if (adaCicilan(d)) {
    ctx.strokeStyle = BIRU_GARIS;
    ctx.beginPath();
    ctx.moveTo(PAD + 20, y + 62.5);
    ctx.lineTo(W - PAD - 20, y + 62.5);
    ctx.stroke();

    ctx.fillStyle = LEMBUT;
    ctx.font = f(13, 500);
    ctx.fillText("Sudah dibayar", PAD + 20, y + 88);
    ctx.textAlign = "right";
    ctx.fillStyle = TEKS;
    ctx.font = f(13, 700);
    ctx.fillText(rupiah(d.dibayar), W - PAD - 20, y + 88);
    ctx.textAlign = "left";

    ctx.fillStyle = BIRU;
    ctx.font = f(14, 800);
    ctx.fillText("SISA BAYAR", PAD + 20, y + 116);
    ctx.textAlign = "right";
    ctx.font = f(18, 800);
    ctx.fillText(rupiah(d.sisa), W - PAD - 20, y + 117);
    ctx.textAlign = "left";
  }
  y += kotakH + 18;

  if (d.paymentMethod || d.statusLabel) {
    ctx.fillStyle = LEMBUT;
    ctx.font = f(12, 500);
    const keterangan = [
      d.paymentMethod ? `Metode pembayaran: ${d.paymentMethod}` : "",
      d.lunas ? `Dilunasi ${waktu(d.lunasAt)}` : d.statusLabel ? `Status: ${d.statusLabel}` : "",
    ].filter(Boolean).join("   ·   ");
    ctx.fillText(keterangan, PAD, y + 14);
    y += 34;
  }

  // Rekening tujuan pembayaran (diisi mitra di Akun Saya), hanya di invoice.
  const rek = barisRekening(d);
  if (rek.length) {
    judul("Pembayaran");
    rek.forEach(([label, nilai]) => baris(label, nilai, true));
    y += 18;
  }

  if (d.lunas) {
    // Tanda tangan penerima di kanan; kuitansi tanpa tanda tangan sering
    // dianggap kurang sah.
    const kolomX = W - PAD - 200, tengah = kolomX + 100;
    ctx.textAlign = "center";
    ctx.fillStyle = TEKS;
    ctx.font = f(12, 500);
    ctx.fillText(waktu(d.lunasAt).split(",")[0], tengah, y + 14);
    ctx.fillText("Penerima,", tengah, y + 32);
    ctx.strokeStyle = TEKS;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(kolomX + 10, y + 104.5);
    ctx.lineTo(kolomX + 190, y + 104.5);
    ctx.stroke();
    ctx.font = f(13, 700);
    ctx.fillText(potong(ctx, d.rentalName || "Rental Kendaraan", 190), tengah, y + 122);

    if (d.total > BATAS_METERAI) {
      ctx.setLineDash([4, 3]);
      ctx.strokeStyle = LEMBUT;
      ctx.strokeRect(kolomX - 104.5, y + 44.5, 96, 56);
      ctx.setLineDash([]);
      ctx.fillStyle = LEMBUT;
      ctx.font = f(10, 600);
      ctx.fillText("Meterai", kolomX - 56, y + 68);
      ctx.fillText("Rp10.000", kolomX - 56, y + 82);
      ctx.textAlign = "left";
      ctx.font = f(11, 500);
      bungkus(ctx, "Nominal di atas Rp5 juta wajib bermeterai Rp10.000 (UU 10/2020). Cetak lalu tempel meterai sebelum ditandatangani.", kolomX - 130 - PAD, 3)
        .forEach((b, i) => ctx.fillText(b, PAD, y + 56 + i * 16));
    }
    ctx.textAlign = "left";
  }

  // Kaki, ditempel dari bawah supaya sisa ruang tidak menggantung di tengah
  ctx.strokeStyle = GARIS;
  ctx.beginPath();
  ctx.moveTo(PAD, H - 76.5);
  ctx.lineTo(W - PAD, H - 76.5);
  ctx.stroke();

  ctx.fillStyle = TEKS;
  ctx.font = f(13, 700);
  ctx.fillText(`Terima kasih telah menyewa di ${potong(ctx, d.rentalName || "bohRental", 380)}.`, PAD, H - 48);
  // Logo bohRental tetap ada, kecil di kaki.
  let kakiX = PAD;
  if (logo) {
    ctx.drawImage(logo, PAD, H - 40, 16, 16);
    kakiX = PAD + 22;
  }
  ctx.fillStyle = LEMBUT;
  ctx.font = f(11, 500);
  ctx.fillText("Dibuat dengan bohRental — bohAntar SuperApp Kalbar.", kakiX, H - 28);

  return canvas;
}
