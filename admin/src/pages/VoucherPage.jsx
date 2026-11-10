import { useEffect, useState } from "react";
import { Plus, Pencil, Trash2, X, Eye, EyeOff } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";
import { toast, confirmDialog, Alert } from "../components/Feedback";

/* Voucher diskon: terpakai OTOMATIS di aplikasi, tanpa kode. Kalau beberapa
   voucher cocok untuk satu pesanan, yang diskonnya terbesar yang dipakai.
   Diskon ditanggung BohAntar — potongan saldo driver ikut berkurang sebesar
   diskonnya, jadi pendapatan driver tidak berubah (backend/voucher.go). */

const LAYANAN = [
  ["", "Semua layanan"],
  ["BohRide", "BohRide"],
  ["BohCar", "BohCar"],
  ["BohFood", "BohFood"],
  ["BohSend", "BohSend"],
];
const KOSONG = { judul: "", layanan: "", jenis: "nominal", nilai: "", maks_diskon: "", min_belanja: "", kuota: "", per_pengguna: 1, mulai: "", selesai: "", aktif: true };
const rp = (n) => "Rp" + Math.round(n || 0).toLocaleString("id-ID");
const hariIni = () => new Date().toLocaleDateString("sv-SE"); // YYYY-MM-DD waktu lokal

function besarDiskon(v) {
  if (v.jenis === "persen") return `${v.nilai}%${v.maks_diskon > 0 ? ` maks. ${rp(v.maks_diskon)}` : ""}`;
  return rp(v.nilai);
}

function status(v) {
  if (!v.aktif) return ["Nonaktif", "badge-muted"];
  if (v.selesai && v.selesai < hariIni()) return ["Berakhir", "badge-muted"];
  if (v.mulai && v.mulai > hariIni()) return ["Terjadwal", "badge-primary"];
  if (v.kuota > 0 && v.terpakai >= v.kuota) return ["Kuota habis", "badge-muted"];
  return ["Berlaku", "badge-success"];
}

