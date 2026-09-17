import { useEffect, useState } from "react";
import { Wallet, Percent, Banknote, Smartphone, Receipt, AlertTriangle, QrCode, CheckCircle, X } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

const rp = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");
// Diformat dari komponen lokal, bukan toISOString: di WIB tanggal 1 pukul 00.00
// jatuh ke pukul 17.00 UTC tanggal 31 bulan sebelumnya, dan seluruh rentang
// laporan meleset satu hari.
const tgl = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

/* Rentang siap pakai. Bulan lalu dihitung lewat setMonth pada tanggal 1 supaya
   tidak melompati bulan pendek — new Date(31 Mar).setMonth(-1) jatuh ke Maret. */
const RENTANG = [
  ["Bulan ini", () => { const a = new Date(); return [tgl(new Date(a.getFullYear(), a.getMonth(), 1)), tgl(a)]; }],
  ["Bulan lalu", () => { const a = new Date(); const m = new Date(a.getFullYear(), a.getMonth() - 1, 1); return [tgl(m), tgl(new Date(a.getFullYear(), a.getMonth(), 0))]; }],
  ["7 hari", () => { const a = new Date(); const m = new Date(); m.setDate(a.getDate() - 6); return [tgl(m), tgl(a)]; }],
  ["Tahun ini", () => { const a = new Date(); return [tgl(new Date(a.getFullYear(), 0, 1)), tgl(a)]; }],
];

