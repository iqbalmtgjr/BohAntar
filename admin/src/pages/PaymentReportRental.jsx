import { useState, useEffect } from "react";
import { DollarSign, CheckCircle2, AlertCircle, Search, RefreshCw, Filter, CalendarPlus } from "lucide-react";
import { BASE, authFetch } from "../api";
import { Alert, toast } from "../components/Feedback";

const HARGA_BULANAN = 100000; // sama dengan tagihan Xendit di subscriptionCreateHandler

const keTanggal = (s) => new Date(String(s).replace(" ", "T"));
const tglPanjang = (d) => d.toLocaleDateString("id-ID", { day: "numeric", month: "long", year: "numeric" });
const sisaHari = (vu) => (vu ? Math.ceil((keTanggal(vu) - Date.now()) / 86400000) : null);

// Sama dengan aturan webhook Xendit: ditambahkan ke tanggal habis kalau masih
// berlaku, dihitung dari hari ini kalau sudah lewat.
function berlakuBaru(vu, bulan) {
  const habis = vu ? keTanggal(vu) : null;
  const dasar = habis && habis > new Date() ? habis : new Date();
  const baru = new Date(dasar);
  baru.setMonth(baru.getMonth() + bulan);
  return baru;
}

// Nilai <input type="date">: "YYYY-MM-DD" dalam jam lokal, bukan UTC.
function tglInput(d) {
  const t = new Date(d);
  t.setMinutes(t.getMinutes() - t.getTimezoneOffset());
  return t.toISOString().slice(0, 10);
}

// Mengisi form dari jumlah bulan: tanggal berlaku dan nominal ikut dihitung.
const dariBulan = (form, bulan) => ({
  ...form,
  bulan,
  sampai: tglInput(berlakuBaru(form.mitra.valid_until, bulan)),
  nominal: String(HARGA_BULANAN * bulan),
});

const STATUS_LANGGANAN = {
  ACTIVE: { label: "Aktif", badge: "badge-success" },
  TRIAL: { label: "Masa Percobaan", badge: "badge-info" },
  EXPIRED: { label: "Habis", badge: "badge-danger" },
  BELUM: { label: "Belum mulai", badge: "badge-warning" },
};

