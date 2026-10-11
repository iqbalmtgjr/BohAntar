// Harga terendah yang mungkin dibayar: harga dasar + varian wajib termurah.
// Menu Kasvo sering Rp0 dengan harga di varian ("Isi 6 +Rp20.000"). Sama dengan
// hargaMulaiDari di aplikasi (mobile/lib/models/food.dart).
export const hargaMulaiDari = (m) => (m.option_groups || []).reduce((total, g) => {
  const minimal = !g.required ? 0 : (g.type === "single" || !(g.min >= 1) ? 1 : g.min);
  const termurah = g.options.map(o => o.price).sort((a, b) => a - b).slice(0, minimal);
  return total + termurah.reduce((a, b) => a + b, 0);
}, m.price);

// Ada varian berbayar, jadi harga akhirnya bisa lebih tinggi — ditulis "mulai Rp…".
export const hargaBisaNaik = (m) => (m.option_groups || []).some(g => g.options.some(o => o.price > 0));
