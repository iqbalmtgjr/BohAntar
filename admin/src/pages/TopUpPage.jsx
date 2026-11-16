import { useEffect, useState } from "react";
import { QrCode } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { toast } from "../components/Feedback";

const rp = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");
// Jam lokal, bukan toISOString: tanggal 1 sebelum 07.00 WIB masih bulan lalu di UTC.
const bulanIni = () => { const n = new Date(); return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, "0")}`; };

function Status({ t }) {
  if (t.status === "PAID") return <span className="badge badge-success">Lunas</span>;
  if (t.status === "DITOLAK") return <span className="badge badge-danger">Ditolak</span>;
  return <span className="badge badge-muted">QR lama tak dibayar</span>; // PENDING: QR Xendit sebelum 16 Nov 2026
}

/* Top up saldo komisi driver, manual sejak 16 Nov 2026: driver transfer lalu
   mengajukan, admin dapat email, mengecek uang masuk, lalu Setujui/Tolak di
   sini. Pengajuan yang menunggu selalu tampil di atas, bulan apa pun. */
export default function TopUpPage() {
  const [bulan, setBulan] = useState(bulanIni());
  const [d, setD] = useState(null);
  const [cari, setCari] = useState("");
  const [semua, setSemua] = useState(false);
  const [proses, setProses] = useState("");

  const muat = () => api.adminTopUp(bulan).then(setD, () => setD({ error: "Gagal terhubung ke server" }));
  useEffect(() => { setD(null); muat(); }, [bulan]);

  const tindak = async (t, aksi) => {
    const tanya = aksi === "setujui"
      ? `Transfer ${rp(t.amount)} dari ${t.nama} (${t.phone_number}) sudah masuk?\n\nSaldonya langsung bertambah.`
      : `Tolak pengajuan ${rp(t.amount)} dari ${t.nama}? Saldo tidak berubah.`;
    if (!window.confirm(tanya)) return;
    setProses(t.id);
    const res = await api.prosesTopUp(t.id, aksi);
    setProses("");
    if (res?.status !== "success") toast.error(res?.error || "Gagal memproses top up");
    else toast.success(aksi === "setujui" ? "Saldo driver bertambah" : "Pengajuan ditolak");
    muat();
  };

  const kata = cari.trim().toLowerCase();
  const menunggu = (d?.topup || []).filter(t => t.status === "MENUNGGU");
  const daftar = (d?.topup || []).filter(t =>
    t.status !== "MENUNGGU" && (semua || t.status === "PAID") &&
    (!kata || t.nama.toLowerCase().includes(kata) || t.phone_number.includes(kata)));

  return (
    <>
      <Topbar title="Top Up Driver" />
      <div className="page">
        <div className="page-header">
          <h1>Top Up Driver</h1>
          <p>Driver transfer lalu mengajukan. Cek uang masuk di rekening, lalu Setujui — saldo bertambah saat itu juga.</p>
        </div>

        {menunggu.length > 0 && (
          <div className="card" style={{ marginBottom: 24, borderLeft: "4px solid var(--warning)" }}>
            <h3 style={{ marginBottom: 12 }}>Menunggu persetujuan ({menunggu.length})</h3>
            <table style={{ width: "100%" }}>
              <thead>
                <tr><th>Diajukan</th><th>Driver</th><th>Nominal</th><th></th></tr>
              </thead>
              <tbody>
                {menunggu.map(t => (
                  <tr key={t.id}>
                    <td data-label="Diajukan">{new Date(t.created_at).toLocaleString("id-ID")}</td>
                    <td data-label="Driver">
                      <div style={{ fontWeight: 700 }}>{t.nama || "(akun terhapus)"}</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{t.phone_number}</div>
                    </td>
                    <td data-label="Nominal" style={{ fontWeight: 700 }}>{rp(t.amount)}</td>
                    <td style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                      <button className="btn btn-primary" disabled={proses === t.id} onClick={() => tindak(t, "setujui")}>Setujui</button>
                      <button className="btn" disabled={proses === t.id} onClick={() => tindak(t, "tolak")}>Tolak</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <div className="filter-bar">
          <input className="input" type="month" value={bulan} max={bulanIni()} style={{ width: 170 }} onChange={e => e.target.value && setBulan(e.target.value)} />
          <input className="input" placeholder="Cari nama / nomor driver" value={cari} style={{ width: 220 }} onChange={e => setCari(e.target.value)} />
          <button className={`filter-btn${semua ? "" : " active"}`} onClick={() => setSemua(false)}>Lunas</button>
          <button className={`filter-btn${semua ? " active" : ""}`} onClick={() => setSemua(true)}>Semua</button>
        </div>

        {!d ? <div className="loading-overlay"><div className="spinner" /></div> : d.status !== "success" ? (
          <div className="card">{d.error || "Gagal memuat riwayat top up"}</div>
        ) : (
          <>
            <div className="stats-grid" style={{ marginBottom: 24 }}>
              <div className="stat-card">
                <div style={{ minWidth: 0 }}>
                  <div className="stat-value" style={{ color: "var(--success)", fontSize: 20 }}>{rp(d.total_lunas)}</div>
                  <div className="stat-label">Masuk bulan ini ({d.jumlah_lunas} top up lunas)</div>
                </div>
              </div>
            </div>

            <div className="card">
              {daftar.length === 0 ? (
                <div className="empty-state">
                  <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                    <QrCode size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                  </div>
                  <h3>Belum ada top up{semua ? "" : " lunas"} di bulan ini</h3>
                </div>
              ) : (
                <table style={{ width: "100%" }}>
                  <thead>
                    <tr><th>Waktu</th><th>Driver</th><th>Nominal</th><th>Status</th></tr>
                  </thead>
                  <tbody>
                    {daftar.map(t => (
                      <tr key={t.id}>
                        <td data-label="Waktu">
                          {new Date(t.paid_at || t.created_at).toLocaleString("id-ID")}
                          {t.paid_at && <div style={{ fontSize: 12, color: "var(--text-muted)" }}>Diajukan {new Date(t.created_at).toLocaleTimeString("id-ID")}</div>}
                        </td>
                        <td data-label="Driver">
                          <div style={{ fontWeight: 700 }}>{t.nama || "(akun terhapus)"}</div>
                          <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{t.phone_number}</div>
                        </td>
                        <td data-label="Nominal" style={{ fontWeight: 700 }}>{rp(t.amount)}</td>
                        <td data-label="Status"><Status t={t} /></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </>
        )}
      </div>
    </>
  );
}
