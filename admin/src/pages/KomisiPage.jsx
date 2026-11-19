import { useEffect, useState } from "react";
import { Wallet, Percent, Banknote, Smartphone, Receipt, AlertTriangle, QrCode, CheckCircle, X } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { DetailPesanan } from "./OrdersPage";

// Pesanan selesai seorang driver di rentang laporan; klik satu → detail lengkap.
function RincianDriver({ v, from, to, onTutup }) {
  const [res, setRes] = useState(null);
  const [detail, setDetail] = useState(null);
  useEffect(() => {
    // ponytail: 200 pesanan pertama saja; tambah halaman kalau ada driver melewatinya sebulan.
    api.getOrders({ driver: v.driver_phone, status: "completed", from, to, limit: 200 }).then(setRes);
  }, [v, from, to]);
  const orders = res?.orders || [];

  return (
    <>
    <div className="modal-overlay" onClick={onTutup}>
      <div className="modal" onClick={e => e.stopPropagation()} style={{ maxWidth: 820, position: "relative" }} role="dialog" aria-modal="true">
        <button className="filter-btn" onClick={onTutup} aria-label="Tutup" style={{ position: "absolute", top: 16, right: 16, padding: 6 }}><X size={16} /></button>
        <h2>{v.driver_name || v.driver_phone}</h2>
        <p className="modal-desc" style={{ marginBottom: 16 }}>{v.order_count} pesanan selesai · {from} s/d {to} · klik pesanan untuk detail</p>
        {!res ? <div className="loading-overlay"><div className="spinner" /></div> : (
          <div style={{ overflowX: "auto" }}>
            <table style={{ width: "100%" }}>
              <thead><tr><th>Pesanan</th><th>Layanan</th><th>Bayar</th><th>Ongkos</th><th>Komisi</th><th>Biaya Jasa</th><th>Diskon</th><th>Bagian Kami</th><th>Bagian Driver</th></tr></thead>
              <tbody>
                {orders.map(o => (
                  <tr key={o.id} onClick={() => setDetail(o)} style={{ cursor: "pointer" }} title="Klik untuk lihat detail">
                    <td data-label="Pesanan">
                      <span className="chip">#{o.id?.slice(-6)}</span>
                      <div style={{ fontSize: 11, color: "var(--text-muted)" }}>{new Date(o.created_at).toLocaleString("id-ID")}</div>
                    </td>
                    <td data-label="Layanan"><span className="badge badge-primary">{o.service}{o.kelas ? ` ${o.kelas}` : ""}</span></td>
                    <td data-label="Bayar">{o.payment_method === "cash" ? "Tunai" : "Saldo"}</td>
                    <td data-label="Ongkos">{rp(o.fare)}</td>
                    <td data-label="Komisi" style={{ color: "var(--success)" }}>{rp(o.komisi)}</td>
                    <td data-label="Biaya Jasa" style={{ color: "var(--success)" }}>{rp(o.biaya_jasa)}</td>
                    <td data-label="Diskon" style={{ color: o.diskon > 0 ? "var(--danger)" : "var(--text-muted)" }}>{o.diskon > 0 ? "− " + rp(o.diskon) : "—"}</td>
                    <td data-label="Bagian Kami" style={{ color: "var(--success)", fontWeight: 700 }}>{rp(o.komisi + o.biaya_jasa - o.diskon)}</td>
                    <td data-label="Bagian Driver" style={{ color: "var(--text-secondary)" }}>{rp(o.fare - o.komisi)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {res.total > orders.length && <p style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 8 }}>Menampilkan {orders.length} dari {res.total} pesanan.</p>}
          </div>
        )}
      </div>
    </div>
    {detail && <DetailPesanan o={detail} dilepas={res?.dilepas?.[detail.id]} onTutup={() => setDetail(null)} />}
    </>
  );
}

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
  const [rincian, setRincian] = useState(null); // baris driver yang diklik

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
  const tagihan = d.tagihan_qr || [];
  // Potongan order tunai diambil dari saldo komisi yang sudah di-top up driver;
  // yang benar-benar belum disetor hanya saldo yang jatuh di bawah nol.
  const utangDriver = drivers.reduce((n, v) => n + Math.max(0, -v.saldo_driver), 0);
  const kartu = [
    { label: "Pendapatan Kami", value: rp(d.total_pendapatan), icon: Wallet, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Dari Komisi", value: rp(d.total_komisi), icon: Percent, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Dari Biaya Jasa", value: rp(d.total_biaya_jasa), icon: Receipt, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Dari Tagihan QR Mitra", value: rp(d.total_komisi_tagihan), icon: QrCode, color: "var(--success)", bg: "var(--success-glow)" },
    { label: "Diskon Voucher (mengurangi pendapatan)", value: rp(d.total_diskon), icon: Percent, color: "var(--danger)", bg: "var(--danger-glow)" },
    { label: "Sudah di Kami (dompet)", value: rp(d.komisi_wallet), icon: Smartphone, color: "var(--primary)", bg: "var(--primary-glow)" },
    { label: "Dari Order Tunai", value: rp(d.komisi_tunai), icon: Banknote, color: "var(--warning)", bg: "var(--warning-glow)" },
    { label: "Ongkos Kotor", value: rp(d.total_ongkos), icon: Receipt, color: "var(--info)", bg: "var(--info-glow)" },
  ];

  return (
    <>
      <Topbar title="Pendapatan & Bagi Hasil" />
      <div className="page">
        <div className="page-header">
          <h1>Pendapatan & Bagi Hasil</h1>
          <p>Komisi yang kami peroleh dari pesanan selesai (per driver) dan dari tagihan QR mitra yang dibayar</p>
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

            {/* Rumusnya dipakai juga oleh kartu "Pendapatan Kami" di dashboard. */}
            <details open className="card" style={{ marginBottom: 24, fontSize: 13, color: "var(--text-secondary)", lineHeight: 1.7 }}>
              <summary style={{ fontWeight: 700, color: "var(--text-primary)", cursor: "pointer" }}>Cara membaca angka ini</summary>
              <div style={{ marginTop: 10 }}>
                Dari setiap pesanan selesai:
                <ul style={{ margin: "4px 0 12px 18px" }}>
                  <li><b>Penumpang membayar</b> = ongkos + biaya jasa − diskon voucher (harga makanan BohFood langsung milik warung, tidak dihitung di sini)</li>
                  <li><b>Driver menerima</b> = ongkos − komisi</li>
                  <li><b>BohAntar menerima</b> = komisi + biaya jasa − diskon voucher</li>
                </ul>
                Untuk rentang {from} s/d {to}:
                <ul style={{ margin: "4px 0 0 18px" }}>
                  <li>Ongkos kotor {rp(d.total_ongkos)} − komisi {rp(d.total_komisi)} = <b>bagian driver {rp((d.total_ongkos || 0) - (d.total_komisi || 0))}</b></li>
                  <li>Komisi {rp(d.total_komisi)} + biaya jasa {rp(d.total_biaya_jasa)} + potongan QR mitra {rp(d.total_komisi_tagihan)} − diskon {rp(d.total_diskon)} = <b style={{ color: "var(--success)" }}>Pendapatan Kami {rp(d.total_pendapatan)}</b></li>
                  <li>Dari jumlah itu, {rp(d.komisi_tunai)} berasal dari order tunai: penumpang membayar ke driver, lalu bagian kami langsung dipotong dari saldo komisi driver (hasil top up). Yang belum disetor hanya saldo driver yang minus: <b>{rp(utangDriver)}</b>.</li>
                </ul>
              </div>
            </details>

            {/* Tunai belum tentu jadi uang: penumpang membayar ke driver, komisinya
                cuma memotong saldo driver sampai ia menyetor. */}
            {utangDriver > 0 && (
              <div className="card" style={{ marginBottom: 24, display: "flex", gap: 10, alignItems: "flex-start", borderColor: "var(--warning)" }}>
                <AlertTriangle size={18} style={{ color: "var(--warning)", flexShrink: 0, marginTop: 2 }} />
                <div style={{ fontSize: 13, color: "var(--text-secondary)" }}>
                  {rp(utangDriver)} belum disetor: saldo komisi sebagian driver sudah minus karena potongan order tunai melebihi top up mereka.
                  Tekan "Terima setoran" di baris driver itu saat uangnya diterima.
                </div>
              </div>
            )}

            <div className="card">
              <div className="table-header"><h3>{drivers.length} driver · {d.total_order || 0} pesanan selesai</h3></div>
              <table style={{ width: "100%" }}>
                <thead><tr><th>Driver</th><th>Pesanan</th><th>Ongkos Kotor</th><th>Bagian Driver</th><th>Komisi</th><th>Biaya Jasa</th><th title="Bagian kami dari order tunai, dipotong otomatis dari saldo komisi driver">Dipotong dari Saldo</th><th>Saldo Driver</th><th>Setoran</th></tr></thead>
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
                    <tr key={v.driver_phone} onClick={() => setRincian(v)} style={{ cursor: "pointer" }} title="Klik untuk lihat pesanannya">
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
                      <td data-label="Dipotong dari Saldo" style={{ color: "var(--text-secondary)" }}>{rp(v.komisi_tunai)}</td>
                      <td data-label="Saldo Driver" style={{ color: v.saldo_driver < 0 ? "var(--danger)" : "var(--text-secondary)", fontWeight: v.saldo_driver < 0 ? 700 : 400 }}>{rp(v.saldo_driver)}</td>
                      <td data-label="Setoran">
                        {v.saldo_driver < 0 ? (
                          <button className="btn" style={{ fontSize: 12, padding: "6px 10px" }} onClick={(e) => { e.stopPropagation(); mulaiSetoran(v); }}>
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

            {/* Tagihan QR: pemesan membayar warung/rental pakai saldo, potongan
                kami terkunci di tiap tagihan saat dibuat. Dihitung saat dibayar. */}
            {tagihan.length > 0 && (
              <div className="card" style={{ marginTop: 24 }}>
                <div className="table-header"><h3>Tagihan QR mitra · {tagihan.reduce((n, t) => n + t.jumlah, 0)} dibayar · {rp(d.total_tagihan)}</h3></div>
                <table style={{ width: "100%" }}>
                  <thead><tr><th>Mitra</th><th>Tagihan</th><th>Dibayar Pemesan</th><th>Bagian Mitra</th><th>Potongan Kami</th></tr></thead>
                  <tbody>
                    {tagihan.map(t => (
                      <tr key={t.penerima_phone + t.penerima_nama}>
                        <td data-label="Mitra">
                          <div className="user-cell">
                            <div className="user-avatar" style={{ background: "rgba(16,185,129,0.1)", color: "#10B981" }}>{t.penerima_nama?.[0] || "?"}</div>
                            <div><div className="user-name">{t.penerima_nama || "—"}</div><div className="user-sub">{t.penerima_phone}</div></div>
                          </div>
                        </td>
                        <td data-label="Tagihan" style={{ fontWeight: 700 }}>{t.jumlah}</td>
                        <td data-label="Dibayar Pemesan">{rp(t.total)}</td>
                        <td data-label="Bagian Mitra" style={{ color: "var(--text-secondary)" }}>{rp(t.total - t.komisi)}</td>
                        <td data-label="Potongan Kami" style={{ color: "var(--success)", fontWeight: 700 }}>{rp(t.komisi)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </>
        )}

        {rincian && <RincianDriver v={rincian} from={from} to={to} onTutup={() => setRincian(null)} />}

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
