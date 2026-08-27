import { useState, useEffect } from "react";
import { Car, Calendar, DollarSign, Clock, Wallet, Eye, EyeOff, TrendingUp, ConciergeBell, CalendarDays, BarChart3, CreditCard, ShoppingBag } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { buildRows, bucketOf } from "./schedule";

/* Ilustrasi dompet: SVG murni supaya tetap tajam di layar HD/retina */
function WalletArt() {
  return (
    <svg
      viewBox="0 0 128 128"
      width="106"
      height="106"
      aria-hidden="true"
      style={{
        position: "absolute",
        right: -12,
        bottom: -18,
        zIndex: 1,
        transform: "rotate(-8deg)",
        filter: "drop-shadow(0 12px 16px rgba(8, 30, 84, 0.45))"
      }}
    >
      <defs>
        <linearGradient id="bohWalletBody" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#F8FBFF" />
          <stop offset="55%" stopColor="#CFE0FD" />
          <stop offset="100%" stopColor="#8FB4F6" />
        </linearGradient>
        <linearGradient id="bohWalletFront" x1="0" y1="0" x2="0.3" y2="1">
          <stop offset="0%" stopColor="#FFFFFF" />
          <stop offset="100%" stopColor="#C3D8FC" />
        </linearGradient>
        <linearGradient id="bohWalletCard" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#FFFFFF" />
          <stop offset="100%" stopColor="#DBEAFE" />
        </linearGradient>
        <linearGradient id="bohWalletClasp" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#3B82F6" />
          <stop offset="100%" stopColor="#1D4ED8" />
        </linearGradient>
      </defs>

      {/* kartu yang menyembul dari dalam dompet */}
      <g transform="rotate(-7 65 37)">
        <rect x="34" y="18" width="62" height="34" rx="7" fill="url(#bohWalletCard)" />
        <rect x="42" y="30" width="30" height="4" rx="2" fill="#93C5FD" />
        <rect x="42" y="38" width="18" height="4" rx="2" fill="#BFDBFE" />
      </g>

      {/* badan dompet */}
      <rect x="16" y="40" width="96" height="64" rx="18" fill="url(#bohWalletBody)" />
      {/* panel depan */}
      <path d="M16 66 h96 v20 a18 18 0 0 1 -18 18 H34 a18 18 0 0 1 -18 -18 z" fill="url(#bohWalletFront)" />
      <rect x="16" y="64" width="96" height="2.5" fill="#FFFFFF" opacity="0.8" />
      {/* jepitan magnet */}
      <rect x="80" y="72" width="28" height="18" rx="9" fill="url(#bohWalletClasp)" />
      <circle cx="94" cy="81" r="4.2" fill="#FFFFFF" opacity="0.9" />
    </svg>
  );
}