// Langganan semua mitra rental: siapa yang segera/sudah habis, plus perpanjangan
// manual untuk mitra yang membayar tunai/transfer langsung.
function LanggananMitra({ onUbah }) {
  const [daftar, setDaftar] = useState([]);
  const [memuat, setMemuat] = useState(true);
  const [filter, setFilter] = useState("semua"); // semua | segera | habis
  // { mitra, bulan (null = tanggal dipilih langsung), sampai "YYYY-MM-DD", nominal, catatan }
  const [form, setForm] = useState(null);
  const [menyimpan, setMenyimpan] = useState(false);

  const ambil = () => {
    setMemuat(true);
    authFetch(`${BASE}/admin/rental/langganan`)
      .then((r) => r.json())
      .then((d) => setDaftar(Array.isArray(d) ? d : []))
      .catch(() => toast.error("Gagal memuat langganan mitra"))
      .finally(() => setMemuat(false));
  };
  useEffect(ambil, []);

  const kategori = (m) => {
    if (m.status === "EXPIRED") return "habis";
    if (m.status !== "BELUM" && sisaHari(m.valid_until) <= 7) return "segera";
    return "aman";
  };
  const jumlah = (k) => daftar.filter((m) => kategori(m) === k).length;
  const tampil = daftar.filter((m) => filter === "semua" || kategori(m) === filter);
  const nama = (m) => m.business_name || m.name || m.phone_number;

  const kirim = async (e) => {
    e.preventDefault();
    setMenyimpan(true);
    try {
      const res = await authFetch(`${BASE}/admin/rental/langganan`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          phone_number: form.mitra.phone_number,
          sampai: form.sampai,
          nominal: Number(form.nominal) || 0,
          catatan: form.catatan,
        }),
      });
      const j = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(j.error || "Gagal memperpanjang langganan");
      toast.success(`Langganan ${nama(form.mitra)} diperpanjang s/d ${tglPanjang(keTanggal(j.valid_until))}`);
      setForm(null);
      ambil();
      onUbah();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setMenyimpan(false);
    }
  };

  return (
    <div className="table-wrap" style={{ marginBottom: 32 }}>
      <div className="table-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 12 }}>
        <h3>Langganan Mitra ({daftar.length})</h3>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {[["semua", "Semua"], ["segera", `Akan habis ≤ 7 hari (${jumlah("segera")})`], ["habis", `Sudah habis (${jumlah("habis")})`]].map(([k, label]) => (
            <button key={k} type="button" className={filter === k ? "btn btn-primary btn-sm" : "btn btn-ghost btn-sm"} onClick={() => setFilter(k)}>
              {label}
            </button>
          ))}
        </div>
      </div>
      <table>
        <thead>
          <tr>
            <th>Mitra</th>
            <th>Nomor HP</th>
            <th>Status</th>
            <th>Berlaku s/d</th>
            <th>Sisa</th>
            <th>Aksi</th>
          </tr>
        </thead>
        <tbody>
          {memuat ? (
            <tr><td colSpan="6" style={{ textAlign: "center", padding: 30 }}><span className="spinner" /></td></tr>
          ) : tampil.length === 0 ? (
            <tr><td colSpan="6" style={{ textAlign: "center", color: "var(--text-muted)", padding: 30 }}>Tidak ada mitra pada filter ini.</td></tr>
          ) : tampil.map((m) => {
            const st = STATUS_LANGGANAN[m.status] || { label: m.status, badge: "badge-info" };
            const sisa = sisaHari(m.valid_until);
            const k = kategori(m);
            return (
              <tr key={m.phone_number}>
                <td data-label="Mitra">
                  <strong>{nama(m)}</strong>
                  {m.business_name && m.name && <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{m.name}</div>}
                </td>
                <td data-label="Nomor HP">{m.phone_number}</td>
                <td data-label="Status"><span className={`badge ${st.badge}`}>{st.label}</span></td>
                <td data-label="Berlaku s/d">{m.valid_until ? tglPanjang(keTanggal(m.valid_until)) : "—"}</td>
                <td data-label="Sisa" style={{ fontWeight: 700, color: k === "habis" ? "#DC2626" : k === "segera" ? "#B45309" : "var(--text-primary)" }}>
                  {m.status === "BELUM" ? <span style={{ fontWeight: 400, color: "var(--text-muted)" }}>trial 14 hari mulai saat login</span>
                    : sisa < 0 ? `lewat ${-sisa} hari` : `${sisa} hari`}
                </td>
                <td data-label="Aksi">
                  <button type="button" className="btn btn-primary btn-sm" onClick={() => setForm(dariBulan({ mitra: m, catatan: "" }, 1))}>
                    <CalendarPlus size={14} /> Perpanjang
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      {form && (
        <div
          onClick={() => setForm(null)}
          style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.6)", display: "flex", alignItems: "flex-start", justifyContent: "center", overflowY: "auto", padding: "clamp(12px, 6vw, 60px) 12px", zIndex: 9998 }}
        >
          <form className="card" onClick={(e) => e.stopPropagation()} onSubmit={kirim} style={{ width: "100%", maxWidth: 460 }}>
            <div className="card-title">Perpanjang Langganan</div>
            <p style={{ fontSize: 13, color: "var(--text-secondary)", marginBottom: 14 }}>
              <strong>{nama(form.mitra)}</strong> · {form.mitra.phone_number}<br />
              Berlaku sekarang: {form.mitra.valid_until ? tglPanjang(keTanggal(form.mitra.valid_until)) : "belum mulai"}
            </p>
            <div className="input-group">
              <label>Lama perpanjangan</label>
              <div style={{ display: "flex", gap: 6, flexWrap: "wrap", alignItems: "center" }}>
                {[1, 3, 6, 12].map((b) => (
                  <button key={b} type="button" className={form.bulan === b ? "btn btn-primary btn-sm" : "btn btn-ghost btn-sm"}
                    onClick={() => setForm(dariBulan(form, b))}>
                    {b} bulan
                  </button>
                ))}
                <span style={{ fontSize: 12, color: "var(--text-muted)" }}>atau</span>
                <input
                  className="input" type="number" min="1" max="120" placeholder="…" aria-label="Jumlah bulan"
                  value={form.bulan ?? ""}
                  onChange={(e) => {
                    const n = parseInt(e.target.value, 10);
                    // Selama angkanya belum sah (kosong saat mengetik), tanggal tidak diubah.
                    setForm(n >= 1 && n <= 120 ? dariBulan(form, n) : { ...form, bulan: e.target.value === "" ? null : form.bulan });
                  }}
                  style={{ width: 80, padding: "6px 10px" }}
                />
                <span style={{ fontSize: 12, color: "var(--text-muted)" }}>bulan</span>
              </div>
            </div>
            <div className="input-group">
              <label>Berlaku sampai tanggal</label>
              <input
                className="input" type="date" required min={tglInput(new Date())} value={form.sampai}
                onChange={(e) => setForm({ ...form, sampai: e.target.value, bulan: null })}
              />
              <small style={{ display: "block", fontSize: 11, color: "var(--text-muted)", marginTop: 4 }}>
                Terisi otomatis dari pilihan bulan; boleh diubah langsung. Berlaku sampai akhir hari tersebut.
              </small>
            </div>
            <div className="input-group">
              <label>Nominal diterima (Rp)</label>
              <input className="input" type="number" min="0" step="1000" required value={form.nominal}
                onChange={(e) => setForm({ ...form, nominal: e.target.value })} />
              <small style={{ display: "block", fontSize: 11, color: "var(--text-muted)", marginTop: 4 }}>Isi 0 kalau perpanjangan gratis (bonus/kompensasi).</small>
            </div>
            <div className="input-group">
              <label>Catatan</label>
              <input className="input" maxLength={200} placeholder="Contoh: transfer BRI 9 Nov" value={form.catatan}
                onChange={(e) => setForm({ ...form, catatan: e.target.value })} />
            </div>
            {form.sampai && (
              <div style={{ fontSize: 13, background: "var(--bg-input)", border: "1px solid var(--border)", borderRadius: 10, padding: 12, marginBottom: 14 }}>
                Berlaku s/d baru: <strong>{tglPanjang(keTanggal(`${form.sampai} 00:00:00`))}</strong>
                {form.bulan ? ` (+${form.bulan} bulan)` : ""}
              </div>
            )}
            <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
              <button type="button" className="btn btn-ghost" onClick={() => setForm(null)}>Batal</button>
              <button type="submit" className="btn btn-primary" disabled={menyimpan}>{menyimpan ? "Menyimpan…" : "Perpanjang"}</button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}

export default function PaymentReportRental() {
  const [invoices, setInvoices] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState("ALL");
  const [error, setError] = useState("");

  // diam = muat ulang tanpa spinner satu halaman (setelah perpanjangan manual).
  const fetchReports = (diam = false) => {
    if (!diam) setLoading(true);
    setError("");
    authFetch(`${BASE}/admin/reports/subscriptions`)
      .then(r => {
        if (!r.ok) throw new Error("Gagal mengambil data laporan");
        return r.json();
      })
      .then(data => {
        setInvoices(Array.isArray(data) ? data : []);
        setLoading(false)
      })
      .catch(err => {
        console.error(err);
        setError("Gagal menghubungi server untuk memuat laporan");
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchReports();
  }, []);

  if (loading) {
    return <div className="page"><div className="spinner" style={{ margin: "100px auto" }}></div></div>;
  }

  // Calculate metrics
  // MANUAL = perpanjangan oleh super admin; uangnya diterima di luar Xendit.
  const paidInvoices = invoices.filter(i => i.status === "PAID" || i.status === "MANUAL");
  const pendingInvoices = invoices.filter(i => i.status === "PENDING");
  const totalRevenue = paidInvoices.reduce((sum, i) => sum + i.amount, 0);

  // Filter invoices based on search & status filter
  const filteredInvoices = invoices.filter(i => {
    const matchesSearch = 
      (i.partner_name && i.partner_name.toLowerCase().includes(searchTerm.toLowerCase())) ||
      (i.phone_number && i.phone_number.includes(searchTerm)) ||
      (i.id && i.id.toLowerCase().includes(searchTerm.toLowerCase()));
    
    const matchesStatus = 
      statusFilter === "ALL" || 
      i.status === statusFilter;

    return matchesSearch && matchesStatus;
  });

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1>Langganan bohRental</h1>
          <p>Masa langganan tiap mitra rental, perpanjangan manual, dan riwayat pembayaran (Rp 100.000 / bulan)</p>
        </div>
        <button 
          onClick={() => fetchReports()}
          className="btn btn-sm" 
          style={{ 
            display: "flex", 
            alignItems: "center", 
            gap: 6, 
            background: "var(--bg-input)", 
            color: "var(--text-primary)", 
            border: "1px solid var(--border)",
            borderRadius: 8,
            cursor: "pointer",
            padding: "8px 16px"
          }}
        >
          <RefreshCw size={14} /> Refresh Data
        </button>
      </div>

      <Alert type="error" style={{ marginBottom: 24 }}>{error}</Alert>

      <LanggananMitra onUbah={() => fetchReports(true)} />

      {/* Metrics Grid */}
      <div className="stats-grid" style={{ marginBottom: 32 }}>
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(16, 185, 129, 0.1)", color: "#10B981" }}>
            <DollarSign size={24} />
          </div>
          <div>
            <div className="stat-label">Total Omset (Lunas)</div>
            <div className="stat-value" style={{ color: "#10B981" }}>
              Rp {totalRevenue.toLocaleString("id-ID")}
            </div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(59, 130, 246, 0.1)", color: "#3B82F6" }}>
            <CheckCircle2 size={24} />
          </div>
          <div>
            <div className="stat-label">Transaksi Lunas</div>
            <div className="stat-value">{paidInvoices.length} Pembayaran</div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(245, 158, 11, 0.1)", color: "#F59E0B" }}>
            <AlertCircle size={24} />
          </div>
          <div>
            <div className="stat-label">Transaksi Pending</div>
            <div className="stat-value">{pendingInvoices.length} Invoice</div>
          </div>
        </div>
      </div>

      {/* Filters & Table */}
      <div className="table-wrap">
        <div className="table-header" style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 16 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, background: "var(--bg-input)", padding: "8px 16px", borderRadius: 10, border: "1px solid var(--border)", width: "100%", maxWidth: 320 }}>
            <Search size={18} style={{ color: "var(--text-muted)" }} />
            <input 
              type="text" 
              placeholder="Cari Mitra, No HP, atau ID..." 
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              style={{ background: "none", border: "none", color: "var(--text-primary)", outline: "none", width: "100%", fontSize: 14 }}
            />
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: "var(--text-secondary)" }}>
              <Filter size={14} /> Filter Status:
            </div>
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              style={{
                background: "var(--bg-input)",
                color: "var(--text-primary)",
                border: "1px solid var(--border)",
                borderRadius: 8,
                padding: "8px 16px",
                fontSize: 13,
                outline: "none",
                cursor: "pointer"
              }}
            >
              <option value="ALL">Semua Transaksi</option>
              <option value="PAID">Lunas</option>
              <option value="MANUAL">Manual (super admin)</option>
              <option value="PENDING">Pending</option>
              <option value="EXPIRED">Expired</option>
            </select>
          </div>
        </div>

        <table>
          <thead>
            <tr>
              <th>ID Invoice</th>
              <th>Nama Mitra</th>
              <th>Nomor HP</th>
              <th>Jumlah Bayar</th>
              <th>Tanggal Transaksi</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {filteredInvoices.length === 0 ? (
              <tr>
                <td colSpan="6" style={{ textAlign: "center", color: "var(--text-muted)", padding: 40 }}>
                  Tidak menemukan data transaksi pembayaran langganan.
                </td>
              </tr>
            ) : (
              filteredInvoices.map(inv => (
                <tr key={inv.id}>
                  <td data-label="ID Invoice"><strong style={{ fontFamily: "monospace", fontSize: 13 }}>{inv.id}</strong></td>
                  <td data-label="Nama Mitra"><strong>{inv.partner_name || "Mitra Rental"}</strong></td>
                  <td data-label="Nomor HP">{inv.phone_number}</td>
                  <td data-label="Jumlah Bayar"><strong>Rp {inv.amount.toLocaleString("id-ID")}</strong></td>
                  <td data-label="Tanggal">
                    {new Date(inv.created_at).toLocaleDateString("id-ID", {
                      year: "numeric",
                      month: "long",
                      day: "numeric",
                      hour: "2-digit",
                      minute: "2-digit"
                    })}
                  </td>
                  <td data-label="Status">
                    <span className={`badge ${
                      inv.status === "PAID" ? "badge-success" :
                      inv.status === "MANUAL" ? "badge-info" :
                      inv.status === "PENDING" ? "badge-warning" : "badge-danger"
                    }`}>
                      {inv.status === "PAID" ? "LUNAS" : inv.status}
                    </span>
                    {inv.catatan && <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 4 }}>{inv.catatan}</div>}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
