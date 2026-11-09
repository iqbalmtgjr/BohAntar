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
    serviceFee: parseFloat(field(raw, "Biaya Jasa")) || 0,
    diskon: parseDiskon(field(raw, "Diskon"))
  };
}

// Diskon sewa manual tersimpan di reason sebagai "Diskon: 10%" (persen) atau
// "Diskon: 50000" (nominal rupiah).
export function parseDiskon(teks = "") {
  const nilai = parseFloat(String(teks).replace(/[^\d.]/g, "")) || 0;
  if (nilai <= 0) return { tipe: "", nilai: 0 };
  return { tipe: String(teks).includes("%") ? "persen" : "nominal", nilai };
}

export function diskonReason(d) {
  if (!d?.tipe || !(Number(d.nilai) > 0)) return "";
  return ` | Diskon: ${Number(d.nilai)}${d.tipe === "persen" ? "%" : ""}`;
}

// Jadwal yang belum mulai = booking untuk hari mendatang. Status di database
// tetap "active"; ini hanya label supaya mitra bisa membedakannya dari yang
// sedang jalan.
export const isUpcoming = (start, now = new Date()) => parseDT(start) > now;

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
      ? scheduleCost(s.start_time, s.end_time, car?.price_per_day, info.serviceFee, info.diskon)
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

// Tarif dihitung per hari: (harga sewa mobil + biaya jasa) x jumlah hari,
// lalu dikurangi diskon. Diskon tidak pernah melebihi subtotal.
export function scheduleCost(startStr, endStr, pricePerDay = 0, serviceFee = 0, diskon = null) {
  const days = rentalDays(startStr, endStr);
  const rental = days * (Number(pricePerDay) || 0);
  const service = days * (Number(serviceFee) || 0);
  const subtotal = rental + service;
  const n = Number(diskon?.nilai) || 0;
  const discount = Math.min(subtotal, Math.max(0,
    diskon?.tipe === "persen" ? Math.round(subtotal * Math.min(n, 100) / 100)
    : diskon?.tipe === "nominal" ? n : 0));
  return { days, rental, service, subtotal, discount, total: subtotal - discount };
}

// Pembayaran sewa: berapa yang sudah masuk, kapan, dan apakah sudah lunas.
// Pelunasan yang ditandai mitra (lunas_at) selalu menang. Tanpa itu, `awal`
// (bayar saat booking manual: penuh atau DP) yang dipakai. Lunas dibanding
// total TERMASUK denda, jadi denda yang muncul setelah pelunasan membuat
// statusnya kembali belum lunas sebesar dendanya.
export function statusBayar(total, rec = {}, awal = null) {
  const ditandai = Boolean(rec?.lunas_at);
  const dibayar = ditandai ? Number(rec.lunas_nominal) || 0 : Number(awal?.nominal) || 0;
  const lunas = total > 0 && dibayar >= total;
  return {
    dibayar,
    sisa: Math.max(0, total - dibayar),
    lunas,
    lunasAt: lunas ? (ditandai ? rec.lunas_at : awal?.waktu || "") : "",
    metode: ditandai ? rec.lunas_metode || "" : awal?.metode || "",
    ditandai,
  };
}

const ANGKA = ["", "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "delapan", "sembilan", "sepuluh", "sebelas"];

// Angka ke kata untuk kuitansi: 1260000 -> "satu juta dua ratus enam puluh ribu".
export function terbilang(n) {
  n = Math.floor(Math.abs(Number(n) || 0));
  const gabung = (a, b) => `${a} ${b}`.trim();
  if (n < 12) return ANGKA[n];
  if (n < 20) return gabung(terbilang(n - 10), "belas");
  if (n < 100) return gabung(`${terbilang(Math.floor(n / 10))} puluh`, terbilang(n % 10));
  if (n < 200) return gabung("seratus", terbilang(n - 100));
  if (n < 1000) return gabung(`${terbilang(Math.floor(n / 100))} ratus`, terbilang(n % 100));
  if (n < 2000) return gabung("seribu", terbilang(n - 1000));
  for (const [besar, nama] of [[1e12, "triliun"], [1e9, "miliar"], [1e6, "juta"], [1e3, "ribu"]]) {
    if (n >= besar) return gabung(`${terbilang(Math.floor(n / besar))} ${nama}`, terbilang(n % besar));
  }
  return "";
}

export const terbilangRupiah = (n) => {
  const kata = `${terbilang(n) || "nol"} rupiah`;
  return kata.charAt(0).toUpperCase() + kata.slice(1);
};
