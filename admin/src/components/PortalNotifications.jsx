import { useState, useEffect } from "react";
import { Bell } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { api } from "../api";

/* Lonceng notifikasi panel web. Dipakai Super Admin dan portal mitra rental;
   bentuk dropdown-nya sama, sumber datanya yang berbeda.

   ponytail: tidak ada status sudah-dibaca. Notif di sini dihitung ulang dari
   kondisi yang masih berlaku (pengajuan masih pending, langganan hampir habis,
   booking masih pending), jadi hilang sendiri begitu ditindaklanjuti. Tambahkan
   tabel read-state kalau nanti ada notif yang bersifat kejadian sekali lewat. */

const DAY = 86400000;

// bohFood belum punya sumber notif: backend belum punya pipeline order resto.
const SUPPORTED = ["admin", "rental"];

async function loadAdmin(next) {
  try {
    const res = await api.getApplications("pending");
    const n = res.applications?.length || 0;
    if (n > 0) next.push({ id: "driver", text: `${n} pengajuan driver menunggu`, sub: "Verifikasi berkas calon driver", to: "/applications", tone: "warning", count: n });
  } catch { /* daftar pengajuan driver gagal dimuat: notif lain tetap jalan */ }

  try {
    const res = await api.getPartnerApplications({ status: "pending" });
    const n = res.applications?.length || 0;
    if (n > 0) next.push({ id: "partner", text: `${n} pengajuan mitra menunggu`, sub: "Tinjau calon mitra Food & Rental", to: "/partner-applications", tone: "warning", count: n });
  } catch { /* daftar pengajuan mitra gagal dimuat */ }
}

async function loadRental(next) {
  try {
    const sub = await api.getSubscriptionStatus();
    const sisa = Math.ceil((new Date(sub.valid_until) - Date.now()) / DAY);
    if (sub.status === "EXPIRED") {
      next.push({ id: "sub", text: "Langganan sudah berakhir", sub: "Perpanjang untuk membuka portal", to: "/subscription", tone: "danger" });
    } else if (sisa <= 7) {
      next.push({ id: "sub", text: `Langganan berakhir ${sisa <= 0 ? "hari ini" : `dalam ${sisa} hari`}`, sub: "Perpanjang sebelum portal terkunci", to: "/subscription", tone: "warning" });
    }
  } catch { /* status langganan gagal dimuat: notif lain tetap jalan */ }

  try {
    const bookings = await api.getRentalBookings();
    const pending = Array.isArray(bookings) ? bookings.filter(b => b.status === "pending").length : 0;
    if (pending > 0) {
      next.push({ id: "booking", text: `${pending} booking baru dari aplikasi`, sub: "Cek jadwal dan konfirmasi penyewa", to: "/calendar", tone: "info", count: pending });
    }
  } catch { /* daftar booking gagal dimuat */ }
}

export default function PortalNotifications({ portalType, className = "theme-toggle-btn" }) {
  const [items, setItems] = useState([]);
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    if (!SUPPORTED.includes(portalType)) {
      setItems([]);
      return;
    }

    let alive = true;
    const load = async () => {
      const next = [];
      if (portalType === "admin") await loadAdmin(next);
      else await loadRental(next);
      if (alive) setItems(next);
    };

    load();
    const t = setInterval(load, 60000);
    return () => { alive = false; clearInterval(t); };
  }, [portalType]);

  if (!SUPPORTED.includes(portalType)) return null;

  return (
    <div style={{ position: "relative", display: "flex", alignItems: "center" }}>
      <button
        onClick={() => setOpen(!open)}
        className={className}
        aria-label="Notifikasi"
        style={{ background: "none", border: "none", cursor: "pointer", color: "var(--text-secondary)", padding: 8, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center" }}
      >
        <Bell size={18} />
        {items.length > 0 && (
          <span style={{
            position: "absolute", top: 2, right: 2,
            background: "var(--danger)", color: "#fff", borderRadius: "50%",
            fontSize: 9, fontWeight: 700, width: 14, height: 14, lineHeight: 1,
            display: "flex", alignItems: "center", justifyContent: "center"
          }}>
            {items.length}
          </span>
        )}
      </button>

      {open && (
        <div style={{
          position: "absolute", top: 38, right: 0, zIndex: 100, width: 260,
          background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 12,
          boxShadow: "0 10px 15px -3px rgba(0,0,0,0.2), 0 4px 6px -2px rgba(0,0,0,0.1)",
          padding: "8px 0"
        }}>
          <div style={{ padding: "8px 16px", fontSize: 11, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.5px", color: "var(--text-secondary)", borderBottom: "1px solid var(--border)" }}>
            Notifikasi
          </div>

          {items.length === 0 ? (
            <div style={{ padding: 16, fontSize: 12, color: "var(--text-muted)", textAlign: "center" }}>
              Tidak ada notifikasi
            </div>
          ) : items.map(item => (
            <button
              key={item.id}
              onClick={() => { setOpen(false); navigate(item.to); }}
              style={{ width: "100%", padding: "12px 16px", textAlign: "left", background: "none", border: "none", cursor: "pointer", display: "flex", alignItems: "center", gap: 10 }}
              onMouseEnter={e => e.currentTarget.style.backgroundColor = "var(--bg-hover)"}
              onMouseLeave={e => e.currentTarget.style.backgroundColor = "transparent"}
            >
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: "var(--text-primary)" }}>{item.text}</div>
                <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>{item.sub}</div>
              </div>
              <span className={`badge badge-${item.tone}`} style={{ margin: 0, fontSize: 10, padding: "2px 6px" }}>
                {item.count ?? "!"}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
