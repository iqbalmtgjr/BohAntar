import { useState, useEffect } from "react";
import { Plus, Trash2, Settings, ConciergeBell, AlarmClock } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { toast, confirmDialog, Alert } from "../../components/Feedback";

// Toleransi disimpan dalam menit; ditampilkan ulang dalam bahasa sehari-hari.
function formatMenit(total) {
  const m = parseInt(total, 10) || 0;
  if (m <= 0) return "tanpa toleransi";
  const hari = Math.floor(m / 1440);
  const jam = Math.floor((m % 1440) / 60);
  const menit = m % 60;
  return [
    hari > 0 ? `${hari} hari` : "",
    jam > 0 ? `${jam} jam` : "",
    menit > 0 ? `${menit} menit` : ""
  ].filter(Boolean).join(" ");
}

export default function ServiceManagement() {
  const [services, setServices] = useState([]);
  const [loading, setLoading] = useState(true);

  // Aturan denda keterlambatan milik mitra ini sendiri.
  const [lateMode, setLateMode] = useState("off");
  const [lateValue, setLateValue] = useState(0);
  const [lateGrace, setLateGrace] = useState(0);
  const [lateErr, setLateErr] = useState("");
  const [lateSaving, setLateSaving] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [name, setName] = useState("");
  const [price, setPrice] = useState(0);
  const [error, setError] = useState("");

  const fetchServices = () => {
    setLoading(true);
    authFetch(`${BASE}/rental/services`)
      .then(r => r.json())
      .then(data => setServices(Array.isArray(data) ? data : []))
      .catch(err => console.error(err))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    fetchServices();
    authFetch(`${BASE}/rental/settings`)
      .then(r => r.json())
      .then(s => {
        setLateMode(s.late_fee_mode || "off");
        setLateValue(s.late_fee_value || 0);
        setLateGrace(s.late_fee_grace_minutes || 0);
      })
      .catch(err => console.error(err));
  }, []);

  const handleSaveLateFee = (e) => {
    e.preventDefault();
    setLateErr("");
    setLateSaving(true);
    authFetch(`${BASE}/rental/settings`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        late_fee_mode: lateMode,
        late_fee_value: parseFloat(lateValue) || 0,
        late_fee_grace_minutes: parseInt(lateGrace, 10) || 0
      })
    })
      .then(async r => {
        const data = await r.json();
        if (!r.ok) throw new Error(data.error || "Gagal menyimpan aturan denda");
        return data;
      })
      .then(() => toast.success("Aturan denda tersimpan"))
      .catch(err => setLateErr(err.message || "Gagal menyimpan aturan denda"))
      .finally(() => setLateSaving(false));
  };

  const resetForm = () => {
    setEditingId(null);
    setName("");
    setPrice(0);
    setError("");
    setShowForm(false);
  };

  const handleSubmit = (e) => {
    e.preventDefault();
    setError("");
    if (!name.trim()) {
      setError("Nama jasa wajib diisi");
      return;
    }
    authFetch(editingId ? `${BASE}/rental/services/${editingId}` : `${BASE}/rental/services`, {
      method: editingId ? "PUT" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: name.trim(), price: parseFloat(price) || 0 })
    })
      .then(async r => {
        const data = await r.json();
        if (!r.ok) throw new Error(data.error || "Gagal menyimpan jasa");
        return data;
      })
      .then(() => {
        const pesan = editingId ? "Jasa berhasil diperbarui" : "Jasa berhasil ditambahkan";
        resetForm();
        fetchServices();
        toast.success(pesan);
      })
      .catch(err => setError(err.message || "Gagal menyimpan jasa"));
  };

  const handleEdit = (s) => {
    setEditingId(s.id);
    setName(s.name);
    setPrice(s.price);
    setError("");
    setShowForm(true);
  };

  const handleDelete = async (s) => {
    const ok = await confirmDialog({
      title: `Hapus jasa "${s.name}"?`,
      message: "Jadwal lama yang sudah memakai jasa ini tidak ikut berubah.",
      confirmText: "Hapus jasa",
    });
    if (!ok) return;
    authFetch(`${BASE}/rental/services/${s.id}`, { method: "DELETE" })
      .then(r => r.json())
      .then(() => {
        fetchServices();
        toast.success("Jasa berhasil dihapus");
      })
      .catch(err => toast.error(err.message || "Gagal menghapus jasa"));
  };

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
        <div>
          <h1>Jasa Layanan & Denda</h1>
          <p>Daftar layanan yang Anda tawarkan, misalnya Lepas Kunci atau Dengan Supir, beserta aturan denda keterlambatan. Jasa ini bisa dipilih saat menambah jadwal di kalender.</p>
        </div>
        <button onClick={() => (showForm ? resetForm() : setShowForm(true))} className="btn btn-primary">
          <Plus size={18} /> {showForm ? "Tutup Form" : "Tambah Jasa"}
        </button>
      </div>

      {/* Aturan denda keterlambatan: dipakai otomatis saat sewa ditandai Selesai */}
      <div className="card" style={{ marginBottom: 28, maxWidth: 720 }}>
        <div className="card-title" style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <AlarmClock size={18} style={{ color: "#B45309" }} />
          <span>Denda Keterlambatan</span>
        </div>
        <p style={{ fontSize: 13, color: "var(--text-secondary)", marginTop: 4, marginBottom: 16 }}>
          Dihitung otomatis saat Anda menekan <strong>Selesai</strong> pada sewa yang melewati jatuh tempo,
          lalu ditambahkan ke total tagihan dan tercatat di Laporan. Masa toleransi dianggap waktu gratis:
          denda baru berjalan setelah toleransi habis, lalu dihitung <strong>per hari</strong> dan dibulatkan
          ke atas — lewat 2 jam dari toleransi tetap terhitung 1 hari.
        </p>

        <Alert type="error">{lateErr}</Alert>

        <form onSubmit={handleSaveLateFee}>
          <div className="grid-2">
            <div className="input-group">
              <label>Cara Menghitung</label>
              <select className="input" value={lateMode} onChange={e => setLateMode(e.target.value)}>
                <option value="off">Tidak ada denda</option>
                <option value="percent">Persen dari tarif harian mobil</option>
                <option value="amount">Nominal tetap per hari</option>
              </select>
            </div>
            {lateMode !== "off" && (
              <div className="input-group">
                <label>{lateMode === "percent" ? "Besar Denda (%)" : "Besar Denda (Rp)"}</label>
                <input
                  className="input"
                  type="number"
                  min="0"
                  step={lateMode === "percent" ? "5" : "10000"}
                  value={lateValue}
                  onChange={e => { setLateValue(e.target.value); setLateMsg(""); }}
                  placeholder={lateMode === "percent" ? "Contoh: 20" : "Contoh: 100000"}
                />
              </div>
            )}
          </div>

          {lateMode !== "off" && (
            <div className="input-group">
              <label>Toleransi Keterlambatan</label>
              <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                <select
                  className="input"
                  style={{ maxWidth: 220 }}
                  value={[0, 15, 30, 60, 120, 180, 360].includes(parseInt(lateGrace, 10) || 0) ? String(parseInt(lateGrace, 10) || 0) : "custom"}
                  onChange={e => { if (e.target.value !== "custom") setLateGrace(e.target.value); setLateMsg(""); }}
                >
                  <option value="0">Tanpa toleransi</option>
                  <option value="15">15 menit</option>
                  <option value="30">30 menit</option>
                  <option value="60">1 jam</option>
                  <option value="120">2 jam</option>
                  <option value="180">3 jam</option>
                  <option value="360">6 jam</option>
                  <option value="custom">Lainnya (isi sendiri)</option>
                </select>
                <input
                  className="input"
                  style={{ maxWidth: 160 }}
                  type="number"
                  min="0"
                  max="10080"
                  step="15"
                  value={lateGrace}
                  onChange={e => { setLateGrace(e.target.value); setLateMsg(""); }}
                  placeholder="menit"
                />
              </div>
              <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>
                Dalam menit. Denda baru mulai dihitung setelah lewat {formatMenit(lateGrace)}.
              </div>
            </div>
          )}

          {lateMode !== "off" && (parseFloat(lateValue) || 0) > 0 && (
            <div style={{ background: "var(--bg-input)", border: "1px solid var(--border)", borderRadius: 10, padding: 12, fontSize: 13, marginBottom: 16, lineHeight: 1.7 }}>
              Mobil tarif <strong>Rp 300.000/hari</strong>, toleransi <strong>{formatMenit(lateGrace)}</strong>:
              <div>
                • Kembali {formatMenit(Math.max(1, Math.floor((parseInt(lateGrace, 10) || 0) / 2)))} setelah jatuh tempo →{" "}
                <strong style={{ color: (parseInt(lateGrace, 10) || 0) > 0 ? "#059669" : "#B45309" }}>
                  {(parseInt(lateGrace, 10) || 0) > 0
                    ? "tidak kena denda"
                    : `Rp ${(lateMode === "percent" ? 300000 * (parseFloat(lateValue) || 0) / 100 : parseFloat(lateValue) || 0).toLocaleString("id-ID")}`}
                </strong>
              </div>
              <div>
                • Telat <strong>2 hari</strong> lewat toleransi →{" "}
                <strong style={{ color: "#B45309" }}>
                  Rp {(lateMode === "percent"
                    ? 2 * 300000 * (parseFloat(lateValue) || 0) / 100
                    : 2 * (parseFloat(lateValue) || 0)
                  ).toLocaleString("id-ID")}
                </strong>
              </div>
            </div>
          )}

          <button type="submit" className="btn btn-primary" disabled={lateSaving} style={{ padding: "10px 20px" }}>
            {lateSaving ? "Menyimpan..." : "Simpan Aturan Denda"}
          </button>
        </form>
      </div>

      {showForm && (
        <div className="card" style={{ marginBottom: 28, maxWidth: 600 }}>
          <div className="card-title">{editingId ? "Ubah Jasa" : "Form Tambah Jasa Baru"}</div>
          <Alert type="error">{error}</Alert>
          <form onSubmit={handleSubmit}>
            <div className="grid-2">
              <div className="input-group">
                <label>Nama Jasa</label>
                <input className="input" list="jasa-preset" placeholder="Contoh: Lepas Kunci" value={name} onChange={e => setName(e.target.value)} required />
                <datalist id="jasa-preset">
                  <option value="Lepas Kunci" />
                  <option value="Dengan Supir" />
                  <option value="Antar Jemput" />
                </datalist>
              </div>
              <div className="input-group">
                <label>Tarif Tambahan per Hari (Rp)</label>
                <input className="input" type="number" min="0" step="10000" value={price} onChange={e => setPrice(e.target.value)} />
              </div>
            </div>
            <button type="submit" className="btn btn-primary" style={{ width: "100%", justifyContent: "center", padding: 12 }}>
              {editingId ? "Simpan Perubahan" : "Tambahkan Jasa"}
            </button>
          </form>
        </div>
      )}

      {loading ? (
        <div className="spinner" style={{ margin: "50px auto" }}></div>
      ) : services.length === 0 ? (
        <div className="card" style={{ textAlign: "center", padding: 50, color: "var(--text-muted)" }}>
          <ConciergeBell size={48} style={{ margin: "0 auto 16px", color: "var(--border)" }} />
          <h3>Belum ada jasa yang didaftarkan</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>Klik tombol Tambah Jasa untuk mendaftarkan layanan seperti Lepas Kunci atau Dengan Supir</p>
        </div>
      ) : (
        <div className="grid-3">
          {services.map(s => (
            <div key={s.id} className="card" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
              <div>
                <h3 style={{ fontSize: 16, fontWeight: 800 }}>{s.name}</h3>
                <div style={{ fontSize: 13, color: s.price > 0 ? "var(--primary)" : "var(--text-secondary)", fontWeight: 700, marginTop: 4 }}>
                  {s.price > 0 ? `+ Rp ${s.price.toLocaleString("id-ID")}/hari` : "Tanpa biaya tambahan"}
                </div>
              </div>
              <div style={{ display: "flex", gap: 8 }}>
                <button onClick={() => handleEdit(s)} className="btn btn-ghost btn-sm" style={{ padding: 8 }}>
                  <Settings size={16} />
                </button>
                <button onClick={() => handleDelete(s)} className="btn btn-danger btn-sm" style={{ padding: 8 }}>
                  <Trash2 size={16} />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
