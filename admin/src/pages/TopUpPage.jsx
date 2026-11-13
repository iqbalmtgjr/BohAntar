import { useEffect, useState } from "react";
import { QrCode } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

const rp = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");
// Jam lokal, bukan toISOString: tanggal 1 sebelum 07.00 WIB masih bulan lalu di UTC.
const bulanIni = () => { const n = new Date(); return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, "0")}`; };
// QR top up dibuat Xendit dengan masa berlaku sejam (buatInvoiceQRIS).
const basi = (t) => Date.now() - new Date(t).getTime() > 3600e3;

function Status({ t }) {
  if (t.status === "PAID") return <span className="badge badge-success">Lunas</span>;
  return basi(t.created_at)
    ? <span className="badge badge-muted">Tidak dibayar</span>
    : <span className="badge badge-warning">Menunggu bayar</span>;
}

/* Riwayat top up saldo komisi driver lewat QRIS, per bulan. Yang dihitung
   masuk hanya yang lunas; QR yang tidak dibayar ikut tampil supaya admin bisa
   menjawab driver yang mengaku "sudah bayar tapi saldo belum masuk". */
export default function TopUpPage() {
  const [bulan, setBulan] = useState(bulanIni());
  const [d, setD] = useState(null);
  const [cari, setCari] = useState("");
  const [semua, setSemua] = useState(false);

  useEffect(() => {
    setD(null);
    api.adminTopUp(bulan).then(setD, () => setD({ error: "Gagal terhubung ke server" }));
  }, [bulan]);

  const kata = cari.trim().toLowerCase();
  const daftar = (d?.topup || []).filter(t =>
    (semua || t.status === "PAID") &&
    (!kata || t.nama.toLowerCase().includes(kata) || t.phone_number.includes(kata)));

  return (
    <>
      <Topbar title="Top Up Driver" />
      <div className="page">
        <div className="page-header">
          <h1>Riwayat Top Up Driver</h1>
          <p>Isi saldo komisi driver lewat QRIS. Saldo bertambah otomatis begitu lunas.</p>
        </div>

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
                          {t.paid_at && <div style={{ fontSize: 12, color: "var(--text-muted)" }}>QR dibuat {new Date(t.created_at).toLocaleTimeString("id-ID")}</div>}
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