export default function KomisiPage() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [[from, to], setRentang] = useState(RENTANG[0][1]());
  const [setoran, setSetoran] = useState(null); // { driver, nominal, id, qr, lunas }

  const load = (f, t) => {
    setLoading(true);
    api.getKomisi(f, t).then(d => { setData(d.status === "success" ? d : null); setLoading(false); });
  };
  useEffect(() => { load(from, to); }, [from, to]);

  // Setoran dibuat SESUDAH uang tunainya diterima. QR-nya lalu dipindai driver
  // untuk menaikkan saldonya sendiri — dua tangan, jadi saldo tidak pernah naik
  // hanya karena salah satu pihak menekan tombol.
  const mulaiSetoran = async (v) => {
    const utang = Math.abs(Math.min(0, v.saldo_driver));
    const isian = window.prompt(
      `Terima setoran tunai dari ${v.driver_name || v.driver_phone}.\n` +
      `Komisi yang belum disetor: ${rp(utang)}.\n\n` +
      "Masukkan nominal uang yang Anda terima:",
      String(Math.round(utang))
    );
    if (isian === null) return;
    const nominal = Number(String(isian).replace(/[^\d]/g, ""));
    if (!nominal) return;

    const res = await api.buatSetoran(v.driver_phone, nominal);
    if (!res || res.error) {
      window.alert("Gagal membuat setoran: " + (res?.error || "tidak diketahui"));
      return;
    }
    const qr = await api.qrSetoran(res.setoran.id);
    setSetoran({ driver: v.driver_name || v.driver_phone, nominal, id: res.setoran.id, qr, lunas: false });
  };

  // Selama QR terbuka, statusnya ditanyakan tiap 3 detik supaya petugas tahu
  // driver sudah memindai — tanpa itu keduanya saling menunggu di depan layar.
  useEffect(() => {
    if (!setoran || setoran.lunas) return;
    const t = setInterval(async () => {
      const res = await api.cekSetoran(setoran.id);
      if (res?.setoran?.claimed_at) {
        setSetoran(s => (s ? { ...s, lunas: true } : s));
        load(from, to);
      }
    }, 3000);
    return () => clearInterval(t);
  }, [setoran, from, to]);

  const tutupSetoran = () => {
    if (setoran?.qr) URL.revokeObjectURL(setoran.qr);
    setSetoran(null);
  };

  const d = data || {};
  const drivers = d.drivers || [];
  const kartu = [
    { label: "Pendapatan Kami", value: rp(d.total_pendapatan), icon: Wallet, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Dari Komisi", value: rp(d.total_komisi), icon: Percent, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Dari Biaya Jasa", value: rp(d.total_biaya_jasa), icon: Receipt, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Sudah di Kami (dompet)", value: rp(d.komisi_wallet), icon: Smartphone, color: "var(--primary)", bg: "var(--primary-glow)" },
    { label: "Dari Order Tunai", value: rp(d.komisi_tunai), icon: Banknote, color: "var(--warning)", bg: "var(--warning-glow)" },
    { label: "Ongkos Kotor", value: rp(d.total_ongkos), icon: Receipt, color: "var(--info)", bg: "var(--info-glow)" },
  ];

  return (
    <>
      <Topbar title="Bagi Hasil Driver" />
      <div className="page">
        <div className="page-header">
          <h1>Bagi Hasil Driver</h1>
          <p>Komisi yang kami peroleh dari pesanan selesai, dirinci per driver</p>
        </div>

        <div className="filter-bar">
          {RENTANG.map(([label, hitung]) => {
            const [f, t] = hitung();
            return (
              <button key={label} className={`filter-btn${from === f && to === t ? " active" : ""}`} onClick={() => setRentang([f, t])}>
                {label}
              </button>
            );
          })}
          <input className="input" type="date" value={from} max={to} style={{ width: 150 }} onChange={e => e.target.value && setRentang([e.target.value, to])} />
          <span style={{ color: "var(--text-muted)", fontSize: 12 }}>s/d</span>
          <input className="input" type="date" value={to} min={from} style={{ width: 150 }} onChange={e => e.target.value && setRentang([from, e.target.value])} />
        </div>

        {loading ? <div className="loading-overlay"><div className="spinner" /><p>Menghitung...</p></div> : (
          <>
            <div className="stats-grid" style={{ marginBottom: 24 }}>
              {kartu.map(s => (
                <div key={s.label} className="stat-card">
                  <div className="stat-icon" style={{ background: s.bg }}><s.icon size={22} style={{ color: s.color }} /></div>
                  <div style={{ minWidth: 0 }}>
                    <div className="stat-value" style={{ color: s.color, fontSize: 20 }}>{s.value}</div>
                    <div className="stat-label">{s.label}</div>
                  </div>
                </div>
              ))}
            </div>

            {/* Tunai belum tentu jadi uang: penumpang membayar ke driver, komisinya
                cuma memotong saldo driver sampai ia menyetor. */}
            {d.komisi_tunai > 0 && (
              <div className="card" style={{ marginBottom: 24, display: "flex", gap: 10, alignItems: "flex-start", borderColor: "var(--warning)" }}>
                <AlertTriangle size={18} style={{ color: "var(--warning)", flexShrink: 0, marginTop: 2 }} />
                <div style={{ fontSize: 13, color: "var(--text-secondary)" }}>
                  {rp(d.komisi_tunai)} berasal dari order tunai — uangnya diterima driver, komisi dan biaya jasanya dipotong dari saldo driver.
                  Saldo minus di tabel berarti uang itu belum disetor ke kami.
                </div>
              </div>
            )}

            <div className="card">
              <div className="table-header"><h3>{drivers.length} driver · {d.total_order || 0} pesanan selesai</h3></div>
              <table style={{ width: "100%" }}>
                <thead><tr><th>Driver</th><th>Pesanan</th><th>Ongkos Kotor</th><th>Bagian Driver</th><th>Komisi</th><th>Biaya Jasa</th><th>Belum Disetor</th><th>Saldo Driver</th><th>Setoran</th></tr></thead>
                <tbody>
                  {drivers.length === 0 ? (
                    <tr><td colSpan={9}>
                      <div className="empty-state">
                        <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                          <Wallet size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                        </div>
                        <h3>Belum ada komisi</h3>
                        <p>Tidak ada pesanan selesai di rentang tanggal ini</p>
                      </div>
                    </td></tr>
                  ) : drivers.map(v => (
                    <tr key={v.driver_phone}>
                      <td data-label="Driver">
                        <div className="user-cell">
                          <div className="user-avatar" style={{ background: "rgba(37,99,235,0.1)", color: "#3B82F6" }}>{v.driver_name?.[0] || "?"}</div>
                          <div><div className="user-name">{v.driver_name || "—"}</div><div className="user-sub">{v.driver_phone}</div></div>
                        </div>
                      </td>
                      <td data-label="Pesanan" style={{ fontWeight: 700 }}>{v.order_count}</td>
                      <td data-label="Ongkos Kotor">{rp(v.total_ongkos)}</td>
                      <td data-label="Bagian Driver" style={{ color: "var(--text-secondary)" }}>{rp(v.total_ongkos - v.komisi)}</td>
                      <td data-label="Komisi" style={{ color: "var(--success)", fontWeight: 700 }}>{rp(v.komisi)}</td>
                      <td data-label="Biaya Jasa" style={{ color: "var(--success)" }}>{rp(v.biaya_jasa)}</td>
                      <td data-label="Belum Disetor" style={{ color: v.komisi_tunai > 0 ? "var(--warning)" : "var(--text-muted)" }}>{rp(v.komisi_tunai)}</td>
                      <td data-label="Saldo Driver" style={{ color: v.saldo_driver < 0 ? "var(--danger)" : "var(--text-secondary)", fontWeight: v.saldo_driver < 0 ? 700 : 400 }}>{rp(v.saldo_driver)}</td>
                      <td data-label="Setoran">
                        {v.saldo_driver < 0 ? (
                          <button className="btn" style={{ fontSize: 12, padding: "6px 10px" }} onClick={() => mulaiSetoran(v)}>
                            <QrCode size={14} /> Terima setoran
                          </button>
                        ) : (
                          <span style={{ fontSize: 12, color: "var(--text-muted)" }}>—</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}

        {setoran && (
          <div
            onClick={tutupSetoran}
            style={{
              position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)",
              display: "flex", alignItems: "center", justifyContent: "center", zIndex: 50, padding: 20,
            }}
          >
            <div className="card" onClick={e => e.stopPropagation()} style={{ maxWidth: 380, width: "100%", textAlign: "center" }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                <div style={{ fontWeight: 800 }}>{setoran.lunas ? "Setoran diterima" : "Minta driver memindai"}</div>
                <button className="btn" style={{ padding: 6 }} onClick={tutupSetoran}><X size={15} /></button>
              </div>

              {setoran.lunas ? (
                <div style={{ padding: "24px 0" }}>
                  <CheckCircle size={56} style={{ color: "var(--success)" }} />
                  <div style={{ marginTop: 12, fontWeight: 700 }}>{rp(setoran.nominal)} masuk ke {setoran.driver}</div>
                  <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 4 }}>Saldo driver sudah dikurangi utang komisinya.</div>
                </div>
              ) : (
                <>
                  <img src={setoran.qr} alt="QR setoran" style={{ width: 240, height: 240, margin: "8px auto", display: "block" }} />
                  <div style={{ fontWeight: 800, fontSize: 18 }}>{rp(setoran.nominal)}</div>
                  <div style={{ fontSize: 13, color: "var(--text-secondary)" }}>{setoran.driver}</div>
                  <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 10 }}>
                    Berlaku 15 menit dan hanya bisa dipindai oleh driver ini. Jangan tutup jendela ini sebelum driver memindai.
                  </div>
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </>
  );
}
