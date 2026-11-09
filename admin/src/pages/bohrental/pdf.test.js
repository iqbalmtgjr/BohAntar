// Jalankan: node --test src/pages/bohrental/pdf.test.js
import test from "node:test";
import assert from "node:assert/strict";
import { pdfSatuGambar } from "./pdf.js";

test("xref menunjuk tepat ke tiap objek dan gambar tertanam utuh", () => {
  const jpg = new Uint8Array([0xff, 0xd8, 0x00, 0x0a, 0x0d, 0xff, 0xd9]); // byte biner, termasuk \n dan \r
  const pdf = pdfSatuGambar(jpg, 1520, 1760);
  const teks = Buffer.from(pdf).toString("latin1");

  assert.ok(teks.startsWith("%PDF-1.4\n"));
  assert.ok(teks.endsWith("%%EOF\n"));

  const startxref = Number(teks.match(/startxref\n(\d+)\n%%EOF/)[1]);
  assert.ok(teks.slice(startxref).startsWith("xref\n0 6\n"), "startxref harus menunjuk tabel xref");

  const entri = teks.slice(startxref).split("\n").slice(3, 8);
  entri.forEach((e, i) => {
    assert.equal(e.length, 19, "tiap entri xref 20 byte termasuk \\n");
    const posisi = Number(e.slice(0, 10));
    assert.ok(teks.slice(posisi).startsWith(`${i + 1} 0 obj\n`), `xref objek ${i + 1} meleset`);
  });

  // Gambar disalin byte demi byte di antara "stream\n" dan "\nendstream".
  const awal = teks.indexOf("/DCTDecode /Length 7 >>\nstream\n") + "/DCTDecode /Length 7 >>\nstream\n".length;
  assert.deepEqual([...pdf.slice(awal, awal + jpg.length)], [...jpg]);
  // Gambar 1520×1760 dimuat di A4 dengan margin dan rata atas.
  assert.match(teks, /q 539\.28 0 0 624\.43 28 189\.46 cm \/Im0 Do Q/);
});
