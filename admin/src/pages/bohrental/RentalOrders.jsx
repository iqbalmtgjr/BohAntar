import { useState, useEffect, useMemo } from "react";
import {
  ShoppingBag, Search, RefreshCw, CheckCircle2, XCircle, PlayCircle,
  Flag, Clock, Phone, User, CalendarDays, StickyNote, FileText
} from "lucide-react";
import { BASE, authFetch } from "../../api";
import { toast, Alert } from "../../components/Feedback";
import { bookingInvoice, useRentalName } from "./invoice";
import InvoiceModal from "./InvoiceModal";

// Peta status: label, warna badge, dan aksi lanjutan yang boleh dilakukan mitra.
// Urutannya sama dengan allowedTransition di backend — kalau salah satu diubah,
// yang satunya harus ikut.
const STATUS = {
  pending: { label: "Menunggu Konfirmasi", color: "#D97706", tint: "rgba(245, 158, 11, 0.14)" },
  confirmed: { label: "Disetujui", color: "#2563EB", tint: "rgba(37, 99, 235, 0.12)" },
  ongoing: { label: "Sedang Berjalan", color: "#7C3AED", tint: "rgba(124, 58, 237, 0.12)" },
  completed: { label: "Selesai", color: "#059669", tint: "rgba(5, 150, 105, 0.12)" },
  rejected: { label: "Ditolak", color: "#DC2626", tint: "rgba(220, 38, 38, 0.12)" },
  cancelled: { label: "Dibatalkan", color: "#64748B", tint: "rgba(100, 116, 139, 0.14)" }
};

const FILTERS = [
  { key: "all", label: "Semua" },
  { key: "pending", label: "Perlu Ditindak" },
  { key: "confirmed", label: "Disetujui" },
  { key: "ongoing", label: "Berjalan" },
  { key: "completed", label: "Selesai" },
  { key: "rejected", label: "Ditolak" },
  { key: "cancelled", label: "Dibatalkan" }
];

// Alasan cepat supaya mitra tidak perlu mengetik hal yang sama berulang kali.
const REJECT_PRESETS = [
  "Kendaraan sedang diservis",
  "Unit sudah disewa orang lain di tanggal tersebut",
  "Data penyewa belum lengkap",
  "Lokasi di luar jangkauan antar"
];

const toDate = (s) => (s ? new Date(String(s).replace(" ", "T")) : null);

const fmtDateTime = (s) => {
  const d = toDate(s);
  if (!d || isNaN(d)) return "-";
  return d.toLocaleString("id-ID", {
    day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit"
  });
};

// Sama dengan rentalDays di backend: sisa jam apa pun dibulatkan jadi satu hari.
const durationDays = (start, end) => {
  const a = toDate(start), b = toDate(end);
  if (!a || !b || isNaN(a) || isNaN(b) || b <= a) return 0;
  return Math.max(1, Math.ceil((b - a) / 86400000));
};

