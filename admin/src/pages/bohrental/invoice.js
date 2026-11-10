import { useState, useEffect } from "react";
import { api } from "../../api";
import { parseSchedule, scheduleCost, parseDT, rentalDays, isUpcoming, statusBayar } from "./schedule";

/*
 * Data invoice sewa, satu bentuk untuk dua keluaran: gambar PNG (invoiceImage.js)
 * dan teks pendamping saat dibagikan. Angkanya dihitung sekali di sini supaya
 * gambar dan teks tidak pernah berbeda.
 */

// Nominal minus (diskon) ditulis "− Rp 50.000", bukan "Rp -50.000".
export const rupiah = (n) => {
  const v = Math.round(Number(n) || 0);
  return (v < 0 ? "− " : "") + "Rp " + Math.abs(v).toLocaleString("id-ID");
};

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

// Kop invoice: nama usaha (business_name, bukan nama pribadi pemilik — nama
// pemilik cuma cadangan untuk akun lama), alamat, No. HP akun, logo mitra, dan
// rekening pembayaran. Satu permintaan per sesi, dibagi ke semua halaman yang
// membutuhkannya, dan sudah siap sebelum tombol ditekan.
const KOP_KOSONG = { name: "", address: "", phone: "", logo: "", rekNama: "", rekBank: "", rekNomor: "" };
let profileCache = null;
function loadProfile() {
  if (!profileCache) {
    profileCache = api.getProfile()
      .then((r) => ({
        name: r.business_name || r.user?.name || "",
        address: r.business_address || "",
        phone: String(r.user?.phone_number || "").replace(/^\+?62/, "0"),
        logo: r.business_logo || "",
        rekNama: r.rek_nama || "",
        rekBank: r.rek_bank || "",
        rekNomor: r.rek_nomor || "",
      }))
      .catch(() => KOP_KOSONG);
  }
  return profileCache;
}

// Nomor dokumen yang dicetak: ID tanpa awalan teknis "schedule-"/"booking-".
// Invoice dan kuitansi satu sewa memakai nomor yang sama, labelnya yang beda.
export const nomorDokumen = (d) => String(d.id || "").replace(/^(schedule|booking)-/i, "").toUpperCase();
export const labelNomor = (d) => `No. ${d.jenis}: ${nomorDokumen(d)}`;

// Dipanggil setelah mitra menyimpan kop usahanya: cache sesi dibuang supaya
// invoice berikutnya memakai data yang baru.
export function invalidateRentalName() {
  profileCache = null;
}

export function useRentalProfile() {
  const [kop, setKop] = useState(KOP_KOSONG);
  useEffect(() => {
    let alive = true;
    loadProfile().then((k) => { if (alive) setKop(k); });
    return () => { alive = false; };
  }, []);
  return kop;
}

const kopInvoice = (rental) => ({
  rentalName: rental?.name || "",
  rentalAddress: rental?.address || "",
  rentalPhone: rental?.phone || "",
  rentalLogo: rental?.logo || "",
  rekNama: rental?.rekNama || "",
  rekBank: rental?.rekBank || "",
  rekNomor: rental?.rekNomor || "",
});

// Teks pendamping saat gambar dibagikan — sengaja ringkas, rinciannya ada di gambar.
export function invoiceCaption(d) {
  const judul = d.rentalName || "Rental Kendaraan";
  return [
    `*${d.jenis.toUpperCase()} SEWA — ${judul.toUpperCase()}*`,
    labelNomor(d),
    `${d.customerName || "-"} · ${d.carLabel}${d.plate ? ` (${d.plate})` : ""}`,
    `${d.days} hari · Total ${rupiah(d.total)}`,
    // Invoice = tagihan: tidak pernah menulis "sudah dibayar penuh" (masukan
    // mitra 9 Nov); yang lunas dibuktikan dengan kuitansi.
    d.lunas ? `LUNAS · ${waktu(d.lunasAt)}` : d.dibayar > 0 && d.sisa > 0 ? `Sisa bayar ${rupiah(d.sisa)}` : "",
    !d.lunas && d.rekNomor ? `Pembayaran: ${[d.rekBank, d.rekNomor, d.rekNama && `a.n. ${d.rekNama}`].filter(Boolean).join(" · ")}` : "",
    ``,
    `Rincian lengkap ada di gambar ${d.jenis.toLowerCase()} terlampir.`,
  ].filter(Boolean).join("\n");
}

// Bagian data yang menentukan dokumennya: invoice (tagihan) selama belum lunas,
// kuitansi (bukti terima uang) begitu lunas.
const dataBayar = (bayar) => ({
  jenis: bayar.lunas ? "Kuitansi" : "Invoice",
  dibayar: bayar.dibayar,
  sisa: bayar.sisa,
  lunas: bayar.lunas,
  lunasAt: bayar.lunasAt,
  ditandaiLunas: bayar.ditandai,
  paymentMethod: bayar.metode,
});

// Pesanan yang masuk dari aplikasi BohAntar (tabel rental_bookings).
export function bookingInvoice(b, car, rental) {
  const days = rentalDays(b.start_time, b.end_time) || 1;
  const sewa = Number(b.total_price) || 0;
  const denda = Number(b.late_fee) || 0;
  const lines = [{ label: `Sewa ${days} hari`, amount: sewa }];
  if (denda > 0) lines.push({ label: "Denda keterlambatan", amount: denda });
  return {
    ...kopInvoice(rental),
    ...dataBayar(statusBayar(sewa + denda, b)),
    sumber: "app",
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
    statusLabel: b.status ? String(b.status).toUpperCase() : "",
  };
}

// Sewa manual yang dicatat mitra sendiri di Kalender (tabel rental_car_schedules).
export function scheduleInvoice(s, car, rental) {
  const info = parseSchedule(s.reason);
  const cost = scheduleCost(s.start_time, s.end_time, car?.price_per_day, info.serviceFee, info.diskon);
  const denda = Number(s.late_fee) || 0;
  const lines = [{
    label: `Sewa ${cost.days} hari × ${rupiah(car?.price_per_day || 0)}`,
    amount: cost.rental,
  }];
  if (cost.service > 0) {
    lines.push({ label: `${info.serviceName || "Jasa"} ${cost.days} hari × ${rupiah(info.serviceFee)}`, amount: cost.service });
  }
  if (cost.discount > 0) {
    lines.push({ label: `Diskon${info.diskon.tipe === "persen" ? ` ${info.diskon.nilai}%` : ""}`, amount: -cost.discount });
  }
  if (denda > 0) lines.push({ label: "Denda keterlambatan", amount: denda });
  const total = cost.total + denda;
  // Yang sudah masuk saat booking hanya DP. "Bayar penuh" artinya penyewa akan
  // membayar penuh tanpa DP — belum dibayar sampai mitra menekan Tandai Lunas
  // (dulu dianggap lunas sejak dibuat; masukan mitra 9 Nov).
  const awal = {
    nominal: info.paymentTerm === "DP" ? (Number(info.dpAmount) || 0) : 0,
    waktu: s.created_at,
    metode: info.paymentMethod,
  };
  return {
    ...kopInvoice(rental),
    ...dataBayar(statusBayar(total, s, awal)),
    sumber: "manual",
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
    statusLabel: s.status === "completed" ? "SELESAI" : isUpcoming(s.start_time) ? "BOOKING" : "BERJALAN",
  };
}
