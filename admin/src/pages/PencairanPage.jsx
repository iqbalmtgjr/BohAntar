import { useEffect, useState } from "react";
import { Banknote } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { toast } from "../components/Feedback";

const rp = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");
const PERAN = { driver: "Driver", food_merchant: "Warung", rental_partner: "Rental" };
const TAB = [["menunggu", "Menunggu"], ["selesai", "Sudah ditransfer"], ["ditolak", "Ditolak"]];

/* Pencairan saldo manual. Saldo pemiliknya sudah dipotong saat pengajuan
   masuk, jadi tugas di sini tinggal dua: transfer lalu tandai selesai, atau
   tolak dan saldonya kembali otomatis. Keduanya meminta catatan — nomor
   referensi transfer adalah bukti kalau pemiliknya bertanya. */
export default function PencairanPage() {
  const [status, setStatus] = useState("menunggu");
  const [daftar, setDaftar] = useState([]);
  const [loading, setLoading] = useState(true);
  const [proses, setProses] = useState("");

  const muat = (s) => {
    setLoading(true);
    api.adminPencairan(s).then(d => { setDaftar(d?.pencairan || []); setLoading(false); });
  };
  useEffect(() => { muat(status); }, [status]);

  const tindak = async (p, aksi) => {
    const tanya = aksi === "selesai"
      ? `Sudah mentransfer ${rp(p.amount)} ke ${p.bank} ${p.nomor_rekening} a.n. ${p.nama_pemilik}?\n\nIsi nomor referensi transfer:`
      : `Tolak pencairan ${rp(p.amount)} dari ${p.nama_akun}? Saldonya dikembalikan.\n\nIsi alasan (dibaca pemiliknya):`;
    const catatan = window.prompt(tanya, "");
    if (!catatan || !catatan.trim()) return;
    setProses(p.id);
    const res = await api.prosesPencairan(p.id, aksi, catatan.trim());
    setProses("");
    if (res?.status !== "success") {
      toast.error(res?.error || "Gagal memproses pencairan");
    } else {
      toast.success(res.message);
    }
    muat(status);
  };

  return (
    <>
      <Topbar title="Pencairan Saldo" />
      <div className="page">
        <div className="page-header">
          <h1>Pencairan Saldo</h1>
          <p>Transfer manual ke rekening driver dan mitra. Saldo sudah dipotong saat diajukan.</p>
        </div>

        <div style={{ display: "flex", gap: 8, marginBottom: 16, flexWrap: "wrap" }}>
          {TAB.map(([k, label]) => (
            <button key={k} className={`btn ${status === k ? "btn-primary" : ""}`} onClick={() => setStatus(k)}>{label}</button>
          ))}
        </div>

        <div className="card">
          {loading ? (
            <div className="spinner" style={{ margin: "40px auto" }} />
          ) : daftar.length === 0 ? (
            <div className="empty-state">
              <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                <Banknote size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
              </div>
              <h3>Tidak ada pencairan {TAB.find(t => t[0] === status)[1].toLowerCase()}</h3>
            </div>
          ) : (
            <table style={{ width: "100%" }}>
              <thead>
                <tr>
                  <th>Diajukan</th>
                  <th>Akun</th>
                  <th>Nominal</th>
                  <th>Rekening tujuan</th>
                  {status === "menunggu" ? <th></th> : <th>Catatan</th>}
                </tr>
              </thead>
              <tbody>
                {daftar.map(p => (
                  <tr key={p.id}>
                    <td data-label="Diajukan">{new Date(p.created_at).toLocaleString("id-ID")}</td>
                    <td data-label="Akun">
                      <div style={{ fontWeight: 700 }}>{p.nama_akun}</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{PERAN[p.peran] || p.peran} · {p.phone_number}</div>
                    </td>
                    <td data-label="Nominal" style={{ fontWeight: 700 }}>{rp(p.amount)}</td>
                    <td data-label="Rekening tujuan">
                      <div>{p.bank} {p.nomor_rekening}</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>a.n. {p.nama_pemilik}</div>
                    </td>
                    {status === "menunggu" ? (
                      <td data-label="">
                        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                          <button className="btn btn-primary" disabled={proses === p.id} onClick={() => tindak(p, "selesai")}>Sudah ditransfer</button>
                          <button className="btn" disabled={proses === p.id} onClick={() => tindak(p, "tolak")}>Tolak</button>
                        </div>
                      </td>
                    ) : (
                      <td data-label="Catatan" style={{ fontSize: 12 }}>{p.catatan}</td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </>
  );
}
