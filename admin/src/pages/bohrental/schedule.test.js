// Jalankan: node --test src/pages/bohrental/schedule.test.js
import test from "node:test";
import assert from "node:assert/strict";
import { parseSchedule, rentalDays, scheduleCost, overlaps, buildRows, carColor, CAR_COLORS } from "./schedule.js";

test("reason sewa manual terbaca utuh", () => {
  const r = parseSchedule(
    "Booking - Customer: Budi Santoso (08123) | Pembayaran: Transfer | Tipe: DP | Nominal DP: 200000 | Jasa: Sopir | Biaya Jasa: 150000 | KTP: /uploads/a.jpg"
  );
  assert.equal(r.isManual, true);
  assert.equal(r.customerName, "Budi Santoso");
  assert.equal(r.customerPhone, "08123");
  assert.equal(r.paymentMethod, "Transfer");
  assert.equal(r.paymentTerm, "DP");
  assert.equal(r.dpAmount, 200000);
  assert.equal(r.serviceName, "Sopir");
  assert.equal(r.serviceFee, 150000);
  assert.equal(r.docUrl, "/uploads/a.jpg");
});

test("blokir perawatan bukan transaksi", () => {
  const r = parseSchedule("Servis Berkala | Dokumen: /uploads/b.pdf");
  assert.equal(r.isManual, false);
  assert.equal(r.note, "Servis Berkala");
  assert.equal(r.docUrl, "/uploads/b.pdf");
});

test("durasi dibulatkan ke atas, minimal sehari", () => {
  assert.equal(rentalDays("2026-08-01 08:00:00", "2026-08-04 08:00:00"), 3);
  assert.equal(rentalDays("2026-08-01 08:00:00", "2026-08-04 10:00:00"), 4);
  assert.equal(rentalDays("2026-08-01 08:00:00", "2026-08-01 10:00:00"), 1);
  assert.equal(rentalDays("2026-08-01 08:00:00", "2026-08-01 08:00:00"), 0);
});

test("kendaraan dianggap sibuk hanya bila periodenya beririsan", () => {
  const jadwal = ["2026-08-25 08:00:00", "2026-08-26 17:00:00"];
  // Periode yang menumpuk sebagian, menelan, dan ditelan.
  assert.equal(overlaps("2026-08-26 08:00:00", "2026-08-27 17:00:00", ...jadwal), true);
  assert.equal(overlaps("2026-08-24 08:00:00", "2026-08-28 17:00:00", ...jadwal), true);
  assert.equal(overlaps("2026-08-25 10:00:00", "2026-08-25 12:00:00", ...jadwal), true);
  // Bersentuhan tepat di ujung dan yang benar-benar terpisah tidak bentrok.
  assert.equal(overlaps("2026-08-26 17:00:00", "2026-08-27 17:00:00", ...jadwal), false);
  assert.equal(overlaps("2026-08-20 08:00:00", "2026-08-25 08:00:00", ...jadwal), false);
  // Objek Date (jendela "sekarang" di form) ikut diterima.
  assert.equal(overlaps(new Date("2026-08-25T09:00:00"), new Date("2026-08-25T09:01:00"), ...jadwal), true);
});

test("3 hari = 3 x (harga sewa + jasa)", () => {
  const c = scheduleCost("2026-08-01 08:00:00", "2026-08-04 08:00:00", 300000, 150000);
  assert.deepEqual(c, { days: 3, rental: 900000, service: 450000, total: 1350000 });
  assert.equal(scheduleCost("2026-08-01 08:00:00", "2026-08-04 08:00:00", 300000).total, 900000);
});

test("denda keterlambatan ikut masuk total transaksi", () => {
  const cars = [{ id: "c1", price_per_day: 300000 }];
  const schedules = [{
    id: "s1", car_id: "c1", status: "completed", late_fee: 150000,
    start_time: "2026-08-01 08:00:00", end_time: "2026-08-04 08:00:00",
    reason: "Booking - Customer: Budi (0812) | Pembayaran: Tunai | Tipe: Full"
  }];
  const bookings = [{
    id: "b1", car_id: "c1", customer_phone: "0899", customer_name: "Sari",
    start_time: "2026-07-01 08:00:00", end_time: "2026-07-02 08:00:00",
    total_price: 300000, late_fee: 60000, status: "completed", notes: ""
  }];

  const [manual, app] = buildRows(bookings, schedules, cars);
  assert.equal(manual.sewa, 900000);
  assert.equal(manual.lateFee, 150000);
  assert.equal(manual.total, 1050000);
  assert.equal(app.total, 360000);

  // Perawatan tetap tanpa tarif, dan sewa tanpa denda tidak berubah nilainya.
  const tanpaDenda = buildRows([], [{ ...schedules[0], late_fee: 0 }], cars)[0];
  assert.equal(tanpaDenda.total, 900000);
  const servis = buildRows([], [{ ...schedules[0], reason: "Servis Berkala", late_fee: 0 }], cars)[0];
  assert.equal(servis.source, "maintenance");
  assert.equal(servis.total, 0);
});

test("lampiran jadwal ikut terbawa ke baris laporan", () => {
  const cars = [{ id: "c1", price_per_day: 300000 }];
  const base = {
    id: "s1", car_id: "c1", status: "completed",
    start_time: "2026-08-01 08:00:00", end_time: "2026-08-02 08:00:00"
  };
  const manual = buildRows([], [{ ...base, reason: "Booking - Customer: Budi (0812) | KTP: /uploads/a.jpg" }], cars)[0];
  assert.equal(manual.docUrl, "/uploads/a.jpg");
  const servis = buildRows([], [{ ...base, reason: "Servis Berkala | Dokumen: /uploads/b.pdf" }], cars)[0];
  assert.equal(servis.docUrl, "/uploads/b.pdf");
  const tanpa = buildRows([], [{ ...base, reason: "Servis Berkala" }], cars)[0];
  assert.equal(tanpa.docUrl, "");
});

test("tiap armada dapat warna berbeda, pilihan owner menang", () => {
  const cars = [{ id: "c3" }, { id: "c1" }, { id: "c2" }];
  const warna = cars.map(c => carColor(c.id, cars));
  assert.equal(new Set(warna).size, 3, "tiga mobil harus dapat tiga warna berbeda");

  // Urutannya stabil: menambah mobil baru tidak mengacak warna yang sudah ada.
  const lebihBanyak = [...cars, { id: "c9" }];
  assert.equal(carColor("c1", lebihBanyak), carColor("c1", cars));

  // Warna pilihan pemilik mengalahkan warna otomatis.
  const dipilih = [{ id: "c1", color: "#DB2777" }, { id: "c2" }];
  assert.equal(carColor("c1", dipilih), "#DB2777");
  assert.notEqual(carColor("c2", dipilih), "#DB2777");

  // Armada ke-11 mengulang palet, bukan menghasilkan warna kosong.
  const banyak = Array.from({ length: 11 }, (_, i) => ({ id: `c${String(i).padStart(2, "0")}` }));
  assert.equal(carColor("c10", banyak), CAR_COLORS[10 % CAR_COLORS.length]);
  assert.ok(carColor("c10", banyak));

  // Mobil yang sudah dihapus tidak bikin kalender error.
  assert.equal(carColor("hilang", cars), "#64748B");
});