export default function RentalOrders({ ownerPhone }) {
  const [bookings, setBookings] = useState([]);
  const [cars, setCars] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState("pending");
  const [query, setQuery] = useState("");
  const [busyId, setBusyId] = useState(null);
  const [errorMsg, setErrorMsg] = useState("");

  // Modal catatan dipakai untuk dua aksi yang sama-sama butuh alasan.
  const [noteModal, setNoteModal] = useState(null); // { booking, status }
  const rentalName = useRentalName();
  const [invoice, setInvoice] = useState(null);
  const [note, setNote] = useState("");

  const fetchData = () => {
    setLoading(true);
    Promise.all([
      authFetch(`${BASE}/rental/bookings?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/cars?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json())
    ])
      .then(([bookingsData, carsData]) => {
        setBookings(Array.isArray(bookingsData) ? bookingsData : []);
        setCars(Array.isArray(carsData) ? carsData : []);
      })
      .catch(err => setErrorMsg(err.message || "Gagal memuat pesanan"))
      .finally(() => setLoading(false));
  };

  useEffect(() => { fetchData(); }, [ownerPhone]);

  const carOf = (id) => cars.find(c => c.id === id);

  const counts = useMemo(() => {
    const c = { all: bookings.length };
    for (const b of bookings) c[b.status] = (c[b.status] || 0) + 1;
    return c;
  }, [bookings]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return bookings
      .filter(b => filter === "all" || b.status === filter)
      .filter(b => {
        if (!q) return true;
        const car = cars.find(c => c.id === b.car_id);
        return [b.id, b.customer_name, b.customer_phone, car?.brand, car?.model, car?.plate_number]
          .filter(Boolean).join(" ").toLowerCase().includes(q);
      })
      .sort((a, b) => (toDate(b.created_at) || 0) - (toDate(a.created_at) || 0));
  }, [bookings, cars, filter, query]);

  const updateStatus = (booking, status, notes) => {
    setBusyId(booking.id);
    setErrorMsg("");
    authFetch(`${BASE}/rental/bookings/${booking.id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(notes ? { status, notes } : { status })
    })
      .then(async r => {
        const data = await r.json();
        if (!r.ok) throw new Error(data.error || "Gagal memperbarui pesanan");
        return data;
      })
      .then(data => {
        // Denda keterlambatan dihitung server saat pesanan ditutup; nominalnya
        // dikembalikan supaya mitra langsung tahu tagihan akhirnya bertambah.
        const pesan = `Pesanan ${booking.id} diubah menjadi "${STATUS[status]?.label || status}"` +
          (data.late_fee > 0 ? ` — denda keterlambatan Rp ${data.late_fee.toLocaleString("id-ID")} ditambahkan ke total` : "");
        if (data.late_fee > 0) toast.warning(pesan, 8000);
        else toast.success(pesan);
        setNoteModal(null);
        setNote("");
        fetchData();
      })
      .catch(err => setErrorMsg(err.message || "Gagal memperbarui pesanan"))
      .finally(() => setBusyId(null));
  };

  const askNote = (booking, status) => {
    setErrorMsg("");
    setNote("");
    setNoteModal({ booking, status });
  };

  const submitNote = (e) => {
    e.preventDefault();
    if (!note.trim()) {
      setErrorMsg("Catatan wajib diisi");
      return;
    }
    updateStatus(noteModal.booking, noteModal.status, note.trim());
  };

  const actionsFor = (b) => {
    if (b.status === "pending") {
      return [
        { label: "Setujui", icon: CheckCircle2, className: "btn btn-success btn-sm", run: () => updateStatus(b, "confirmed") },
        { label: "Tolak", icon: XCircle, className: "btn btn-danger btn-sm", run: () => askNote(b, "rejected") }
      ];
    }
    if (b.status === "confirmed") {
      return [
        { label: "Mulai Jalan", icon: PlayCircle, className: "btn btn-primary btn-sm", run: () => updateStatus(b, "ongoing") },
        { label: "Batalkan", icon: XCircle, className: "btn btn-danger btn-sm", run: () => askNote(b, "cancelled") }
      ];
    }
    if (b.status === "ongoing") {
      return [
        { label: "Selesaikan Sewa", icon: Flag, className: "btn btn-primary btn-sm", run: () => updateStatus(b, "completed") }
      ];
    }
    return [];
  };

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
        <div>
          <h1>Pesanan Masuk</h1>
          <p>Permintaan sewa yang dikirim penyewa lewat aplikasi bohAntar. Setujui atau tolak di sini — penolakan wajib disertai catatan alasan.</p>
        </div>
        <button onClick={fetchData} className="btn btn-ghost" disabled={loading}>
          <RefreshCw size={16} /> Muat Ulang
        </button>
      </div>

      {!noteModal && <Alert type="error">{errorMsg}</Alert>}

      {/* Ringkasan: angka yang paling sering dicari mitra tiap buka halaman */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(130px, 1fr))", gap: 10, marginBottom: 18 }}>
        {["pending", "confirmed", "ongoing", "completed", "rejected"].map(k => (
          <button
            key={k}
            onClick={() => setFilter(k)}
            className="card"
            style={{
              padding: "14px 12px", textAlign: "left", cursor: "pointer",
              border: filter === k ? `1px solid ${STATUS[k].color}` : "1px solid var(--border)"
            }}
          >
            <div style={{ fontSize: 11, fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.4, color: "var(--text-muted)" }}>
              {STATUS[k].label}
            </div>
            <div style={{ fontSize: 24, fontWeight: 800, color: STATUS[k].color, lineHeight: 1.2, marginTop: 4 }}>
              {counts[k] || 0}
            </div>
          </button>
        ))}
      </div>

      <div style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center", marginBottom: 18 }}>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {FILTERS.map(f => (
            <button
              key={f.key}
              onClick={() => setFilter(f.key)}
              className={filter === f.key ? "btn btn-primary btn-sm" : "btn btn-ghost btn-sm"}
            >
              {f.label}{counts[f.key] ? ` (${counts[f.key]})` : ""}
            </button>
          ))}
        </div>
        <div className="input-group" style={{ marginLeft: "auto", marginBottom: 0, minWidth: 220, flex: "1 1 220px", position: "relative" }}>
          <Search size={15} style={{ position: "absolute", left: 12, top: "50%", transform: "translateY(-50%)", color: "var(--text-muted)" }} />
          <input
            className="input"
            style={{ paddingLeft: 34 }}
            placeholder="Cari nama, No. HP, plat, atau ID pesanan"
            value={query}
            onChange={e => setQuery(e.target.value)}
          />
        </div>
      </div>

      {loading ? (
        <div className="spinner" style={{ margin: "60px auto" }}></div>
      ) : visible.length === 0 ? (
        <div className="card" style={{ textAlign: "center", padding: 50, color: "var(--text-muted)" }}>
          <ShoppingBag size={48} style={{ margin: "0 auto 16px", color: "var(--border)" }} />
          <h3>Tidak ada pesanan pada filter ini</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>
            Pesanan dari aplikasi bohAntar akan muncul di sini begitu penyewa mengirim permintaan sewa.
          </p>
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
          {visible.map(b => {
            const car = carOf(b.car_id);
            const st = STATUS[b.status] || { label: b.status, color: "#64748B", tint: "rgba(100,116,139,0.14)" };
            const days = durationDays(b.start_time, b.end_time);
            const actions = actionsFor(b);
            return (
              <div key={b.id} className="card" style={{ padding: 0, overflow: "hidden" }}>
                <div style={{
                  display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap",
                  padding: "14px 18px", borderBottom: "1px solid var(--border)", background: "var(--bg-input)"
                }}>
                  <div>
                    <div style={{ fontSize: 15, fontWeight: 800 }}>
                      {car ? `${car.brand} ${car.model}` : "Kendaraan tidak ditemukan"}
                    </div>
                    <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 2, display: "flex", gap: 8, flexWrap: "wrap" }}>
                      {car && <span style={{ fontFamily: "monospace" }}>{car.plate_number}</span>}
                      <span style={{ fontFamily: "monospace" }}>#{b.id}</span>
                    </div>
                  </div>
                  <span style={{
                    fontSize: 11, fontWeight: 800, letterSpacing: 0.3, textTransform: "uppercase",
                    padding: "6px 12px", borderRadius: 999, background: st.tint, color: st.color
                  }}>
                    {st.label}
                  </span>
                </div>

                <div style={{ padding: 18, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(190px, 1fr))", gap: 16 }}>
                  <div>
                    <div style={{ fontSize: 11, color: "var(--text-muted)", fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>Penyewa</div>
                    <div style={{ fontSize: 14, fontWeight: 700, display: "flex", alignItems: "center", gap: 6 }}>
                      <User size={14} style={{ color: "var(--text-muted)" }} /> {b.customer_name || "Tanpa nama"}
                    </div>
                    <a href={`tel:${b.customer_phone}`} style={{ fontSize: 13, color: "#3B82F6", display: "flex", alignItems: "center", gap: 6, marginTop: 4, textDecoration: "none" }}>
                      <Phone size={13} /> {b.customer_phone}
                    </a>
                  </div>

                  <div>
                    <div style={{ fontSize: 11, color: "var(--text-muted)", fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>Periode Sewa</div>
                    <div style={{ fontSize: 13, display: "flex", alignItems: "center", gap: 6 }}>
                      <CalendarDays size={14} style={{ color: "var(--text-muted)" }} /> {fmtDateTime(b.start_time)}
                    </div>
                    <div style={{ fontSize: 13, display: "flex", alignItems: "center", gap: 6, marginTop: 4 }}>
                      <Flag size={14} style={{ color: "var(--text-muted)" }} /> {fmtDateTime(b.end_time)}
                    </div>
                    <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>{days} hari sewa</div>
                  </div>

                  <div>
                    <div style={{ fontSize: 11, color: "var(--text-muted)", fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.4, marginBottom: 6 }}>Total Biaya</div>
                    <div style={{ fontSize: 19, fontWeight: 900, color: "var(--primary)" }}>
                      Rp {Number(b.total_price || 0).toLocaleString("id-ID")}
                    </div>
                    <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4, display: "flex", alignItems: "center", gap: 6 }}>
                      <Clock size={13} /> Masuk {fmtDateTime(b.created_at)}
                    </div>
                  </div>
                </div>

                {b.notes && (
                  <div style={{
                    margin: "0 18px 18px", padding: 12, borderRadius: 10,
                    background: st.tint, border: `1px solid ${st.color}33`
                  }}>
                    <div style={{ fontSize: 11, fontWeight: 800, textTransform: "uppercase", letterSpacing: 0.4, color: st.color, display: "flex", alignItems: "center", gap: 6 }}>
                      <StickyNote size={13} /> Catatan Mitra
                    </div>
                    <div style={{ fontSize: 13, marginTop: 6, lineHeight: 1.5 }}>{b.notes}</div>
                  </div>
                )}

                <div style={{ display: "flex", gap: 8, flexWrap: "wrap", justifyContent: "flex-end", padding: "0 18px 18px" }}>
                  <button
                    className="btn btn-ghost btn-sm"
                    onClick={() => setInvoice(bookingInvoice(b, car, rentalName))}
                  >
                    <FileText size={15} /> Invoice
                  </button>
                  {actions.map(a => (
                    <button key={a.label} className={a.className} onClick={a.run} disabled={busyId === b.id}>
                      <a.icon size={15} /> {busyId === b.id ? "Memproses..." : a.label}
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {noteModal && (
        <div
          onClick={() => setNoteModal(null)}
          style={{
            position: "fixed", inset: 0, background: "rgba(0,0,0,0.6)", backdropFilter: "blur(4px)",
            display: "flex", alignItems: "flex-start", justifyContent: "center", overflowY: "auto",
            padding: "clamp(12px, 6vw, 60px) 12px", zIndex: 9998
          }}
        >
          <div className="card" onClick={e => e.stopPropagation()} style={{ width: "100%", maxWidth: 520 }}>
            <div className="card-title">
              {noteModal.status === "rejected" ? "Tolak Pesanan" : "Batalkan Pesanan"}
            </div>
            <p style={{ fontSize: 13, color: "var(--text-secondary)", marginBottom: 16 }}>
              Catatan ini tersimpan pada pesanan <strong style={{ fontFamily: "monospace" }}>#{noteModal.booking.id}</strong> sebagai alasan resmi, dan bisa dilihat kembali kapan saja.
            </p>

            <form onSubmit={submitNote}>
              <Alert type="error">{errorMsg}</Alert>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 10 }}>
                {REJECT_PRESETS.map(p => (
                  <button key={p} type="button" className="btn btn-ghost btn-sm" onClick={() => setNote(p)}>
                    {p}
                  </button>
                ))}
              </div>
              <div className="input-group">
                <label>Catatan Alasan (wajib)</label>
                <textarea
                  className="input"
                  rows={4}
                  maxLength={500}
                  autoFocus
                  placeholder="Tulis alasan sejelas mungkin agar penyewa paham"
                  value={note}
                  onChange={e => setNote(e.target.value)}
                  style={{ resize: "vertical", minHeight: 96 }}
                />
                <div style={{ fontSize: 11, color: "var(--text-muted)", textAlign: "right", marginTop: 4 }}>
                  {note.length}/500
                </div>
              </div>
              <div style={{ display: "flex", gap: 8, justifyContent: "flex-end", marginTop: 8 }}>
                <button type="button" className="btn btn-ghost" onClick={() => setNoteModal(null)}>Batal</button>
                <button type="submit" className="btn btn-danger" disabled={busyId === noteModal.booking.id}>
                  {busyId === noteModal.booking.id ? "Memproses..." : noteModal.status === "rejected" ? "Tolak Pesanan" : "Batalkan Pesanan"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
      <InvoiceModal data={invoice} onClose={() => setInvoice(null)} />
    </div>
  );
}
