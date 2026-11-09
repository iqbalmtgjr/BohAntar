// PDF satu halaman A4 berisi satu gambar JPEG — cukup untuk invoice/kuitansi
// yang sudah digambar di canvas. Ditulis tangan (±40 baris) supaya tidak perlu
// jsPDF (±300 KB) hanya untuk menempel satu gambar.
// ponytail: satu halaman saja; kalau dokumen kelak lebih panjang dari A4,
// gambarnya mengecil agar muat — pecah per halaman bila itu terjadi.

const A4 = [595.28, 841.89]; // pt
const MARGIN = 28;

export function pdfSatuGambar(jpg, lebarPx, tinggiPx) {
  const enc = new TextEncoder();
  const [pw, ph] = A4;
  // Muat di lebar halaman; kalau masih kepanjangan, muat di tinggi.
  const k = Math.min((pw - 2 * MARGIN) / lebarPx, (ph - 2 * MARGIN) / tinggiPx);
  const w = +(lebarPx * k).toFixed(2), h = +(tinggiPx * k).toFixed(2);
  const x = +((pw - w) / 2).toFixed(2), y = +(ph - MARGIN - h).toFixed(2); // rata atas
  const isi = `q ${w} 0 0 ${h} ${x} ${y} cm /Im0 Do Q`;

  const objek = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pw} ${ph}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`,
    [`<< /Type /XObject /Subtype /Image /Width ${lebarPx} /Height ${tinggiPx} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpg.length} >>\nstream\n`, jpg, "\nendstream"],
    `<< /Length ${isi.length} >>\nstream\n${isi}\nendstream`,
  ];

  const bagian = [];
  let panjang = 0;
  const tulis = (b) => { const u = typeof b === "string" ? enc.encode(b) : b; bagian.push(u); panjang += u.length; };
  tulis("%PDF-1.4\n");
  const posisi = [];
  objek.forEach((o, i) => {
    posisi.push(panjang);
    tulis(`${i + 1} 0 obj\n`);
    (Array.isArray(o) ? o : [o]).forEach(tulis);
    tulis("\nendobj\n");
  });
  const xref = panjang;
  tulis(`xref\n0 ${objek.length + 1}\n0000000000 65535 f \n`);
  posisi.forEach((p) => tulis(`${String(p).padStart(10, "0")} 00000 n \n`));
  tulis(`trailer\n<< /Size ${objek.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);

  const hasil = new Uint8Array(panjang);
  let o = 0;
  for (const b of bagian) { hasil.set(b, o); o += b.length; }
  return hasil;
}
