import { useLocation } from "react-router-dom";
import { User } from "lucide-react";
import ThemeToggle from "./ThemeToggle";
import PortalNotifications from "./PortalNotifications";

/* Topbar ringan untuk portal mitra (rental & food).
   Topbar.jsx tidak dipakai di sini karena komponen itu khusus Super Admin:
   ia memanggil endpoint pengajuan driver/mitra tiap 30 detik dan
   menavigasi ke rute yang tidak ada di portal mitra. */

const TITLES = {
  rental: {
    "/": "Dashboard bohRental",
    "/orders": "Pesanan Masuk",
    "/cars": "Kelola Armada",
    "/services": "Jasa & Denda",
    "/calendar": "Kalender Rental",
    "/reports": "Laporan Lengkap",
    "/subscription": "Langganan & Billing",
    "/account": "Akun Saya"
  },
  food: {
    "/": "Dashboard bohFood",
    "/menu": "Kelola Menu",
    "/account": "Akun Saya"
  }
};

export default function PortalTopbar({ portalType, userPhone }) {
  const { pathname } = useLocation();
  const title = TITLES[portalType]?.[pathname] || "Dashboard";
  const roleLabel = portalType === "food" ? "Mitra bohFood" : "Mitra bohRental";

  return (
    <header className="topbar portal-topbar">
      <span className="topbar-title">{title}</span>

      <div className="topbar-right">
        <PortalNotifications portalType={portalType} />
        <ThemeToggle className="theme-toggle-btn" />

        <div style={{ textAlign: "right", lineHeight: 1.3 }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: "var(--text-primary)" }}>{roleLabel}</div>
          <div style={{ fontSize: 11, color: "var(--text-muted)" }}>{userPhone || "-"}</div>
        </div>
        <div className="avatar" style={{ background: "linear-gradient(135deg, #3B82F6, #1D4ED8)", color: "#fff" }}>
          <User size={16} />
        </div>
      </div>
    </header>
  );
}
