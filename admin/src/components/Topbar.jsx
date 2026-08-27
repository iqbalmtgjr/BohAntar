import { ShieldCheck } from "lucide-react";
import ThemeToggle from "./ThemeToggle";
import PortalNotifications from "./PortalNotifications";

/* Topbar Super Admin. Bentuknya disamakan dengan PortalTopbar milik mitra:
   judul di kiri, lonceng + tema + identitas di kanan. Di bawah 1024px topbar
   ini disembunyikan (lihat portal-mobile.css) karena brand bar sidebar sudah
   berperan sebagai app bar. */
export default function Topbar({ title }) {
  return (
    <header className="topbar">
      <span className="topbar-title">{title}</span>

      <div className="topbar-right">
        <PortalNotifications portalType="admin" />
        <ThemeToggle className="theme-toggle-btn" />

        <div style={{ textAlign: "right", lineHeight: 1.3 }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: "var(--text-primary)" }}>Super Admin</div>
          <div style={{ fontSize: 11, color: "var(--text-muted)" }}>bohAntar Control</div>
        </div>
        <div className="avatar" style={{ background: "linear-gradient(135deg, var(--primary-light), var(--primary-dark))", color: "#fff" }}>
          <ShieldCheck size={16} />
        </div>
      </div>
    </header>
  );
}
