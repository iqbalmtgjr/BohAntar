import { useState, useEffect } from "react";
import { CreditCard, Calendar, Clock, CheckCircle, AlertTriangle, ExternalLink, ShieldCheck } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { Alert } from "../../components/Feedback";

export default function Subscription({ ownerPhone }) {
  const [sub, setSub] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [loading, setLoading] = useState(true);
  const [paying, setPaying] = useState(false);
  const [error, setError] = useState("");

  const fetchSubscriptionData = () => {
    setLoading(true);
    Promise.all([
      authFetch(`${BASE}/subscription/status?phone=${encodeURIComponent(ownerPhone)}`).then(r => {
        if (!r.ok) throw new Error("Gagal mengambil status langganan");
        return r.json();
      }),
      authFetch(`${BASE}/subscription/invoices?phone=${encodeURIComponent(ownerPhone)}`).then(r => {
        if (!r.ok) throw new Error("Gagal mengambil riwayat tagihan");
        return r.json();
      })
    ])
      .then(([subData, invData]) => {
        setSub(subData);
        setInvoices(Array.isArray(invData) ? invData : []);
        setLoading(false);
      })
      .catch(err => {
        console.error(err);
        setError(err.message || "Terjadi kesalahan koneksi");
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchSubscriptionData();
  }, [ownerPhone]);

  const handleSubscribe = () => {
    setPaying(true);
    setError("");
    authFetch(`${BASE}/subscription/create`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ phone: ownerPhone })
    })
      .then(r => r.json())
      .then(data => {
        setPaying(false);
        if (data.payment_url) {
          window.location.href = data.payment_url;
        } else {
          setError(data.error || "Gagal membuat link pembayaran");
        }
      })
      .catch(err => {
        console.error(err);
        setError("Gagal menghubungi server pembayaran");
        setPaying(false);
      });
  };

  if (loading) {
    return <div className="page"><div className="spinner" style={{ margin: "100px auto" }}></div></div>;
  }

  const getRemainingDays = (dateStr) => {
    if (!dateStr) return 0;
    const diff = new Date(dateStr) - new Date();
    const days = Math.ceil(diff / (1000 * 60 * 60 * 24));
    return days > 0 ? days : 0;
  };

  const remainingDays = sub ? getRemainingDays(sub.valid_until) : 0;
  const formattedExpiry = sub ? new Date(sub.valid_until).toLocaleDateString("id-ID", {
    weekday: "long",
    year: "numeric",
    month: "long",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  }) : "";

  return (
    <div className="page">
      <div className="page-header">
        <h1>Langganan & Penagihan</h1>
        <p>Kelola lisensi penggunaan SaaS bohRental Anda</p>
      </div>

      <Alert type="error" style={{ marginBottom: 24 }}>{error}</Alert>

      {sub && (
        <div style={{
          display: "grid",
          gridTemplateColumns: "1fr",
          gap: 24,
          marginBottom: 32
        }}>
          <div style={{
            background: "var(--bg-card, white)",
            padding: "clamp(18px, 4vw, 32px)",
            borderRadius: 16,
            boxShadow: "0 4px 6px -1px rgba(0,0,0,0.05)",
            border: "1px solid var(--border)",
            display: "flex",
            flexDirection: "column",
            justifyContent: "space-between",
            position: "relative",
            overflow: "hidden"
          }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, flexWrap: "wrap" }}>
              <div>
                <div style={{ fontSize: 13, textTransform: "uppercase", letterSpacing: 1.5, color: "var(--text-secondary)", fontWeight: 700 }}>
                  Paket Penggunaan
                </div>
                <div style={{ fontSize: "clamp(20px, 5vw, 28px)", fontWeight: 800, marginTop: 8, color: "var(--text-primary)" }}>
                  SaaS bohRental Partner
                </div>
                <div style={{ fontSize: 14, color: "var(--text-secondary)", marginTop: 8 }}>
                  Masa aktif berlaku sampai: <strong style={{ color: "var(--text-primary)" }}>{formattedExpiry}</strong>
                </div>
              </div>

              <div className={`badge`} style={{
                fontSize: 14,
                padding: "8px 16px",
                borderRadius: 50,
                fontWeight: 700,
                background: sub.status === "ACTIVE" ? "rgba(16, 185, 129, 0.1)" : sub.status === "TRIAL" ? "rgba(59, 130, 246, 0.1)" : "rgba(239, 68, 68, 0.1)",
                color: sub.status === "ACTIVE" ? "#10B981" : sub.status === "TRIAL" ? "#3B82F6" : "#EF4444",
                border: "none"
              }}>
                {sub.status === "ACTIVE" ? "AKTIF" : sub.status === "TRIAL" ? "Masa Percobaan" : "EXPIRED"}
              </div>
            </div>

            <div style={{
              display: "flex",
              alignItems: "center",
              gap: 16,
              flexWrap: "wrap",
              background: "var(--bg-input)",
              padding: "16px clamp(14px, 3vw, 24px)",
              borderRadius: 12,
              marginTop: 24,
              border: "1px solid var(--border)"
            }}>
              {sub.status === "ACTIVE" || sub.status === "TRIAL" ? (
                <ShieldCheck size={36} style={{ color: "#10B981", flexShrink: 0 }} />
              ) : (
                <AlertTriangle size={36} style={{ color: "#EF4444", flexShrink: 0 }} />
              )}
              <div>
                <div style={{ fontSize: 15, fontWeight: 700, color: "var(--text-primary)" }}>
                  {sub.status === "ACTIVE" && `Sisa Masa Aktif Anda: ${remainingDays} Hari lagi`}
                  {sub.status === "TRIAL" && `Sisa Masa Percobaan Gratis: ${remainingDays} Hari lagi`}
                  {sub.status === "EXPIRED" && `Masa Aktif Layanan Anda Sudah Habis`}
                </div>
                <div style={{ fontSize: 13, color: "var(--text-muted)", marginTop: 2 }}>
                  {sub.status === "ACTIVE" && "Layanan berjalan normal. Terima kasih atas dukungan Anda!"}
                  {sub.status === "TRIAL" && "Gunakan masa percobaan untuk mencoba seluruh fitur. Anda bisa melakukan perpanjangan kapan saja."}
                  {sub.status === "EXPIRED" && "Sistem dibekukan. Silakan lakukan perpanjangan langganan untuk membuka kembali pemblokiran armada dan reservasi."}
                </div>
              </div>
            </div>

            <div style={{ marginTop: 24, display: "flex", justifyContent: "flex-end" }}>
              <button
                disabled={paying}
                onClick={handleSubscribe}
                className="btn btn-primary"
                style={{
                  padding: "14px 24px",
                  borderRadius: 10,
                  fontSize: 14,
                  fontWeight: 700,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 8,
                  width: "100%",
                  maxWidth: 380,
                  cursor: paying ? "not-allowed" : "pointer"
                }}
              >
                <CreditCard size={18} />
                {paying ? "Menyiapkan Pembayaran..." : sub.status === "EXPIRED" ? "Perpanjang Layanan (Rp 100.000 / bln)" : "Perpanjang Masa Aktif (Rp 100.000 / bln)"}
              </button>
            </div>
          </div>
        </div>
      )}

      <div className="table-wrap">
        <div className="table-header">
          <h3>Riwayat Tagihan Pembayaran</h3>
        </div>
        <table>
          <thead>
            <tr>
              <th>ID Invoice</th>
              <th>Tanggal Penagihan</th>
              <th>Jumlah Pembayaran</th>
              <th>Status</th>
              <th>Aksi</th>
            </tr>
          </thead>
          <tbody>
            {invoices.length === 0 ? (
              <tr>
                <td colSpan="5" style={{ textAlign: "center", color: "var(--text-muted)", padding: 40 }}>
                  Belum ada riwayat tagihan penagihan.
                </td>
              </tr>
            ) : (
              invoices.map(inv => (
                <tr key={inv.id}>
                  <td data-label="ID Invoice"><strong style={{ fontFamily: "monospace", fontSize: 13 }}>{inv.id}</strong></td>
                  <td data-label="Tanggal">
                    {new Date(inv.created_at).toLocaleDateString("id-ID", {
                      year: "numeric",
                      month: "long",
                      day: "numeric"
                    })}
                  </td>
                  <td data-label="Jumlah"><strong>Rp {inv.amount.toLocaleString("id-ID")}</strong></td>
                  <td data-label="Status">
                    <span className={`badge ${
                      inv.status === "PAID" ? "badge-success" :
                      inv.status === "PENDING" ? "badge-warning" : "badge-danger"
                    }`}>
                      {inv.status === "PAID" ? "LUNAS" : inv.status}
                    </span>
                  </td>
                  <td data-label="Aksi">
                    {inv.status === "PENDING" ? (
                      <a
                        href={inv.payment_url}
                        className="btn btn-success btn-sm"
                        style={{
                          display: "inline-flex",
                          alignItems: "center",
                          gap: 4,
                          padding: "6px 12px",
                          borderRadius: 6,
                          textDecoration: "none",
                          fontSize: 12
                        }}
                      >
                        Bayar Sekarang <ExternalLink size={12} />
                      </a>
                    ) : (
                      <span style={{ color: "var(--text-muted)", fontSize: 12 }}>Selesai</span>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
