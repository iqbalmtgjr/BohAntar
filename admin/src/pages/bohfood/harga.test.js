// Jalankan: node --test src/pages/bohfood/harga.test.js
import test from "node:test";
import assert from "node:assert/strict";
import { hargaMulaiDari, hargaBisaNaik } from "./harga.js";

const opsi = (...harga) => harga.map((price, i) => ({ name: `o${i}`, price }));

test("menu Kasvo Rp0: harga diambil dari varian wajib termurah", () => {
  // Bentuk "Dimsum ayam udang" di produksi.
  const m = {
    price: 0,
    option_groups: [
      { name: "Saus", type: "single", required: true, options: opsi(0, 3000, 5000) },
      { name: "Topping", type: "multiple", required: false, options: opsi(0, 2000) },
      { name: "Jumlah Isi", type: "single", required: true, options: opsi(29000, 22000, 39000) },
    ],
  };
  assert.equal(hargaMulaiDari(m), 22000);
  assert.equal(hargaBisaNaik(m), true);
});

test("varian wajib pilih banyak menjumlah min opsi termurah", () => {
  const m = { price: 5000, option_groups: [{ type: "multiple", required: true, min: 2, options: opsi(3000, 1000, 2000) }] };
  assert.equal(hargaMulaiDari(m), 8000);
});

test("menu tanpa varian tetap harga dasar", () => {
  const m = { price: 18000 };
  assert.equal(hargaMulaiDari(m), 18000);
  assert.equal(hargaBisaNaik(m), false);
});
