import { useState, useEffect } from "react";
import { Link, useLocation } from "react-router-dom";
import {
  LayoutDashboard, Users, ShoppingBag, BarChart3, UserPlus, FileText,
  LogOut, CheckCircle, CreditCard, LayoutGrid, Percent
} from "lucide-react";
import logoB from "../assets/logo_b_icon.png";
import ThemeToggle from "./ThemeToggle";
import PortalNotifications from "./PortalNotifications";

/* Sidebar Super Admin. Bentuknya mengikuti SidebarRentalPartner: sidebar penuh
   di desktop, app bar + tab bar bawah di mobile.

   desktopOnly: tab bar mobile dijaga tetap 5 slot (2 | FAB | 2), sedangkan menu
   admin ada sembilan. Menu bertanda ini hanya muncul di sidebar desktop; di HP
   dijangkau lewat sheet "Lainnya" dan grid menu di Dashboard. */
const navItems = [
  { section: "Overview" },
  { to: "/", icon: LayoutDashboard, label: "Dashboard", short: "Beranda" },
  { to: "/analytics", icon: BarChart3, label: "Analitik", short: "Analitik", desktopOnly: true },
  { section: "Manajemen" },
  { to: "/users", icon: Users, label: "Pengguna", short: "Pengguna" },
  { to: "/orders", icon: ShoppingBag, label: "Pesanan", short: "Pesanan", center: true },
  { to: "/tarif", icon: Percent, label: "Tarif & Bagi Hasil", short: "Tarif", desktopOnly: true },
  { section: "Driver" },
  { to: "/driver-register", icon: UserPlus, label: "Daftar Driver", short: "Daftar", desktopOnly: true },
  { to: "/applications", icon: FileText, label: "Pengajuan Driver", short: "Driver", desktopOnly: true },
  { section: "Kemitraan" },
  { to: "/partner-applications", icon: FileText, label: "Pengajuan Mitra", short: "Mitra" },
  { to: "/approved-partners", icon: CheckCircle, label: "Mitra Disetujui", short: "Disetujui", desktopOnly: true },
  { section: "Pelaporan Pembayaran" },
  { to: "/payment-reports/rental", icon: CreditCard, label: "bohRental", short: "Bayar", desktopOnly: true },
];

/* Menu yang tidak kebagian slot di tab bar. Diekspor supaya Dashboard memakai
   daftar yang sama — satu sumber, tidak ada versi yang ketinggalan. */
export const OVERFLOW_MENU = navItems.filter(i => i.desktopOnly);

/* Seluruh menu selain Dashboard, untuk grid "Semua Menu" di Beranda mobile. */
export const ALL_MENU = navItems.filter(i => i.to && i.to !== "/");

export default function Sidebar({ onLogout }) {
  const { pathname } = useLocation();
  const [sheetOpen, setSheetOpen] = useState(false);

  useEffect(() => {
    if (!sheetOpen) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKey = (e) => { if (e.key === "Escape") setSheetOpen(false); };
    window.addEventListener("keydown", onKey);
    return () => {
      document.body.style.overflow = prev;
      window.removeEventListener("keydown", onKey);
    };
  }, [sheetOpen]);

  return (
    <aside className="sidebar">
      <div className="sidebar-brand" style={{ justifyContent: "space-between", width: "100%" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <img
            src={logoB}
            alt="bohAntar"
            className="logo-icon"
            style={{ background: "none", objectFit: "contain" }}
          />
          <div>
            <div className="brand-name">bohAntar</div>
            <div className="brand-sub">Super Admin</div>
          </div>
        </div>

        {/* Aksi ringkas untuk mobile; sidebar-footer disembunyikan di breakpoint itu
            dan .topbar admin ikut disembunyikan, jadi lonceng & tema tinggal di sini. */}
        <div style={{ display: "flex", alignItems: "center", gap: 2 }}>
          <PortalNotifications portalType="admin" className="brandbar-btn" />
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

        {/* Slot ke-5 tab bar: pintu ke menu yang tidak muat. */}
        <button
          type="button"
          onClick={() => setSheetOpen(true)}
          className={`nav-item nav-mobile-only${OVERFLOW_MENU.some(m => m.to === pathname) ? " active" : ""}`}
          style={{ background: "none", border: "none" }}
        >
          <LayoutGrid size={19} />
          <span className="nav-label-short">Lainnya</span>
        </button>
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

      {sheetOpen && (
        <>
          <div className="portal-sheet-backdrop" onClick={() => setSheetOpen(false)} />
          <div className="portal-sheet" role="dialog" aria-modal="true" aria-label="Menu lainnya">
            <div className="portal-sheet-grip" />
            <div className="portal-sheet-title">Menu Lainnya</div>
            <div className="portal-sheet-sub">Fitur yang tidak muat di bar bawah</div>

            <div className="menu-grid">
              {OVERFLOW_MENU.map(m => (
                <Link key={m.to} to={m.to} className="menu-grid-item" onClick={() => setSheetOpen(false)}>
                  <span className="menu-grid-ico"><m.icon size={24} strokeWidth={2.1} /></span>
                  <span className="menu-grid-label">{m.label}</span>
                </Link>
              ))}
            </div>

            <button className="portal-sheet-logout" onClick={onLogout}>
              <LogOut size={16} /> Keluar dari panel
            </button>
          </div>
        </>
      )}
    </aside>
  );
}
