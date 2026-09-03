import { useEffect, useState } from "react";
import { CheckCircle, XCircle, Clock, FileText } from "lucide-react";
import { api, fileURL } from "../api";
import Topbar from "../components/Topbar";

const DOCS = [["KTP", "ktp_photo_url"], ["SIM", "sim_photo_url"], ["STNK", "stnk_photo_url"]];

const STATUS = { 
  pending: { label: "Menunggu", badge: "badge-warning", icon: Clock }, 
  approved: { label: "Disetujui", badge: "badge-success", icon: CheckCircle }, 
  rejected: { label: "Ditolak", badge: "badge-danger", icon: XCircle } 
};

const FILTER_ITEMS = [
  { value: "", label: "Semua", icon: null },
  { value: "pending", label: "Menunggu", icon: Clock },
  { value: "approved", label: "Disetujui", icon: CheckCircle },
  { value: "rejected", label: "Ditolak", icon: XCircle }
];

export default function ApplicationsPage() {
  const [apps, setApps] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState("");
  const [actionLoading, setActionLoading] = useState(null);

  const load = (status = "") => {
    setLoading(true);
    api.getApplications(status).then(d => { setApps(d.applications || []); setLoading(false); });
  };

  useEffect(() => { load(); }, []);

  const approve = async (app) => {
    // Menyetujui pengaju yang nomornya sudah punya akun akan MENIMPA peran
    // lamanya: penumpang yang jadi driver berhenti bisa memesan, tanpa
    // pemberitahuan apa pun ke dia. Admin berhak tahu sebelum menekan tombol.
    if (app.existing_role && app.existing_role !== "driver") {
      const lanjut = window.confirm(
        `Nomor ${app.phone_number} sudah punya akun dengan peran "${app.existing_role}". ` +
        "Menyetujui akan mengubah perannya jadi driver, dan dia tidak bisa lagi memesan sebagai penumpang. Lanjutkan?"
      );
      if (!lanjut) return;
    }

    setActionLoading(app.id + "_approve");
    const res = await api.approveDriver(app.id);
    if (res && res.error) {
      window.alert("Gagal menyetujui: " + res.error);
    } else if (res && res.initial_password) {
      // Password awal hanya ada untuk akun yang baru dibuat. Driver tidak bisa
      // masuk tanpa ini, jadi ditampilkan lewat prompt() supaya bisa disalin dan
      // tidak hilang sendiri seperti toast.
      window.prompt("Password awal driver — salin & sampaikan sekarang, tidak ditampilkan lagi:", res.initial_password);
    }
    setActionLoading(null); load(filter);
  };
  const reject = async (id) => {
    setActionLoading(id + "_reject");
    await api.rejectDriver(id);
    setActionLoading(null); load(filter);
  };

  return (
    <>
      <Topbar title="Pengajuan Driver" />
      <div className="page">
        <div className="page-header"><h1>Pengajuan Driver</h1><p>Verifikasi calon mitra driver bohAntar</p></div>
        <div className="filter-bar">
          {FILTER_ITEMS.map(f => (
            <button 
              key={f.value} 
              className={`filter-btn${filter === f.value ? " active" : ""}`} 
              onClick={() => { setFilter(f.value); load(f.value); }}
              style={{ display: "inline-flex", alignItems: "center", gap: 6 }}
            >
              {f.icon && <f.icon size={13} />}
              <span>{f.label}</span>
            </button>
          ))}
        </div>
        {loading ? <div className="loading-overlay"><div className="spinner" /><p>Memuat...</p></div> : apps.length === 0 ? (
          <div className="card">
            <div className="empty-state">
              <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                <FileText size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
              </div>
              <h3>Tidak ada pengajuan</h3>
              <p>Pengajuan driver baru akan muncul di sini</p>
            </div>
          </div>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(340px, 1fr))", gap: 16 }}>
            {apps.map(app => {
              const s = STATUS[app.status] || STATUS.pending;
              return (
                <div key={app.id} className="card" style={{ display: "flex", flexDirection: "column", gap: 16 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
                    <div>
                      <div style={{ fontWeight: 800, fontSize: 15 }}>{app.name}</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{app.phone_number}</div>
                    </div>
                    <span className={`badge ${s.badge}`}><s.icon size={11} />{s.label}</span>
                  </div>
                  <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
                    {[["Email", app.email], ["KTP", app.ktp_number], ["SIM", app.sim_number], ["Kendaraan", app.vehicle_type === "mobil" ? "Mobil" : "Motor"], ["Plat", app.vehicle_plate], ["Model", app.vehicle_model]].map(([l, v]) => (
                      <div key={l} style={{ background: "var(--bg-input)", borderRadius: 8, padding: "8px 10px" }}>
                        <div style={{ fontSize: 10, color: "var(--text-muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: 0.5 }}>{l}</div>
                        <div style={{ fontSize: 13, fontWeight: 600, marginTop: 2 }}>{v || "—"}</div>
                      </div>
                    ))}
                  </div>
                  <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                    {DOCS.map(([l, k]) => app[k] ? (
                      <a key={k} className="btn" href={fileURL(app[k])} target="_blank" rel="noreferrer" style={{ fontSize: 12, padding: "6px 10px" }}>
                        <FileText size={13} /> {l}
                      </a>
                    ) : (
                      <span key={k} style={{ fontSize: 12, padding: "6px 10px", color: "var(--text-muted)" }}>{l}: —</span>
                    ))}
                  </div>
                  <div style={{ fontSize: 11, color: "var(--text-muted)" }}>Dikirim: {new Date(app.created_at).toLocaleString("id-ID")}</div>
                  {app.status === "pending" && (
                    <div style={{ display: "flex", gap: 8 }}>
                      <button className="btn btn-success" style={{ flex: 1, justifyContent: "center" }} onClick={() => approve(app)} disabled={actionLoading === app.id + "_approve"}>
                        {actionLoading === app.id + "_approve" ? <span className="spinner" /> : <><CheckCircle size={14} /> Setujui</>}
                      </button>
                      <button className="btn btn-danger" style={{ flex: 1, justifyContent: "center" }} onClick={() => reject(app.id)} disabled={actionLoading === app.id + "_reject"}>
                        {actionLoading === app.id + "_reject" ? <span className="spinner" /> : <><XCircle size={14} /> Tolak</>}
                      </button>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </>
  );
}