export default function RentalDashboard({ ownerPhone }) {
  const [cars, setCars] = useState([]);
  const [bookings, setBookings] = useState([]);
  const [schedules, setSchedules] = useState([]);
  const [loading, setLoading] = useState(true);
  const [hideAmount, setHideAmount] = useState(false);

  useEffect(() => {
    Promise.all([
      authFetch(`${BASE}/rental/cars?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/bookings?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/schedules`).then(r => r.json())
    ])
      .then(([carsData, bookingsData, schedulesData]) => {
        setCars(Array.isArray(carsData) ? carsData : []);
        setBookings(Array.isArray(bookingsData) ? bookingsData : []);
        setSchedules(Array.isArray(schedulesData) ? schedulesData : []);
        setLoading(false);
      })
      .catch(err => {
        console.error("Error fetching dashboard data:", err);
        setLoading(false);
      });
  }, [ownerPhone]);

  if (loading) {
    return <div className="page"><div className="spinner" style={{ margin: "100px auto" }}></div></div>;
  }

  // Angka dashboard menghitung pesanan aplikasi DAN sewa manual dari kalender;
  // perawatan bukan transaksi jadi tidak ikut dihitung.
  const transactions = buildRows(bookings, schedules, cars).filter(row => row.source !== "maintenance");
  const activeBookings = transactions.filter(row => bucketOf(row.status) === "berjalan");
  const pendingBookings = transactions.filter(row => bucketOf(row.status) === "menunggu");
  const completedBookings = transactions.filter(row => bucketOf(row.status) === "selesai");
  const totalEarnings = completedBookings.reduce((sum, row) => sum + (row.total || 0), 0);

  return (
    <div className="page">
      <div className="page-header dash-header">
        <h1>Dashboard bohRental</h1>
        <p>Kelola performa persewaan kendaraan Anda di {ownerPhone}</p>
      </div>

      {/* ===== MOBILE: kartu dompet pendapatan + strip statistik ===== */}
      <div className="portal-mobile-only">
        <div style={{
          position: "relative",
          overflow: "hidden",
          borderRadius: 24,
          padding: "20px 20px 24px",
          color: "#fff",
          background: "linear-gradient(135deg, #3B82F6 0%, #2563EB 45%, #1D4ED8 100%)",
          boxShadow: "0 20px 34px -18px rgba(29, 78, 216, 0.9), 0 2px 8px -2px rgba(15, 23, 42, 0.18)"
        }}>
          {/* cahaya dekoratif */}
          <div style={{
            position: "absolute", top: -80, right: -60, width: 200, height: 200, borderRadius: "50%",
            background: "radial-gradient(circle at 30% 30%, rgba(255,255,255,0.30), rgba(255,255,255,0) 70%)"
          }} />
          <div style={{
            position: "absolute", bottom: -100, left: -50, width: 210, height: 210, borderRadius: "50%",
            background: "radial-gradient(circle, rgba(147,197,253,0.38), rgba(147,197,253,0) 70%)"
          }} />

          <WalletArt />

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
                Pendapatan Selesai
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

            {/* sisakan ruang kanan untuk ilustrasi dompet */}
            <div style={{ marginTop: 16, display: "flex", alignItems: "baseline", gap: 6, maxWidth: "calc(100% - 84px)" }}>
              <span style={{ fontSize: 15, fontWeight: 700, opacity: 0.9 }}>Rp</span>
              <span style={{ fontSize: "clamp(22px, 7vw, 32px)", fontWeight: 800, letterSpacing: -0.8, lineHeight: 1.1, whiteSpace: "nowrap" }}>
                {hideAmount ? "••••••" : totalEarnings.toLocaleString("id-ID")}
              </span>
            </div>

            <div style={{ marginTop: 18, display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", maxWidth: "calc(100% - 84px)" }}>
              <span style={{
                display: "inline-flex", alignItems: "center", gap: 5,
                fontSize: 11, fontWeight: 700, padding: "5px 10px", borderRadius: 999,
                background: "rgba(255,255,255,0.16)", border: "1px solid rgba(255,255,255,0.24)"
              }}>
                <TrendingUp size={13} /> {completedBookings.length} sewa selesai
              </span>
              <span style={{ fontSize: 11, color: "rgba(255,255,255,0.75)" }}>Akumulasi seluruh transaksi</span>
            </div>
          </div>
        </div>

        {/* strip statistik yang menimpa kartu dompet */}
        <div style={{
          position: "relative", zIndex: 3, margin: "-20px 10px 22px",
          display: "grid", gridTemplateColumns: "repeat(3, 1fr)",
          background: "#fff", border: "1px solid var(--border)", borderRadius: 18,
          boxShadow: "0 12px 26px -16px rgba(15, 23, 42, 0.45)", overflow: "hidden"
        }}>
          {[
            { icon: Car, label: "Armada", value: cars.length, tint: "rgba(37, 99, 235, 0.10)", color: "#2563EB" },
            { icon: Calendar, label: "Sewa Aktif", value: activeBookings.length, tint: "rgba(2, 132, 199, 0.12)", color: "#0284C7" },
            { icon: Clock, label: "Pending", value: pendingBookings.length, tint: "rgba(245, 158, 11, 0.14)", color: "#D97706" }
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

        {/* Menu cepat ala e-wallet: tab bar bawah cuma muat 5 slot,
            sisanya (Armada, Jasa, Langganan) hanya bisa dijangkau dari sini di HP. */}
        <div className="card" style={{ marginBottom: 22, padding: "18px 14px 14px", borderRadius: 20 }}>
          <div style={{ fontSize: 13.5, fontWeight: 800, padding: "0 4px" }}>Semua Menu</div>
          <div style={{ fontSize: 11, color: "var(--text-muted)", margin: "2px 4px 16px" }}>
            Akses cepat seluruh fitur mitra
          </div>
          {/* Akun sengaja tidak ada di sini: sudah punya tab sendiri di bar bawah,
              dan tanpa dia grid-nya pas 3 atas + 3 bawah. */}
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "14px 6px" }}>
            {[
              { to: "#/orders", icon: ShoppingBag, label: "Pesanan", badge: pendingBookings.length },
              { to: "#/cars", icon: Car, label: "Armada" },
              { to: "#/services", icon: ConciergeBell, label: "Jasa & Denda" },
              { to: "#/calendar", icon: CalendarDays, label: "Kalender" },
              { to: "#/reports", icon: BarChart3, label: "Laporan" },
              { to: "#/subscription", icon: CreditCard, label: "Langganan" }
            ].map(m => (
              <a
                key={m.to}
                href={m.to}
                className="quick-menu-item"
                style={{
                  display: "flex", flexDirection: "column", alignItems: "center", gap: 8,
                  textDecoration: "none", color: "var(--text-primary)"
                }}
              >
                <div style={{
                  position: "relative",
                  width: 54, height: 54, borderRadius: 18,
                  display: "flex", alignItems: "center", justifyContent: "center",
                  color: "#fff",
                  background: "linear-gradient(140deg, #60A5FA 0%, #3B82F6 45%, #1D4ED8 100%)",
                  boxShadow: "0 10px 18px -10px rgba(37, 99, 235, 0.95), inset 0 1px 0 rgba(255,255,255,0.35)"
                }}>
                  <m.icon size={24} strokeWidth={2.1} />
                  {/* Pesanan pending itu satu-satunya angka yang menuntut tindakan hari itu */}
                  {m.badge > 0 && (
                    <span style={{
                      position: "absolute", top: -5, right: -5, minWidth: 20, height: 20, padding: "0 5px",
                      borderRadius: 999, background: "#EF4444", color: "#fff",
                      fontSize: 11, fontWeight: 800, lineHeight: "20px", textAlign: "center",
                      border: "2px solid var(--bg-card, #fff)"
                    }}>
                      {m.badge > 9 ? "9+" : m.badge}
                    </span>
                  )}
                </div>
                <span style={{ fontSize: 11.5, fontWeight: 700, textAlign: "center", lineHeight: 1.25 }}>
                  {m.label}
                </span>
              </a>
            ))}
          </div>
        </div>
      </div>

      <div className="stats-grid portal-desktop-only">
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(37, 99, 235, 0.08)", color: "#2563EB" }}>
            <Car size={24} />
          </div>
          <div>
            <div className="stat-label">Total Armada</div>
            <div className="stat-value">{cars.length} Kendaraan</div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(59, 130, 246, 0.1)", color: "#3B82F6" }}>
            <Calendar size={24} />
          </div>
          <div>
            <div className="stat-label">Sewa Aktif</div>
            <div className="stat-value">{activeBookings.length} Aktif</div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(245, 158, 11, 0.1)", color: "#F59E0B" }}>
            <Clock size={24} />
          </div>
          <div>
            <div className="stat-label">Menunggu Persetujuan</div>
            <div className="stat-value">{pendingBookings.length} Pending</div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(29, 78, 216, 0.08)", color: "#1D4ED8" }}>
            <DollarSign size={24} />
          </div>
          <div>
            <div className="stat-label">Pendapatan Selesai</div>
            <div className="stat-value">Rp {totalEarnings.toLocaleString("id-ID")}</div>
          </div>
        </div>
      </div>

      <div className="table-wrap">
        {/* Aksi pesanan dipusatkan di halaman Pesanan Masuk: penolakan wajib
            disertai catatan, dan formulir catatannya ada di sana. */}
        <div className="table-header">
          <h3>Pengajuan Sewa Terbaru</h3>
        </div>
        <table>
          <thead>
            <tr>
              <th>ID Booking</th>
              <th>Kendaraan</th>
              <th>Penyewa</th>
              <th>Mulai Sewa</th>
              <th>Selesai Sewa</th>
              <th>Total Biaya</th>
              <th>Status</th>
              <th>Aksi</th>
            </tr>
          </thead>
          <tbody>
            {bookings.length === 0 ? (
              <tr>
                <td colSpan="8" style={{ textAlign: "center", color: "var(--text-muted)", padding: 40 }}>
                  Belum ada pengajuan sewa dari aplikasi. Sewa manual dicatat lewat menu Kalender.
                </td>
              </tr>
            ) : (
              bookings.map(b => (
                <tr key={b.id}>
                  <td data-label="ID Booking"><strong style={{ fontFamily: "monospace" }}>{b.id}</strong></td>
                  <td data-label="Kendaraan">{cars.find(c => c.id === b.car_id)?.brand || "Kendaraan"} {cars.find(c => c.id === b.car_id)?.model || ""}</td>
                  <td data-label="Penyewa">{b.customer_phone}</td>
                  <td data-label="Mulai Sewa">{b.start_time}</td>
                  <td data-label="Selesai Sewa">{b.end_time}</td>
                  <td data-label="Total Biaya"><strong>Rp {b.total_price.toLocaleString("id-ID")}</strong></td>
                  <td data-label="Status">
                    <span className={`badge ${
                      b.status === "pending" ? "badge-warning" :
                      b.status === "confirmed" ? "badge-info" :
                      b.status === "ongoing" ? "badge-primary" :
                      b.status === "completed" ? "badge-success" : "badge-danger"
                    }`}>
                      {b.status.toUpperCase()}
                    </span>
                  </td>
                  <td data-label="Aksi">
                    {["pending", "confirmed", "ongoing"].includes(b.status) ? (
                      <a href="#/orders" className="btn btn-ghost btn-sm">Tindak Lanjuti</a>
                    ) : (
                      <span style={{ color: "var(--text-muted)", fontSize: 12 }}>Tidak ada aksi</span>
                    )}
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
