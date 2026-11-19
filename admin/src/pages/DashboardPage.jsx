import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Users, ShoppingBag, Bike, Clock, CheckCircle, XCircle, DollarSign, Wallet, Eye, EyeOff, UserCheck, Navigation } from "lucide-react";
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, PieChart, Pie, Cell, Legend } from "recharts";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { ALL_MENU } from "../components/Sidebar";

export default function DashboardPage() {
  const [analytics, setAnalytics] = useState(null);
  const [loading, setLoading] = useState(true);
  const [hideAmount, setHideAmount] = useState(false);

  useEffect(() => {
    api.getAnalytics().then(d => { if (d.status === "success") setAnalytics(d.analytics); setLoading(false); });
  }, []);

  if (loading) return (<><Topbar title="Dashboard" /><div className="loading-overlay"><div className="spinner"/><p>Memuat data...</p></div></>);

  const a = analytics || {};
  // Urut perjalanan pesanan; dipakai strip mobile, kartu desktop, dan pie.
  const statusData = [
    { name: "Pending", short: "Pending", value: a.pending_orders || 0, icon: Clock, color: "var(--warning)", bg: "var(--warning-glow)" },
    { name: "Diambil Driver", short: "Diambil", value: a.accepted_orders || 0, icon: UserCheck, color: "var(--info)", bg: "var(--info-glow)" },
    { name: "Dalam Perjalanan", short: "Di Jalan", value: a.picked_up_orders || 0, icon: Navigation, color: "var(--primary)", bg: "var(--primary-glow)" },
    { name: "Selesai", short: "Selesai", value: a.completed_orders || 0, icon: CheckCircle, color: "var(--success)", bg: "var(--success-glow)" },
    { name: "Dibatalkan", short: "Batal", value: a.cancelled_orders || 0, icon: XCircle, color: "var(--danger)", bg: "var(--danger-glow)" },
  ];
  const driverData = (a.driver_stats || []).slice(0, 6).map(d => ({
    name: d.driver_name?.split(" ")[0] || "?",
    pesanan: d.order_count || 0,
    pendapatan: Math.round((d.bagian_driver || 0) / 1000),
  }));

  const fmt = (n) => "Rp " + (n || 0).toLocaleString("id-ID");
  // Kartu statistik cuma selebar ~190px di layar 1440; nominal pendapatan penuh
  // selalu pecah baris di situ. Angka utuhnya tetap ada di tooltip.
  const fmtShort = (n) => {
    n = n || 0;
    if (n >= 1e9) return "Rp " + (n / 1e9).toFixed(1).replace(".", ",") + " M";
    if (n >= 1e6) return "Rp " + (n / 1e6).toFixed(1).replace(".", ",") + " jt";
    return fmt(n);
  };

  return (
    <>
      <Topbar title="Dashboard" />
      <div className="page">
        <div className="page-header dash-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: 16 }}>
          <div>
            <h1 style={{ fontWeight: 700 }}>Selamat Datang, Admin</h1>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 4 }}>
              <span className="system-status-dot" style={{ display: "inline-block", width: 8, height: 8, borderRadius: "50%", backgroundColor: "var(--success)", animation: "pulse 2s infinite" }} />
              <span style={{ color: "var(--text-secondary)", fontSize: 13 }}>Semua sistem operasional dan berjalan normal</span>
            </div>
          </div>
          <div style={{ color: "var(--text-muted)", fontSize: 12, fontWeight: 500 }}>
            Hari ini: {new Date().toLocaleDateString("id-ID", { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}
          </div>
        </div>

        {/* ===== MOBILE: kartu pendapatan + strip statistik + grid menu ===== */}
        <div className="portal-mobile-only">
          <div style={{
            position: "relative",
            overflow: "hidden",
            borderRadius: 24,
            padding: "20px 20px 24px",
            color: "#fff",
            background: "linear-gradient(135deg, #6366F1 0%, #4F46E5 45%, #4338CA 100%)",
            boxShadow: "0 20px 34px -18px rgba(67, 56, 202, 0.9), 0 2px 8px -2px rgba(15, 23, 42, 0.18)"
          }}>
            <div style={{
              position: "absolute", top: -80, right: -60, width: 200, height: 200, borderRadius: "50%",
              background: "radial-gradient(circle at 30% 30%, rgba(255,255,255,0.28), rgba(255,255,255,0) 70%)"
            }} />
            <div style={{
              position: "absolute", bottom: -100, left: -50, width: 210, height: 210, borderRadius: "50%",
              background: "radial-gradient(circle, rgba(165,180,252,0.38), rgba(165,180,252,0) 70%)"
            }} />

            <div style={{ position: "relative", zIndex: 2 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <div style={{
                  width: 34, height: 34, borderRadius: 11, flexShrink: 0,
                  display: "flex", alignItems: "center", justifyContent: "center",
                  background: "rgba(255,255,255,0.18)", border: "1px solid rgba(255,255,255,0.28)"
                }}>
                  <Wallet size={18} />
                </div>
                <div style={{
                  fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: "uppercase",
                  color: "rgba(255,255,255,0.88)"
                }}>
                  Pendapatan Kami (bersih)
                </div>
                <button
                  onClick={() => setHideAmount(v => !v)}
                  aria-label={hideAmount ? "Tampilkan nominal" : "Sembunyikan nominal"}
                  style={{
                    marginLeft: "auto", width: 32, height: 32, borderRadius: 10, cursor: "pointer",
                    display: "flex", alignItems: "center", justifyContent: "center",
                    background: "rgba(255,255,255,0.14)", border: "1px solid rgba(255,255,255,0.22)", color: "#fff"
                  }}
                >
                  {hideAmount ? <EyeOff size={16} /> : <Eye size={16} />}
                </button>
              </div>

              <div style={{ marginTop: 16, display: "flex", alignItems: "baseline", gap: 6 }}>
                <span style={{ fontSize: 15, fontWeight: 700, opacity: 0.9 }}>Rp</span>
                <span style={{ fontSize: "clamp(22px, 7vw, 32px)", fontWeight: 800, letterSpacing: -0.8, lineHeight: 1.1, whiteSpace: "nowrap" }}>
                  {hideAmount ? "••••••" : Math.round(a.pendapatan_kami || 0).toLocaleString("id-ID")}
                </span>
              </div>
              <div style={{ marginTop: 6, fontSize: 11.5, color: "rgba(255,255,255,0.8)" }}>
                dari ongkos kotor {hideAmount ? "••••••" : fmt(a.total_revenue)} yang dibayar penumpang
              </div>

              <div style={{ marginTop: 18, display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                <span style={{
                  display: "inline-flex", alignItems: "center", gap: 5,
                  fontSize: 11, fontWeight: 700, padding: "5px 10px", borderRadius: 999,
                  background: "rgba(255,255,255,0.16)", border: "1px solid rgba(255,255,255,0.24)"
                }}>
                  <CheckCircle size={13} /> {a.completed_orders || 0} pesanan selesai
                </span>
                <Link to="/komisi" style={{ fontSize: 11, fontWeight: 700, color: "#fff" }}>Lihat rincian →</Link>
              </div>
            </div>
          </div>

          {/* strip statistik yang menimpa kartu pendapatan */}
          <div style={{
            position: "relative", zIndex: 3, margin: "-20px 10px 22px",
            display: "grid", gridTemplateColumns: "repeat(3, 1fr)",
            background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 18,
            boxShadow: "0 12px 26px -16px rgba(15, 23, 42, 0.45)", overflow: "hidden"
          }}>
            {[
              { icon: Users, label: "Pengguna", value: a.total_users || 0, tint: "rgba(79, 70, 229, 0.10)", color: "#4F46E5" },
              { icon: ShoppingBag, label: "Pesanan", value: a.total_orders || 0, tint: "rgba(2, 132, 199, 0.12)", color: "#0284C7" },
              { icon: Bike, label: "Driver", value: a.total_drivers || 0, tint: "rgba(245, 158, 11, 0.14)", color: "#D97706" }
            ].map((s, i) => (
              <div key={s.label} style={{ padding: "15px 6px 13px", textAlign: "center", borderLeft: i ? "1px solid var(--border)" : "none" }}>
                <div style={{
                  width: 34, height: 34, margin: "0 auto 8px", borderRadius: 11,
                  background: s.tint, color: s.color,
                  display: "flex", alignItems: "center", justifyContent: "center"
                }}>
                  <s.icon size={17} />
                </div>
                <div style={{ fontSize: 19, fontWeight: 800, lineHeight: 1.1, color: "var(--text-primary)" }}>{s.value}</div>
                <div style={{
                  fontSize: 10, fontWeight: 700, letterSpacing: 0.4, textTransform: "uppercase",
                  color: "var(--text-muted)", marginTop: 3
                }}>
                  {s.label}
                </div>
              </div>
            ))}
          </div>

          {/* Status pesanan sekilas, menggantikan 8 kartu statistik versi desktop */}
          <div className="card" style={{ marginBottom: 22, padding: 14, borderRadius: 18 }}>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 4 }}>
              {statusData.map(s => (
                <div key={s.name} style={{ textAlign: "center", minWidth: 0 }}>
                  <div style={{ fontSize: 18, fontWeight: 800, color: s.color, lineHeight: 1.2 }}>{s.value}</div>
                  <div style={{ fontSize: 10.5, fontWeight: 600, color: "var(--text-muted)", marginTop: 2, whiteSpace: "nowrap" }}>{s.short}</div>
                </div>
              ))}
            </div>
          </div>

          {/* Menu cepat: tab bar bawah cuma muat 5 slot, sisanya dijangkau dari sini. */}
          <div className="card" style={{ marginBottom: 22, padding: "18px 14px 14px", borderRadius: 20 }}>
            <div style={{ fontSize: 13.5, fontWeight: 800, padding: "0 4px" }}>Semua Menu</div>
            <div style={{ fontSize: 11, color: "var(--text-muted)", margin: "2px 4px 16px" }}>
              Akses cepat seluruh fitur panel admin
            </div>
            <div className="menu-grid">
              {ALL_MENU.map(m => (
                <Link key={m.to} to={m.to} className="menu-grid-item">
                  <span className="menu-grid-ico">
                    <m.icon size={24} strokeWidth={2.1} />
                    {/* Pesanan pending itu satu-satunya angka yang menuntut tindakan hari ini */}
                    {m.to === "/orders" && a.pending_orders > 0 && (
                      <span className="menu-grid-badge">{a.pending_orders > 9 ? "9+" : a.pending_orders}</span>
                    )}
                  </span>
                  <span className="menu-grid-label">{m.label}</span>
                </Link>
              ))}
            </div>
          </div>
        </div>

        <div className="stats-grid portal-desktop-only">

          {[
            { label: "Total Pengguna", value: a.total_users || 0, icon: Users, color: "var(--primary)", bg: "var(--primary-glow)" },
            { label: "Total Pesanan", value: a.total_orders || 0, icon: ShoppingBag, color: "var(--success)", bg: "var(--success-glow)" },
            { label: "Total Driver", value: a.total_drivers || 0, icon: Bike, color: "var(--warning)", bg: "var(--warning-glow)" },
            { label: "Pendapatan Kami (bersih) →", value: fmtShort(a.pendapatan_kami), title: `Komisi + biaya jasa − diskon voucher + potongan QR mitra. Ongkos kotor: ${fmt(a.total_revenue)}`, icon: DollarSign, color: "var(--info)", bg: "var(--info-glow)", to: "/komisi" },
            { label: "Total Penumpang", value: a.total_riders || 0, icon: Users, color: "var(--info)", bg: "var(--info-glow)" },
            ...statusData.map(s => ({ ...s, label: "Pesanan " + s.name })),
          ].map((s, i) => {
            const Kartu = s.to ? Link : "div";
            return (
              <Kartu key={i} to={s.to} className="stat-card" style={{ textDecoration: "none", color: "inherit" }}>
                <div className="stat-icon" style={{ background: s.bg }}><s.icon size={22} style={{ color: s.color }} /></div>
                <div style={{ minWidth: 0 }}><div className="stat-value" style={{ color: s.color }} title={s.title}>{s.value}</div><div className="stat-label">{s.label}</div></div>
              </Kartu>
            );
          })}
        </div>

        <div className="grid-2" style={{ marginBottom: 24 }}>
          <div className="card">
            <div className="card-title">Performa Driver (Pesanan)</div>
            <ResponsiveContainer width="100%" height={220}>
              <BarChart data={driverData}>
                <XAxis dataKey="name" stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
                <YAxis stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
                <Tooltip contentStyle={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 8, color: "var(--text-primary)" }} />
                <Bar dataKey="pesanan" fill="var(--primary)" radius={[6,6,0,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
          <div className="card">
            <div className="card-title">Distribusi Status Pesanan</div>
            <ResponsiveContainer width="100%" height={220}>
              <PieChart>
                {/* Irisan nol dibuang: labelnya menumpuk di satu titik. Angka nol tetap ada di kartu. */}
                <Pie data={statusData.filter(s => s.value)} cx="50%" cy="50%" outerRadius={80} dataKey="value" label={({name,value})=>`${name}: ${value}`}>
                  {statusData.filter(s => s.value).map(s => <Cell key={s.name} fill={s.color} />)}
                </Pie>
                <Legend />
                <Tooltip contentStyle={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 8, color: "var(--text-primary)" }} />
              </PieChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div className="card">
          <div className="card-title">Bagian Driver — ongkos dikurangi komisi (Ribuan Rp)</div>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={driverData}>
              <XAxis dataKey="name" stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
              <YAxis stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
              <Tooltip contentStyle={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 8, color: "var(--text-primary)" }} formatter={(v) => ["Rp " + v + "K", "Pendapatan"]} />
              <Bar dataKey="pendapatan" fill="var(--success)" radius={[6,6,0,0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>
    </>
  );
}
