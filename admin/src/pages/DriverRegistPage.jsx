import { useState } from "react";
import { UserPlus, CheckCircle, User, Bike, FileText, Clock } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { Alert } from "../components/Feedback";

const EMPTY_FORM = { phone_number: "", name: "", email: "", ktp_number: "", sim_number: "", vehicle_plate: "", vehicle_type: "motor", vehicle_model: "", notes: "" };
const DOCS = [
  { key: "ktp_photo_url", label: "Scan KTP" },
  { key: "sim_photo_url", label: "Scan SIM" },
  { key: "stnk_photo_url", label: "Scan STNK" },
];
const ACCEPT = "image/jpeg,image/png,image/webp,.heic,.heif,application/pdf";

export default function DriverRegistPage() {
  const [form, setForm] = useState(EMPTY_FORM);
  const [docs, setDocs] = useState({});
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(null);
  const [error, setError] = useState("");

  const set = (k, v) => setForm(f => ({ ...f, [k]: v }));

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true); setError("");
    // Unggah dulu ketiga dokumen; backend menolak pengajuan tanpa URL-nya.
    const uploads = await Promise.all(DOCS.map(d => api.uploadFile(docs[d.key])));
    const failed = uploads.find(u => u.status !== "success");
    if (failed) { setLoading(false); setError(failed.error || "Gagal mengunggah dokumen"); return; }
    const payload = { ...form };
    DOCS.forEach((d, i) => { payload[d.key] = uploads[i].url; });
    const res = await api.registerDriver(payload);
    setLoading(false);
    if (res.status === "success") { setSuccess(res.application); setForm(EMPTY_FORM); setDocs({}); e.target.reset(); }
    else setError(res.error || "Gagal mendaftar driver");
  };

  return (
    <>
      <Topbar title="Pendaftaran Driver" />
      <div className="page">
        <div className="page-header"><h1>Daftar Driver Baru</h1><p>Isi data lengkap calon mitra driver bohAntar</p></div>

        {success && (
          <div className="card" style={{ marginBottom: 24, border: "1px solid var(--success)", background: "var(--success-glow)" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
              <CheckCircle size={24} style={{ color: "var(--success)" }} />
              <div>
                <div style={{ fontWeight: 700, color: "var(--success)" }}>Pendaftaran Berhasil!</div>
                <div style={{ color: "var(--text-secondary)", fontSize: 13 }}>ID: {success.id} — Status menunggu verifikasi admin</div>
              </div>
            </div>
          </div>
        )}

        <Alert type="error" style={{ marginBottom: 20 }}>{error}</Alert>

        <div className="grid-2">
          <div className="card">
            <div style={{ fontWeight: 700, marginBottom: 16, fontSize: 15, display: "flex", alignItems: "center", gap: 8 }}>
              <User size={16} style={{ color: "var(--primary)" }} />
              <span>Data Pribadi</span>
            </div>
            <form onSubmit={handleSubmit}>
              {[
                { label: "Nama Lengkap", key: "name", placeholder: "Budi Santoso", type: "text" },
                { label: "Nomor HP (WhatsApp)", key: "phone_number", placeholder: "+628123456789", type: "tel" },
                { label: "Email", key: "email", placeholder: "driver@email.com", type: "email" },
                { label: "Nomor KTP", key: "ktp_number", placeholder: "3201XXXXXXXXXXXX", type: "text" },
                { label: "Nomor SIM", key: "sim_number", placeholder: "XXXXXXXXXXXXXXXX", type: "text" },
              ].map(f => (
                <div key={f.key} className="input-group">
                  <label>{f.label}</label>
                  <input className="input" type={f.type} placeholder={f.placeholder} value={form[f.key]} onChange={e => set(f.key, e.target.value)} required />
                </div>
              ))}

              <div style={{ fontWeight: 700, margin: "20px 0 16px", fontSize: 15, display: "flex", alignItems: "center", gap: 8 }}>
                <Bike size={16} style={{ color: "var(--primary)" }} />
                <span>Data Kendaraan</span>
              </div>

              <div className="input-group">
                <label>Jenis Kendaraan</label>
                <select className="input" value={form.vehicle_type} onChange={e => set("vehicle_type", e.target.value)}>
                  <option value="motor">Sepeda Motor</option>
                  <option value="mobil">Mobil</option>
                </select>
              </div>

              {[
                { label: "Plat Nomor", key: "vehicle_plate", placeholder: "KB 1234 AB" },
                { label: "Merk/Model Kendaraan", key: "vehicle_model", placeholder: "Honda Vario 125" },
              ].map(f => (
                <div key={f.key} className="input-group">
                  <label>{f.label}</label>
                  <input className="input" type="text" placeholder={f.placeholder} value={form[f.key]} onChange={e => set(f.key, e.target.value)} required />
                </div>
              ))}

              <div style={{ fontWeight: 700, margin: "20px 0 16px", fontSize: 15, display: "flex", alignItems: "center", gap: 8 }}>
                <FileText size={16} style={{ color: "var(--primary)" }} />
                <span>Dokumen</span>
              </div>

              {DOCS.map(d => (
                <div key={d.key} className="input-group">
                  <label>{d.label}</label>
                  <input className="input" type="file" accept={ACCEPT} onChange={e => setDocs(v => ({ ...v, [d.key]: e.target.files[0] }))} required />
                </div>
              ))}
              <div style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 16 }}>Foto atau PDF, maksimal 5 MB per dokumen.</div>

              <div className="input-group">
                <label>Catatan Tambahan</label>
                <textarea className="input" rows={3} placeholder="Catatan opsional..." value={form.notes} onChange={e => set("notes", e.target.value)} style={{ resize: "vertical" }} />
              </div>

              <button type="submit" className="btn btn-primary" disabled={loading} style={{ width: "100%", justifyContent: "center", padding: "12px" }}>
                {loading ? <span className="spinner" /> : <><UserPlus size={16} /> Daftarkan Driver</>}
              </button>
            </form>
          </div>

          <div className="card" style={{ height: "fit-content" }}>
            <div style={{ fontWeight: 700, marginBottom: 12, fontSize: 15, display: "flex", alignItems: "center", gap: 8 }}>
              <FileText size={16} style={{ color: "var(--primary)" }} />
              <span>Syarat & Ketentuan</span>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
              {["Memiliki SIM C yang masih berlaku (motor) atau SIM A (mobil)", "Kendaraan maksimal berumur 10 tahun", "KTP asli Warga Negara Indonesia", "Smartphone dengan Android/iOS terbaru", "Rekening bank aktif atas nama sendiri"].map((s, i) => (
                <div key={i} style={{ display: "flex", gap: 10, alignItems: "flex-start" }}>
                  <CheckCircle size={16} style={{ color: "var(--success)", flexShrink: 0, marginTop: 2 }} />
                  <span style={{ fontSize: 13, color: "var(--text-secondary)" }}>{s}</span>
                </div>
              ))}
            </div>
            <div style={{ marginTop: 24, padding: 16, background: "var(--bg-input)", borderRadius: 10, fontSize: 13 }}>
              <div style={{ fontWeight: 600, marginBottom: 4, display: "flex", alignItems: "center", gap: 6 }}>
                <Clock size={14} style={{ color: "var(--warning)" }} />
                <span>Proses Verifikasi</span>
              </div>
              <div style={{ color: "var(--text-secondary)" }}>Pengajuan akan diverifikasi admin dalam 1-3 hari kerja. Driver akan dihubungi via WhatsApp.</div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
