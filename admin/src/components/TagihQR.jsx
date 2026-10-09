import { useState, useEffect } from "react";
import { QrCode, X, CheckCircle } from "lucide-react";
import { api } from "../api";
import { toast } from "./Feedback";

const rupiah = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");

/* Tagih pelanggan di tempat: QR dipindai, saldo pelanggan pindah ke saldo
   mitra. Dipakai portal warung dan portal rental — penerimanya diambil backend
   dari token, jadi komponen ini cuma perlu tahu kata untuk menyebut saldonya.

   Tagihan dibuat SESUDAH transaksinya jelas, lalu QR-nya ditunjukkan ke
   pelanggan. Uang berpindah cuma kalau kedua pihak bertindak: kasir memasukkan
   nominal, pelanggan memindai dan menekan bayar. */
export default function TagihQR({ saldoMilik = "warung", warna = "#F59E0B", onLunas }) {
  const [tagihan, setTagihan] = useState(null); // { nominal, komisi, id, qr, lunas }

  const mulai = async () => {
    const isian = window.prompt("Nominal yang harus dibayar pelanggan:", "");
    if (isian === null) return;
    const nominal = Number(String(isian).replace(/[^\d]/g, ""));
    if (!nominal) return;

    const res = await api.buatTagihan(nominal);
    if (!res || res.error) {
      toast.error("Gagal membuat tagihan: " + (res?.error || "tidak diketahui"));
      return;
    }
    const qr = await api.qrTagihan(res.tagihan.id);
    setTagihan({ nominal, komisi: res.tagihan.komisi || 0, id: res.tagihan.id, qr, lunas: false });
  };

  // Selama QR terbuka, statusnya ditanyakan tiap 3 detik supaya kasir tahu
  // pembayarannya masuk — tanpa itu keduanya saling menunggu di depan layar.
  useEffect(() => {
    if (!tagihan || tagihan.lunas) return;
    const t = setInterval(async () => {
      const res = await api.cekTagihan(tagihan.id);
      if (res?.tagihan?.paid_at) setTagihan(s => (s ? { ...s, lunas: true } : s));
    }, 3000);
    return () => clearInterval(t);
  }, [tagihan]);

  const tutup = () => {
    if (tagihan?.qr) URL.revokeObjectURL(tagihan.qr);
    // Saldo di halaman induk dibaca ulang saat jendela yang sudah lunas
    // ditutup — bukan dari dalam polling, supaya callback induk yang berganti
    // tiap render tidak ikut mengulang interval.
    if (tagihan?.lunas) onLunas?.();
    setTagihan(null);
  };

  const diterima = tagihan ? tagihan.nominal - tagihan.komisi : 0;

  return (
    <>
      <div className="card" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
        <div>
          <strong>Tagih pelanggan pakai QR</strong>
          <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 2 }}>
            Masukkan nominal, tunjukkan QR-nya. Saldo pelanggan langsung pindah ke saldo {saldoMilik}.
          </div>
        </div>
        <button className="btn btn-primary" style={{ background: warna }} onClick={mulai}>
          <QrCode size={16} /> Buat tagihan
        </button>
      </div>

      {tagihan && (
        <div
          onClick={tutup}
          style={{
            position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)",
            display: "flex", alignItems: "center", justifyContent: "center", zIndex: 50, padding: 20,
          }}
        >
          <div className="card" onClick={e => e.stopPropagation()} style={{ maxWidth: 380, width: "100%", textAlign: "center" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
              <div style={{ fontWeight: 800 }}>{tagihan.lunas ? "Pembayaran diterima" : "Minta pelanggan memindai"}</div>
              <button className="btn" style={{ padding: 6 }} onClick={tutup}><X size={15} /></button>
            </div>

            {tagihan.lunas ? (
              <div style={{ padding: "24px 0" }}>
                <CheckCircle size={56} style={{ color: "var(--success)" }} />
                <div style={{ marginTop: 12, fontWeight: 700 }}>{rupiah(diterima)} masuk ke saldo {saldoMilik}</div>
              </div>
            ) : (
              <>
                <img src={tagihan.qr} alt="QR tagihan" style={{ width: 240, height: 240, margin: "8px auto", display: "block" }} />
                <div style={{ fontWeight: 800, fontSize: 18 }}>{rupiah(tagihan.nominal)}</div>
                {/* Potongan disebut di muka, bukan baru ketahuan di saldo. */}
                {tagihan.komisi > 0 && (
                  <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>
                    Anda menerima {rupiah(diterima)} (potongan bohAntar {rupiah(tagihan.komisi)})
                  </div>
                )}
                <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 10 }}>
                  Berlaku 15 menit dan hanya bisa dibayar sekali. Jangan tutup jendela ini sebelum pelanggan memindai.
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
}
