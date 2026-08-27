import { useEffect, useState } from "react";
import { CheckCircle, XCircle, Clock, FileText, Store, KeyRound, Filter, Check, Eye } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { toast, confirmDialog } from "../components/Feedback";

const STATUS = {
  pending: { label: "Menunggu", badge: "badge-warning", icon: Clock },
  approved: { label: "Disetujui", badge: "badge-success", icon: CheckCircle },
  rejected: { label: "Ditolak", badge: "badge-danger", icon: XCircle },
};

const FILTER_ITEMS = [
  { value: "", label: "Semua", icon: null },
  { value: "pending", label: "Menunggu", icon: Clock },
  { value: "approved", label: "Disetujui", icon: CheckCircle },
  { value: "rejected", label: "Ditolak", icon: XCircle },
];

const TYPE_FILTER_ITEMS = [
  { value: "", label: "Semua Kemitraan", icon: null },
  { value: "food", label: "Mitra Resto Food", icon: Store },
  { value: "rental", label: "Mitra Rental Mobil", icon: KeyRound },
];

export default function PartnerApplicationsPage() {
  const [apps, setApps] = useState([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("");
  const [typeFilter, setTypeFilter] = useState("");
  const [actionLoading, setActionLoading] = useState(null);

  const load = (type = typeFilter, status = statusFilter) => {
    setLoading(true);
    api.getPartnerApplications({ type, status }).then((d) => {
      setApps(d.applications || []);
      setLoading(false);
    });
  };

  useEffect(() => {
    load();
  }, []);

  const approve = async (id) => {
    setActionLoading(id + "_approve");
    try {
      const res = await api.approvePartner(id);
      if (res.status === "success") {
        if (res.initial_password) {
          // ponytail: prompt() bukan toast — isinya bisa disalin dan tidak hilang sendiri setelah 4.5 detik
          window.prompt("Password awal mitra — salin & sampaikan sekarang, tidak ditampilkan lagi:", res.initial_password);
        }
        toast.success("Pendaftaran mitra berhasil disetujui! Akun mitra telah aktif.");
      } else {
        toast.error("Gagal menyetujui: " + res.error);
      }
    } catch (e) {
      toast.error("Terjadi kesalahan sistem.");
    } finally {
      setActionLoading(null);
      load(typeFilter, statusFilter);
    }
  };

  const reject = async (id) => {
    const ok = await confirmDialog({
      title: "Tolak pengajuan ini?",
      message: "Calon mitra tidak akan mendapatkan akun. Keputusan ini tidak bisa dibatalkan dari halaman ini.",
      confirmText: "Tolak pengajuan",
    });
    if (!ok) return;
    setActionLoading(id + "_reject");
    try {
      await api.rejectPartner(id);
      toast.success("Pendaftaran mitra berhasil ditolak.");
    } catch (e) {
      toast.error("Terjadi kesalahan sistem.");
    } finally {
      setActionLoading(null);
      load(typeFilter, statusFilter);
    }
  };

  return (
    <>
      <Topbar title="Pengajuan Mitra Kemitraan" />
      <div className="page">
        <div className="page-header">
          <h1>Pengajuan Kemitraan</h1>
          <p>Verifikasi pengajuan calon Mitra Resto Food & Mitra Rental Mobil</p>
        </div>

        {/* Filter Controls */}
        <div className="filter-panel">
          {/* Filter Type */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <label style={{ fontSize: 11, fontWeight: 700, textTransform: "uppercase", color: "var(--text-muted)", letterSpacing: 0.5 }}>Jenis Portal</label>
            <div style={{ display: "flex", gap: 8 }}>
              {TYPE_FILTER_ITEMS.map((f) => (
                <button
                  key={f.value}
                  className={`btn ${typeFilter === f.value ? "btn-primary" : "btn-ghost"}`}
                  onClick={() => {
                    setTypeFilter(f.value);
                    load(f.value, statusFilter);
                  }}
                  style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "8px 12px", fontSize: 13, height: "auto" }}
                >
                  {f.icon && <f.icon size={14} />}
                  <span>{f.label}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Filter Status */}
          <div className="filter-panel-search" style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <label style={{ fontSize: 11, fontWeight: 700, textTransform: "uppercase", color: "var(--text-muted)", letterSpacing: 0.5 }}>Status Verifikasi</label>
            <div style={{ display: "flex", gap: 8 }}>
              {FILTER_ITEMS.map((f) => (
                <button
                  key={f.value}
                  className={`filter-btn${statusFilter === f.value ? " active" : ""}`}
                  onClick={() => {
                    setStatusFilter(f.value);
                    load(typeFilter, f.value);
                  }}
                  style={{ display: "inline-flex", alignItems: "center", gap: 6 }}
                >
                  {f.icon && <f.icon size={13} />}
                  <span>{f.label}</span>
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* Cards Grid list */}
        {loading ? (
          <div className="loading-overlay" style={{ minHeight: 200 }}>
            <div className="spinner" />
            <p>Memuat pengajuan...</p>
          </div>
        ) : apps.length === 0 ? (
          <div className="card">
            <div className="empty-state" style={{ padding: "40px 0" }}>
              <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                <FileText size={48} style={{ color: "var(--text-muted)", opacity: 0.4 }} />
              </div>
              <h3>Tidak ada pengajuan</h3>
              <p>Pengajuan kemitraan baru akan muncul di sini</p>
            </div>
          </div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(360px, 1fr))", gap: 16 }}>
            {apps.map((app) => {
              const s = STATUS[app.status] || STATUS.pending;
              const isFood = app.type === "food";
              return (
                <div key={app.id} className="card" style={{ display: "flex", flexDirection: "column", gap: 16, borderLeft: `4px solid ${isFood ? "#f59e0b" : "#10b981"}` }}>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
                    <div>
                      <span className={`badge`} style={{ background: isFood ? "var(--warning-glow)" : "var(--success-glow)", color: isFood ? "#d97706" : "#059669", display: "inline-flex", alignItems: "center", gap: 4, marginBottom: 8, fontSize: 10, fontWeight: 700, textTransform: "uppercase" }}>
                        {isFood ? <Store size={10} /> : <KeyRound size={10} />}
                        {isFood ? "Mitra Resto Food" : "Mitra Rental"}
                      </span>
                      <div style={{ fontWeight: 800, fontSize: 16, color: "var(--text-primary)" }}>{app.business_name}</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 2 }}>{app.name} (Pemilik)</div>
                    </div>
                    <span className={`badge ${s.badge}`} style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
                      <s.icon size={11} />
                      {s.label}
                    </span>
                  </div>

                  <div style={{ display: "grid", gridTemplateColumns: "1fr", gap: 8, background: "var(--bg-input)", borderRadius: 12, padding: 12 }}>
                    {[
                      { label: "Nomor WhatsApp", value: app.phone_number },
                      { label: "Alamat Email", value: app.email },
                      { label: "Nomor KTP", value: app.ktp_number },
                      { label: isFood ? "Alamat Restoran" : "Alamat Kantor Rental", value: app.address },
                    ].map((f, idx) => (
                      <div key={idx} style={{ display: "flex", flexDirection: "column" }}>
                        <span style={{ fontSize: 9, color: "var(--text-muted)", fontWeight: 700, textTransform: "uppercase", letterSpacing: 0.5 }}>{f.label}</span>
                        <span style={{ fontSize: 13, fontWeight: 600, color: "var(--text-primary)", marginTop: 2, wordBreak: "break-all" }}>{f.value || "—"}</span>
                      </div>
                    ))}
                  </div>

                  {app.notes && (
                    <div style={{ fontSize: 12, background: "var(--bg-input)", border: "1px solid var(--border)", borderRadius: 10, padding: 10, color: "var(--text-muted)" }}>
                      <strong style={{ display: "block", fontSize: 10, textTransform: "uppercase", marginBottom: 2 }}>Catatan Pengaju:</strong>
                      {app.notes}
                    </div>
                  )}

                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: "auto", paddingTop: 12, borderTop: "1px solid var(--border)" }}>
                    <div style={{ fontSize: 11, color: "var(--text-muted)" }}>Tgl Pengajuan: {new Date(app.created_at).toLocaleString("id-ID")}</div>
                    {app.status === "pending" && (
                      <div style={{ display: "flex", gap: 8 }}>
                        <button className="btn btn-success" style={{ padding: "6px 12px", fontSize: 12, height: "auto", display: "inline-flex", alignItems: "center", gap: 4 }} onClick={() => approve(app.id)} disabled={actionLoading === app.id + "_approve"}>
                          {actionLoading === app.id + "_approve" ? <span className="spinner" /> : <><Check size={14} /> Setujui</>}
                        </button>
                        <button className="btn btn-danger" style={{ padding: "6px 12px", fontSize: 12, height: "auto", display: "inline-flex", alignItems: "center", gap: 4 }} onClick={() => reject(app.id)} disabled={actionLoading === app.id + "_reject"}>
                          {actionLoading === app.id + "_reject" ? <span className="spinner" /> : <><XCircle size={14} /> Tolak</>}
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

    </>
  );
}
