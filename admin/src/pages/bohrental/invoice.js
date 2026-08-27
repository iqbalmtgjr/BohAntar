import { useState, useEffect } from "react";
import { api } from "../../api";
import { parseSchedule, scheduleCost, parseDT, rentalDays } from "./schedule";

/*
 * Data invoice sewa, satu bentuk untuk dua keluaran: gambar PNG (invoiceImage.js)
 * dan teks pendamping saat dibagikan. Angkanya dihitung sekali di sini supaya
 * gambar dan teks tidak pernah berbeda.
 */

export const rupiah = (n) => "Rp " + Math.round(Number(n) || 0).toLocaleString("id-ID");

export const waktu = (v) => {
  const d = parseDT(v);
  return isNaN(d) ? "-" : d.toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" });
};

// Nomor Indonesia untuk wa.me harus tanpa "+" dan tanpa "0" di depan.
export function waNumber(phone) {
  const digits = String(phone || "").replace(/\D/g, "");
  if (!digits) return "";
  if (digits.startsWith("62")) return digits;
  return "62" + digits.replace(/^0+/, "");
}

// Cadangan kalau perangkat tidak punya Web Share: buka chat WhatsApp berisi teksnya,
// gambarnya dilampirkan manual setelah diunduh.
export function openWhatsApp(phone, text) {
  window.open(`https://wa.me/${waNumber(phone)}?text=${encodeURIComponent(text)}`, "_blank", "noopener");
}

// Kop invoice memakai nama usaha yang didaftarkan saat pengajuan kemitraan
// (business_name), bukan nama pribadi pemilik. Nama pemilik cuma jadi cadangan
// untuk akun lama yang pengajuannya tidak ditemukan.
// Satu permintaan per sesi, dibagi ke semua halaman yang membutuhkannya, dan
// sudah siap sebelum tombol ditekan.
let profileCache = null;
function loadProfile() {
  if (!profileCache) {
    profileCache = api.getProfile()
      .then((r) => r.business_name || r.user?.name || "")
      .catch(() => "");
  }
  return profileCache;
}

// Dipanggil setelah mitra menyimpan nama usahanya: cache sesi dibuang supaya
// halaman invoice berikutnya mengambil nama yang baru.
export function invalidateRentalName() {
  profileCache = null;
}

export function useRentalName() {
  const [name, setName] = useState("");
  useEffect(() => {
    let alive = true;
    loadProfile().then((n) => { if (alive) setName(n); });
    return () => { alive = false; };
  }, []);
  return name;
}

// Teks pendamping saat gambar dibagikan — sengaja ringkas, rinciannya ada di gambar.
export function invoiceCaption(d) {
  const judul = d.rentalName || "Rental Kendaraan";
  return [
    `*INVOICE SEWA — ${judul.toUpperCase()}*`,
    `No. ${d.id}`,
    `${d.customerName || "-"} · ${d.carLabel}${d.plate ? ` (${d.plate})` : ""}`,
    `${d.days} hari · Total ${rupiah(d.total)}`,
    d.dp > 0 ? `Sisa bayar ${rupiah(d.sisa)}` : "",
    ``,
    `Rincian lengkap ada di gambar invoice terlampir.`,
  ].filter(Boolean).join("\n");
}

// Pesanan yang masuk dari aplikasi bohAntar (tabel rental_bookings).
export function bookingInvoice(b, car, rentalName) {
  const days = rentalDays(b.start_time, b.end_time) || 1;
  const sewa = Number(b.total_price) || 0;
  const denda = Number(b.late_fee) || 0;
  const lines = [{ label: `Sewa ${days} hari`, amount: sewa }];
  if (denda > 0) lines.push({ label: "Denda keterlambatan", amount: denda });
  return {
    rentalName,
    id: b.id,
    customerName: b.customer_name,
    customerPhone: b.customer_phone,
    carLabel: car ? `${car.brand} ${car.model}` : "Kendaraan",
    plate: car?.plate_number || "",
    start: b.start_time,
    end: b.end_time,
    days,
    lines,
    total: sewa + denda,
    dp: 0,
    sisa: 0,
    paymentMethod: "",
    statusLabel: b.status ? String(b.status).toUpperCase() : "",
  };
}

// Sewa manual yang dicatat mitra sendiri di Kalender (tabel rental_car_schedules).
export function scheduleInvoice(s, car, rentalName) {
  const info = parseSchedule(s.reason);
  const cost = scheduleCost(s.start_time, s.end_time, car?.price_per_day, info.serviceFee);
  const denda = Number(s.late_fee) || 0;
  const lines = [{
    label: `Sewa ${cost.days} hari × ${rupiah(car?.price_per_day || 0)}`,
    amount: cost.rental,
  }];
  if (cost.service > 0) {
    lines.push({ label: `${info.serviceName || "Jasa"} ${cost.days} hari × ${rupiah(info.serviceFee)}`, amount: cost.service });
  }
  if (denda > 0) lines.push({ label: "Denda keterlambatan", amount: denda });
  const total = cost.total + denda;
  const dp = info.paymentTerm === "DP" ? (Number(info.dpAmount) || 0) : 0;
  return {
    rentalName,
    id: s.id,
    customerName: info.customerName,
    customerPhone: info.customerPhone,
    carLabel: car ? `${car.brand} ${car.model}` : "Kendaraan",
    plate: car?.plate_number || "",
    start: s.start_time,
    end: s.end_time,
    days: cost.days,
    lines,
    total,
    dp,
    sisa: Math.max(0, total - dp),
    paymentMethod: info.paymentMethod,
    statusLabel: s.status === "completed" ? "SELESAI" : "BERJALAN",
  };
}
