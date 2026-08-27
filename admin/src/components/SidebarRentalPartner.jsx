import { Link, useLocation } from "react-router-dom";
import { LayoutDashboard, Car, Calendar, LogOut, BarChart3, UserCog, ConciergeBell, ShoppingBag } from "lucide-react";
import logoB from "../assets/logo_b_icon.png";
import ThemeToggle from "./ThemeToggle";
import PortalNotifications from "./PortalNotifications";

const navItems = [
  { section: "Overview" },
  { to: "/", icon: LayoutDashboard, label: "Dashboard", short: "Beranda" },
  { section: "Pesanan" },
  { to: "/orders", icon: ShoppingBag, label: "Pesanan Masuk", short: "Pesanan" },
  { section: "Penjadwalan" },
  { to: "/calendar", icon: Calendar, label: "Kalender Rental", short: "Kalender", center: true },
  { section: "Armada Sewa" },
  // desktopOnly: tab bar mobile dijaga tetap 5 item (2 | tombol tengah | 2), jadi
  // urutan di atas menentukan posisi tab. Menu bertanda ini dijangkau lewat grid
  // "Semua Menu" di Dashboard saat dibuka dari HP.
  { to: "/cars", icon: Car, label: "Kelola Armada", short: "Armada", desktopOnly: true },
  { to: "/services", icon: ConciergeBell, label: "Jasa & Denda", short: "Jasa", desktopOnly: true },
  { section: "Laporan" },
  { to: "/reports", icon: BarChart3, label: "Laporan Lengkap", short: "Laporan" },
  // Langganan pindah ke halaman Akun: nav bawah mobile hanya simetris pada jumlah
  // ganjil (2 | tombol tengah | 2), dan billing bukan menu harian.
  { section: "Akun" },
  { to: "/account", icon: UserCog, label: "Akun Saya", short: "Akun" },
];

export default function SidebarRentalPartner({ onLogout }) {
  const { pathname } = useLocation();

  return (
    <aside className="sidebar">
      <div className="sidebar-brand" style={{ justifyContent: "space-between", width: "100%" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "12px" }}>
          <img
            src={logoB}
            alt="bohRental"
            className="logo-icon"
            style={{ background: "none", objectFit: "contain" }}
          />
          <div>
            <div className="brand-name">bohRental</div>
            <div className="brand-sub">Mitra Panel</div>
          </div>
        </div>

        {/* Aksi ringkas untuk mobile; sidebar-footer disembunyikan di breakpoint itu.
            Lonceng ikut di sini karena .portal-topbar disembunyikan di bawah 1024px. */}
        <div style={{ display: "flex", alignItems: "center", gap: 2 }}>
          <PortalNotifications portalType="rental" className="brandbar-btn" />
          <ThemeToggle className="brandbar-btn" size={19} />
          <button onClick={onLogout} className="brandbar-btn danger" aria-label="Keluar">
            <LogOut size={19} />
          </button>
        </div>
      </div>

      <nav className="sidebar-nav">
        {navItems.map((item, i) =>
          item.section ? (
            <div key={i} className="nav-section-label">{item.section}</div>
          ) : (
            <Link
              key={item.to}
              to={item.to}
              className={`nav-item${pathname === item.to ? " active" : ""}${item.center ? " nav-center" : ""}${item.desktopOnly ? " nav-desktop-only" : ""}`}
            >
              <item.icon size={19} />
              <span className="nav-label-full">{item.label}</span>
              <span className="nav-label-short">{item.short}</span>
            </Link>
          )
        )}
      </nav>

      <div className="sidebar-footer">
        <button
          onClick={onLogout}
          className="nav-item logout-item"
          style={{ width: "100%", border: "none", cursor: "pointer", background: "none" }}
        >
          <LogOut size={17} />Keluar
        </button>
      </div>
    </aside>
  );
}
