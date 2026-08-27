import logoImg from "../../assets/logo_b_icon.png";
import { rupiah, waktu } from "./invoice";

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

function muatGambar(src) {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null); // logo gagal dimuat bukan alasan invoice batal
    img.src = src;
  });
}

// Potong teks yang kepanjangan supaya tidak menabrak kolom nominal di kanan.
function potong(ctx, text, maxWidth) {
  let t = String(text ?? "");
  if (ctx.measureText(t).width <= maxWidth) return t;
  while (t.length > 1 && ctx.measureText(t + "…").width > maxWidth) t = t.slice(0, -1);
  return t + "…";
}

function tinggiInvoice(d) {
  const baris = 2 + 4 + d.lines.length;      // penyewa + kendaraan + rincian
  return 170 + 24                            // kepala + jarak
    + 3 * 34                                 // tiga judul bagian
    + baris * 28                             // isi
    + 3 * 18                                 // jarak antar bagian
    + (d.dp > 0 ? 152 : 100)                 // kotak total
    + (d.paymentMethod || d.statusLabel ? 34 : 0)
    + 104;                                   // kaki
}

export async function invoiceBlob(d) {
  // Inter dimuat lewat Google Fonts; tanpa menunggu, canvas bisa terlanjur
  // menggambar dengan font cadangan.
  if (document.fonts?.ready) await document.fonts.ready;
  const logo = await muatGambar(logoImg);

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

  // Kepala biru
  const grad = ctx.createLinearGradient(0, 0, W, 170);
  grad.addColorStop(0, BIRU);
  grad.addColorStop(1, BIRU_TERANG);
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, W, 170);

  if (logo) {
    const s = 54;
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(PAD, 38, s, s, 14);
    ctx.fillStyle = "#FFFFFF";
    ctx.fill();
    ctx.clip();
    ctx.drawImage(logo, PAD + 5, 43, s - 10, s - 10);
    ctx.restore();
  }

  ctx.fillStyle = "#FFFFFF";
  ctx.font = f(25, 800);
  ctx.fillText("bohRental", PAD + (logo ? 70 : 0), 62);
  ctx.font = f(13, 500);
  ctx.fillStyle = "rgba(255,255,255,0.85)";
  ctx.fillText(potong(ctx, d.rentalName || "Rental Kendaraan", 300), PAD + (logo ? 70 : 0), 82);

  ctx.textAlign = "right";
  ctx.fillStyle = "#FFFFFF";
  ctx.font = f(30, 800);
  ctx.fillText("INVOICE", W - PAD, 62);
  ctx.font = f(13, 500);
  ctx.fillStyle = "rgba(255,255,255,0.85)";
  ctx.fillText(`No. ${d.id}`, W - PAD, 84);
  ctx.fillText(waktu(new Date()), W - PAD, 104);
  ctx.textAlign = "left";

  let y = 170 + 24;

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

  judul("Rincian Biaya");
  d.lines.forEach((l) => baris(l.label, rupiah(l.amount)));
  y += 18;

  // Kotak total
  const kotakH = d.dp > 0 ? 134 : 82;
  ctx.beginPath();
  ctx.roundRect(PAD, y, W - PAD * 2, kotakH, 14);
  ctx.fillStyle = BIRU_MUDA;
  ctx.fill();
  ctx.strokeStyle = BIRU_GARIS;
  ctx.lineWidth = 1;
  ctx.stroke();

  ctx.fillStyle = BIRU;
  ctx.font = f(13, 800);
  ctx.fillText("TOTAL TAGIHAN", PAD + 20, y + 34);
  ctx.textAlign = "right";
  ctx.font = f(26, 800);
  ctx.fillText(rupiah(d.total), W - PAD - 20, y + 40);
  ctx.textAlign = "left";

  if (d.dp > 0) {
    ctx.strokeStyle = BIRU_GARIS;
    ctx.beginPath();
    ctx.moveTo(PAD + 20, y + 62.5);
    ctx.lineTo(W - PAD - 20, y + 62.5);
    ctx.stroke();

    ctx.fillStyle = LEMBUT;
    ctx.font = f(13, 500);
    ctx.fillText("Sudah dibayar (DP)", PAD + 20, y + 88);
    ctx.textAlign = "right";
    ctx.fillStyle = TEKS;
    ctx.font = f(13, 700);
    ctx.fillText(rupiah(d.dp), W - PAD - 20, y + 88);
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
      d.statusLabel ? `Status: ${d.statusLabel}` : "",
    ].filter(Boolean).join("   ·   ");
    ctx.fillText(keterangan, PAD, y + 14);
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
  ctx.fillStyle = LEMBUT;
  ctx.font = f(11, 500);
  ctx.fillText("Invoice ini dibuat otomatis oleh bohRental — bohAntar SuperApp Kalbar.", PAD, H - 28);

  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}