export default function VoucherPage() {
  const [daftar, setDaftar] = useState(null);
  const [form, setForm] = useState(null); // null = modal tertutup
  const [galat, setGalat] = useState("");
  const [sibuk, setSibuk] = useState(false);

  const muat = () =>
    api.getVoucher()
      .then((res) => (res.status === "success" ? setDaftar(res.voucher) : toast.error(res.error || "Gagal memuat voucher")))
      .catch(() => toast.error("Gagal memuat voucher"));
  useEffect(() => { muat(); }, []);

  const ubah = (kunci) => (e) => setForm({ ...form, [kunci]: e.target.type === "checkbox" ? e.target.checked : e.target.value });

  const simpan = async (v) => {
    const angka = (x) => Number(x) || 0;
    const res = await api.simpanVoucher({
      ...v, nilai: angka(v.nilai), maks_diskon: angka(v.maks_diskon), min_belanja: angka(v.min_belanja),
      kuota: angka(v.kuota), per_pengguna: angka(v.per_pengguna),
    });
    if (res.status !== "success") throw new Error(res.error || "Gagal menyimpan voucher");
    await muat();
  };

  const kirimForm = async (e) => {
    e.preventDefault();
    setSibuk(true);
    setGalat("");
    try {
      await simpan(form);
      toast.success("Voucher tersimpan. Pesanan berikutnya langsung memakainya.");
      setForm(null);
    } catch (err) {
      setGalat(err.message);
    } finally {
      setSibuk(false);
    }
  };

  const alihAktif = async (v) => {
    try {
      await simpan({ ...v, aktif: !v.aktif });
      toast.success(v.aktif ? "Voucher dinonaktifkan" : "Voucher diaktifkan");
    } catch (err) {
      toast.error(err.message);
    }
  };

  const hapus = async (v) => {
    const yakin = await confirmDialog({ title: "Hapus voucher?", message: `"${v.judul}" tidak dipakai lagi. Diskon pesanan yang sudah terjadi tetap tercatat.`, confirmText: "Hapus" });
    if (!yakin) return;
    const res = await api.hapusVoucher(v.id);
    if (res.status !== "success") return toast.error(res.error || "Gagal menghapus voucher");
    toast.success("Voucher dihapus");
    muat();
  };

  return (
    <>
      <Topbar title="Voucher Diskon" />
      <div className="page">
        <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, flexWrap: "wrap" }}>
          <div>
            <h1>Voucher Diskon</h1>
            <p>Terpakai otomatis saat pelanggan memesan — tanpa kode. Satu pesanan satu voucher, yang diskonnya terbesar. Diskon ditanggung BohAntar, pendapatan driver tetap.</p>
          </div>
          <button className="btn btn-primary" onClick={() => { setGalat(""); setForm({ ...KOSONG }); }}>
            <Plus size={16} /> Tambah voucher
          </button>
        </div>

        {daftar && daftar.length === 0 && <div className="card">Belum ada voucher. Pelanggan membayar harga penuh.</div>}

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))", gap: 16 }}>
          {(daftar || []).map((v) => {
            const [label, kelas] = status(v);
            return (
              <div key={v.id} className="card" style={{ opacity: label === "Berlaku" || label === "Terjadwal" ? 1 : 0.6 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                  <span className={`badge ${kelas}`}>{label}</span>
                  <span className="badge badge-muted">{v.layanan || "Semua layanan"}</span>
                </div>
                <div style={{ fontWeight: 800, fontSize: 22, marginTop: 10 }}>{besarDiskon(v)}</div>
                <div style={{ fontWeight: 700, marginTop: 2 }}>{v.judul}</div>
                <div style={{ fontSize: 13, color: "var(--text-muted)", marginTop: 6, lineHeight: 1.6 }}>
                  {v.min_belanja > 0 && <div>Min. belanja {rp(v.min_belanja)}</div>}
                  <div>{v.mulai || v.selesai ? `${v.mulai || "sekarang"} s.d. ${v.selesai || "tanpa batas"}` : "Tanpa batas waktu"}</div>
                  <div>Terpakai {v.terpakai}{v.kuota > 0 ? ` / ${v.kuota}` : ""} · {v.per_pengguna > 0 ? `${v.per_pengguna}× per pelanggan` : "tanpa batas per pelanggan"}</div>
                </div>
                <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
                  <button className="btn btn-ghost btn-sm" onClick={() => { setGalat(""); setForm({ ...v }); }}><Pencil size={14} /> Ubah</button>
                  <button className="btn btn-ghost btn-sm" onClick={() => alihAktif(v)}>
                    {v.aktif ? <><EyeOff size={14} /> Nonaktifkan</> : <><Eye size={14} /> Aktifkan</>}
                  </button>
                  <button className="btn btn-danger btn-sm" onClick={() => hapus(v)} aria-label="Hapus voucher"><Trash2 size={14} /></button>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      {form && (
        <div className="modal-overlay" onClick={() => !sibuk && setForm(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 560, position: "relative" }}>
            <button onClick={() => setForm(null)} aria-label="Tutup" style={{ position: "absolute", top: 16, right: 16, background: "none", border: "none", cursor: "pointer", color: "var(--text-muted)" }}>
              <X size={18} />
            </button>
            <h2>{form.id ? "Ubah voucher" : "Voucher baru"}</h2>
            <p className="modal-desc">Di aplikasi tampil sebagai "Diskon {form.judul || "…"}" di rincian harga.</p>

            <form onSubmit={kirimForm}>
              <div className="input-group">
                <label>Nama voucher (wajib)</label>
                <input className="input" value={form.judul} onChange={ubah("judul")} maxLength={80} required placeholder="Mis. Promo Akhir Pekan" />
              </div>
              <div className="grid-2">
                <div className="input-group">
                  <label>Berlaku untuk</label>
                  <select className="input" value={form.layanan} onChange={ubah("layanan")}>
                    {LAYANAN.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                  </select>
                </div>
                <div className="input-group">
                  <label>Jenis diskon</label>
                  <select className="input" value={form.jenis} onChange={ubah("jenis")}>
                    <option value="nominal">Potongan rupiah</option>
                    <option value="persen">Persen</option>
                  </select>
                </div>
              </div>
              <div className="grid-2">
                <div className="input-group">
                  <label>{form.jenis === "persen" ? "Besar diskon (%)" : "Besar potongan (Rp)"}</label>
                  <input className="input" type="number" min="1" max={form.jenis === "persen" ? 100 : undefined} step="any" value={form.nilai} onChange={ubah("nilai")} required />
                </div>
                {form.jenis === "persen" && (
                  <div className="input-group">
                    <label>Maks. potongan (Rp, 0 = tanpa batas)</label>
                    <input className="input" type="number" min="0" value={form.maks_diskon} onChange={ubah("maks_diskon")} />
                  </div>
                )}
              </div>
              <div className="input-group">
                <label>Min. belanja (Rp)</label>
                <input className="input" type="number" min="0" value={form.min_belanja} onChange={ubah("min_belanja")} placeholder="0" />
                <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 6 }}>
                  Dibanding total sebelum diskon: ongkos + biaya jasa (+ makanan untuk BohFood). Diskon dihitung dari total yang sama,
                  tapi paling besar sebesar ongkos + biaya jasa — uang makanan BohFood sudah ditalangi driver ke warung, jadi tidak ikut dipotong.
                </div>
              </div>
              <div className="grid-2">
                <div className="input-group">
                  <label>Kuota total (0 = tanpa batas)</label>
                  <input className="input" type="number" min="0" value={form.kuota} onChange={ubah("kuota")} placeholder="0" />
                </div>
                <div className="input-group">
                  <label>Per pelanggan (0 = tanpa batas)</label>
                  {/* Wajib: dikosongkan = 0 = tanpa batas, terlalu mudah terjadi tanpa sengaja. */}
                  <input className="input" type="number" min="0" value={form.per_pengguna} onChange={ubah("per_pengguna")} required />
                </div>
              </div>
              <div className="grid-2">
                <div className="input-group">
                  <label>Mulai (kosong = sekarang)</label>
                  <input className="input" type="date" value={form.mulai} onChange={ubah("mulai")} />
                </div>
                <div className="input-group">
                  <label>Selesai (kosong = tanpa batas)</label>
                  <input className="input" type="date" value={form.selesai} min={form.mulai || undefined} onChange={ubah("selesai")} />
                </div>
              </div>
              <label style={{ display: "flex", alignItems: "center", gap: 8, fontWeight: 600, fontSize: 13, cursor: "pointer", marginBottom: 12 }}>
                <input type="checkbox" checked={form.aktif} onChange={ubah("aktif")} /> Aktif
              </label>

              {galat && <Alert type="error">{galat}</Alert>}
              <div className="modal-footer">
                <button type="button" className="btn btn-ghost" onClick={() => setForm(null)} disabled={sibuk}>Batal</button>
                <button type="submit" className="btn btn-primary" disabled={sibuk}>{sibuk ? "Menyimpan…" : "Simpan voucher"}</button>
              </div>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
