// Sewa manual dan blokir perawatan sama-sama tersimpan di rental_car_schedules,
// dengan seluruh detail dijejalkan ke satu kolom `reason` berformat pipa:
//   "Booking - Customer: Budi (0812) | Pembayaran: Tunai | Tipe: DP | Nominal DP: 100000
//    | Jasa: Sopir | Biaya Jasa: 50000 | KTP: /uploads/a.jpg"
// Kalender dan Laporan sama-sama membacanya, jadi aturannya ditaruh di satu file.

const MANUAL_PREFIX = "Booking - Customer:";

// Warna pembeda armada di kalender. Dipilih pada tingkat terang yang sama supaya
// sama-sama terbaca di tema terang maupun gelap, dan cukup berjauhan agar dua
// mobil bersebelahan tidak tampak mirip.
export const CAR_COLORS = [
  "#2563EB", "#059669", "#D97706", "#DC2626", "#7C3AED",
  "#0891B2", "#DB2777", "#65A30D", "#EA580C", "#4F46E5"
];

// Warna dipilih berdasarkan urutan armada, bukan hasil hash: dengan begitu mobil
// ke-1 sampai ke-10 dijamin berbeda warna, sementara hash bisa memberi dua mobil
// warna yang sama. Pemilik yang sudah menentukan warna sendiri selalu menang.
export function carColor(carId, cars = []) {
  const urut = [...cars].sort((a, b) => String(a.id).localeCompare(String(b.id)));
  const idx = urut.findIndex(c => c.id === carId);
  if (idx < 0) return "#64748B";
  return urut[idx].color || CAR_COLORS[idx % CAR_COLORS.length];
}

function field(reason, label) {
  const m = reason.match(new RegExp(`${label}:\\s*([^|]*)`, "i"));
  return m ? m[1].trim() : "";
}

// "2026-08-25 08:00:00" bukan format yang dijamin Safari; ganti spasi jadi "T".
export function parseDT(value) {
  if (value instanceof Date) return value;
  return new Date(String(value || "").replace(" ", "T"));
}

// Aturan bentrok yang sama dengan backend: dua periode dianggap tabrakan bila
// yang satu mulai sebelum yang lain selesai. Bersentuhan di ujung (selesai jam
// 17:00, berikutnya mulai jam 17:00) bukan bentrok.
export function overlaps(aStart, aEnd, bStart, bEnd) {
  return parseDT(aStart) < parseDT(bEnd) && parseDT(aEnd) > parseDT(bStart);
}

// Sama dengan rentalDays() di backend: pembulatan ke atas, minimal 1 hari.
export function rentalDays(startStr, endStr) {
  const ms = parseDT(endStr) - parseDT(startStr);
  if (!isFinite(ms) || ms <= 0) return 0;
  return Math.max(1, Math.ceil(ms / 86400000));
}

export function parseSchedule(reason = "") {
  const raw = reason || "";
  const isManual = raw.startsWith(MANUAL_PREFIX);
  if (!isManual) {
    return {
      isManual: false,
      note: raw.replace(/\|\s*Dokumen:.*$/i, "").trim(),
      docUrl: field(raw, "Dokumen"),
      customerName: "",
      customerPhone: "",
      paymentMethod: "",
      paymentTerm: "",
      dpAmount: 0,
      serviceName: "",
      serviceFee: 0
    };
  }
  const who = raw.match(/Booking - Customer:\s*(.*?)\s*\((.*?)\)/i);
  return {
    isManual: true,
    note: "",
    docUrl: field(raw, "KTP"),
    customerName: who ? who[1] : "",
    customerPhone: who ? who[2] : "",
    paymentMethod: field(raw, "Pembayaran") || "Tunai",
    paymentTerm: field(raw, "Tipe") || "Full",
    dpAmount: parseFloat(field(raw, "Nominal DP")) || 0,
    serviceName: field(raw, "Jasa"),
    serviceFee: parseFloat(field(raw, "Biaya Jasa")) || 0
  };
}

// Riwayat transaksi rental berasal dari dua tabel: pesanan aplikasi
// (rental_bookings) dan jadwal yang dibuat sendiri di Kalender
// (rental_car_schedules, baik sewa manual maupun perawatan). Dashboard dan
// Laporan sama-sama butuh gabungannya, jadi bentuk barisnya disatukan di sini.
export function buildRows(bookings, schedules, cars) {
  const fromApp = bookings.map(b => ({
    id: b.id,
    carId: b.car_id,
    customer: b.customer_name || b.customer_phone,
    contact: b.customer_phone,
    start: b.start_time,
    end: b.end_time,
    // Denda keterlambatan sudah dikunci server saat sewa ditutup; di sini tinggal
    // ditambahkan ke tarif supaya laporan dan dashboard memakai angka yang sama.
    sewa: b.total_price,
    lateFee: b.late_fee || 0,
    total: b.total_price + (b.late_fee || 0),
    status: b.status,
    source: "app",
    sourceLabel: "Aplikasi",
    note: b.notes || "",
    // Data mentahnya ikut dibawa supaya Laporan bisa mencetak invoice tanpa
    // mencari ulang ke daftar asalnya.
    raw: b
  }));

  const fromCalendar = schedules.map(s => {
    const info = parseSchedule(s.reason);
    const car = cars.find(c => c.id === s.car_id);
    const cost = info.isManual
      ? scheduleCost(s.start_time, s.end_time, car?.price_per_day, info.serviceFee)
      : null;
    return {
      id: s.id,
      carId: s.car_id,
      customer: info.isManual ? (info.customerName || "Penyewa offline") : "-",
      contact: info.customerPhone,
      start: s.start_time,
      end: s.end_time,
      sewa: cost ? cost.total : 0,
      lateFee: s.late_fee || 0,
      total: (cost ? cost.total : 0) + (s.late_fee || 0),
      status: s.status === "completed" ? "completed" : (info.isManual ? "berjalan" : "perawatan"),
      source: info.isManual ? "manual" : "maintenance",
      sourceLabel: info.isManual ? "Manual (Offline)" : "Perawatan",
      note: info.isManual ? [info.serviceName, info.paymentMethod].filter(Boolean).join(" · ") : info.note,
      docUrl: info.docUrl,
      raw: s
    };
  });

  return [...fromApp, ...fromCalendar].sort((a, b) => parseDT(b.start) - parseDT(a.start));
}

// Status mentah dari dua tabel berbeda dirangkum jadi empat keranjang.
export function bucketOf(status) {
  if (status === "completed") return "selesai";
  if (status === "cancelled" || status === "rejected") return "batal";
  if (status === "pending") return "menunggu";
  return "berjalan";
}

// Sewa yang belum ditutup padahal jatuh temponya sudah lewat: kendaraannya masih
// di luar, jadi tetap dihitung terpakai sampai mitra menekan "Selesai".
export function isOverdue(row, now = new Date()) {
  return bucketOf(row.status) === "berjalan" && parseDT(row.end) < now;
}

// Tarif dihitung per hari: (harga sewa mobil + biaya jasa) x jumlah hari.
export function scheduleCost(startStr, endStr, pricePerDay = 0, serviceFee = 0) {
  const days = rentalDays(startStr, endStr);
  const rental = days * (Number(pricePerDay) || 0);
  const service = days * (Number(serviceFee) || 0);
  return { days, rental, service, total: rental + service };
}
