import { useState, useEffect } from "react";
import { Wallet, X } from "lucide-react";
import { api } from "../api";
import { toast } from "./Feedback";

const rupiah = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");
const LABEL = { menunggu: "Diproses admin", selesai: "Ditransfer", ditolak: "Ditolak" };
const WARNA = { menunggu: "#F59E0B", selesai: "var(--success)", ditolak: "var(--danger, #EF4444)" };

/* Saldo mitra dan pencairannya. Saldo ini bertambah dari tagihan QR; sebelum
   kartu ini ada, mitra tidak bisa melihat uangnya, apalagi menariknya.

   Pencairan manual: mitra mengajukan, saldonya langsung dipotong, admin
   mentransfer lalu menandai selesai — atau menolak dan saldonya kembali.
   `versi` dinaikkan induknya setiap ada tagihan yang lunas, supaya saldonya
   ikut terbaca ulang tanpa memuat ulang halaman. */
export default function SaldoMitra({ versi = 0 }) {
  const [saldo, setSaldo] = useState(null);
  const [riwayat, setRiwayat] = useState([]);
  const [form, setForm] = useState(null); // null = tertutup
  const [mengirim, setMengirim] = useState(false);

  const muat = () => {
    api.getProfile().then(d => setSaldo(typeof d?.user?.balance === "number" ? d.user.balance : null));
    api.getPencairan().then(d => setRiwayat(d?.pencairan || []));
  };
  useEffect(() => { muat(); }, [versi]);

  const menunggu = riwayat.find(p => p.status === "menunggu");

  // Rekening diisi dari pengajuan terakhir: hampir selalu rekening yang sama.
  const buka = () => {
    const akhir = riwayat[0];
    setForm({
      amount: "",
      bank: akhir?.bank || "",
      nomor_rekening: akhir?.nomor_rekening || "",
      nama_pemilik: akhir?.nama_pemilik || "",
    });
  };

  const ajukan = async (e) => {
    e.preventDefault();
    setMengirim(true);
    const res = await api.ajukanPencairan({ ...form, amount: Number(String(form.amount).replace(/[^\d]/g, "")) });
    setMengirim(false);
    if (res?.status !== "success") {
      toast.error(res?.error || "Gagal mengajukan pencairan");
      return;
    }
    toast.success("Pengajuan terkirim. Saldo dipotong sekarang; admin akan mentransfer ke rekening Anda.");
    setForm(null);
    muat();
  };

  const isian = (kunci, label, props = {}) => (
    <label style={{ display: "block", marginBottom: 10, textAlign: "left" }}>
      <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 4 }}>{label}</div>
      <input
        className="input" required value={form[kunci]} style={{ width: "100%" }}
        onChange={e => setForm({ ...form, [kunci]: e.target.value })} {...props}
      />
    </label>
  );

  return (
    <>
      <div className="card">
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <Wallet size={28} style={{ color: "var(--primary, #2563EB)" }} />
            <div>
              <div style={{ fontSize: 12, color: "var(--text-secondary)" }}>Saldo Anda</div>
              <div style={{ fontWeight: 800, fontSize: 20 }}>{saldo == null ? "—" : rupiah(saldo)}</div>
            </div>
          </div>
          <button className="btn btn-primary" onClick={buka} disabled={!!menunggu}>
            Cairkan ke rekening
          </button>
        </div>

        {menunggu && (
          <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 10 }}>
            Pencairan {rupiah(menunggu.amount)} ke {menunggu.bank} {menunggu.nomor_rekening} sedang diproses admin.
          </div>
        )}

        {riwayat.length > 0 && (
          <div style={{ marginTop: 12, borderTop: "1px solid var(--border, #E2E8F0)", paddingTop: 10 }}>
            {riwayat.slice(0, 5).map(p => (
              <div key={p.id} style={{ display: "flex", justifyContent: "space-between", gap: 8, fontSize: 12, padding: "4px 0" }}>
                <span>
                  {new Date(p.created_at).toLocaleDateString("id-ID")} · {rupiah(p.amount)}
                  {p.catatan && <span style={{ color: "var(--text-muted)" }}> · {p.catatan}</span>}
                </span>
                <strong style={{ color: WARNA[p.status], whiteSpace: "nowrap" }}>{LABEL[p.status] || p.status}</strong>
              </div>
            ))}
          </div>
        )}
      </div>

      {form && (
        <div
          onClick={() => setForm(null)}
          style={{
            position: "fixed", inset: 0, background: "rgba(15,23,42,0.55)",
            display: "flex", alignItems: "center", justifyContent: "center", zIndex: 50, padding: 20,
          }}
        >
          <form className="card" onClick={e => e.stopPropagation()} onSubmit={ajukan} style={{ maxWidth: 400, width: "100%" }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
              <div style={{ fontWeight: 800 }}>Cairkan saldo</div>
              <button type="button" className="btn" style={{ padding: 6 }} onClick={() => setForm(null)}><X size={15} /></button>
            </div>
            {isian("amount", `Nominal (saldo ${rupiah(saldo)})`, { inputMode: "numeric", placeholder: "Minimal Rp 10.000" })}
            {isian("bank", "Bank atau e-wallet", { placeholder: "BRI, BCA, DANA, ..." })}
            {isian("nomor_rekening", "Nomor rekening", { inputMode: "numeric" })}
            {isian("nama_pemilik", "Nama pemilik rekening")}
            <div style={{ fontSize: 12, color: "var(--text-muted)", margin: "4px 0 12px" }}>
              Saldo langsung dipotong saat diajukan. Kalau admin tidak bisa mentransfer, saldo dikembalikan utuh.
            </div>
            <button className="btn btn-primary" type="submit" disabled={mengirim} style={{ width: "100%" }}>
              {mengirim ? "Mengirim..." : "Ajukan pencairan"}
            </button>
          </form>
        </div>
      )}
    </>
  );
}
