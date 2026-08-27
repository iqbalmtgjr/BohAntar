import { Link, useLocation } from "react-router-dom";
import { LayoutDashboard, Salad, LogOut, Utensils, UserCog } from "lucide-react";
import ThemeToggle from "./ThemeToggle";

const navItems = [
  { section: "Overview" },
  { to: "/", icon: LayoutDashboard, label: "Dashboard", short: "Beranda" },
  { section: "Toko & Menu" },
  { to: "/menu", icon: Salad, label: "Kelola Menu", short: "Menu" },
  { section: "Akun" },
  { to: "/account", icon: UserCog, label: "Akun Saya", short: "Akun" },
];

export default function SidebarFoodMerchant({ onLogout }) {
  const { pathname } = useLocation();

  return (
    <aside className="sidebar">
      <div className="sidebar-brand" style={{ justifyContent: "space-between", width: "100%" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "12px" }}>
          <div className="logo-icon" style={{ background: "linear-gradient(135deg, #F59E0B, #D97706)" }}>
            <Utensils size={20} />
          </div>
          <div>
            <div className="brand-name">bohFood</div>
            <div className="brand-sub">Merchant Panel</div>
          </div>
        </div>

        {/* Aksi ringkas untuk mobile; sidebar-footer disembunyikan di breakpoint itu */}
        <div style={{ display: "flex", alignItems: "center", gap: 2 }}>
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
              className={`nav-item${pathname === item.to ? " active" : ""}`}
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
