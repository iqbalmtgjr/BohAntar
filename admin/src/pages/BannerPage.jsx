import { useEffect, useState } from "react";
import { Plus, Pencil, Trash2, X, Eye, EyeOff, ImagePlus } from "lucide-react";
import { api, fileURL } from "../api";
import Topbar from "../components/Topbar";
import { toast, confirmDialog, Alert } from "../components/Feedback";
import ikonRide from "../assets/layanan/layanan_bohride.png";
import ikonCar from "../assets/layanan/layanan_bohcar.png";
import ikonFood from "../assets/layanan/layanan_bohfood.png";
import ikonSend from "../assets/layanan/layanan_bohsend.png";

/* Banner beranda aplikasi: spanduk geser di belakang kartu BohPay.
   Banner tanpa gambar digambar aplikasi dari judul, keterangan, dan warna —
   pratinjau di sini meniru gambarnya. Banner bergambar dipasang apa adanya.
   Warna dan ilustrasi WAJIB sama dengan mobile/lib/widgets/banner_beranda.dart. */

const WARNA = {
  biru: ["#0B5CD5", "#3B8BFF"],
  oranye: ["#C2410C", "#F97316"],
  hijau: ["#047857", "#10B981"],
  ungu: ["#5B21B6", "#8B5CF6"],
  merah: ["#B91C1C", "#EF4444"],
  gelap: ["#0F172A", "#334155"],
};
const TUJUAN = [
  ["", "Tidak membuka apa pun"],
  ["BohRide", "BohRide"],
  ["BohCar", "BohCar"],
  ["BohFood", "BohFood"],
  ["BohSend", "BohSend"],
  ["url", "Tautan (https://…)"],
];
const IKON = { BohRide: ikonRide, BohCar: ikonCar, BohFood: ikonFood, BohSend: ikonSend };
const KOSONG = { judul: "", keterangan: "", label_tombol: "", tujuan: "", url: "", warna: "biru", gambar_url: "", aktif: true, urutan: 0 };

// Sebanding dengan aplikasi: banner setinggi 200 dp selebar layar (±2:1 di HP
// biasa), dan kartu BohPay menutup ±17% bagian bawahnya.
function PratinjauBanner({ b }) {
  const [gelap, terang] = WARNA[b.warna] || WARNA.biru;
  const ikon = IKON[b.tujuan];
  return (
    <div
      style={{
        position: "relative", width: "100%", maxWidth: 380, aspectRatio: "2 / 1", borderRadius: 14, overflow: "hidden",
        background: b.gambar_url ? `center / cover no-repeat url("${fileURL(b.gambar_url)}")` : `linear-gradient(90deg, ${gelap}, ${terang})`,
      }}
    >
      {!b.gambar_url && (
        <>
          {ikon && <img src={ikon} alt="" style={{ position: "absolute", right: 4, top: "6%", height: "68%" }} />}
          <div style={{ position: "absolute", left: 16, top: 14, right: ikon ? "38%" : 16, color: "#fff" }}>
            <div style={{ fontWeight: 900, fontSize: 16, lineHeight: 1.2 }}>{b.judul || "Judul banner"}</div>
            {b.keterangan && <div style={{ fontSize: 11, marginTop: 4, lineHeight: 1.35 }}>{b.keterangan}</div>}
            {b.label_tombol && b.tujuan && (
              <span style={{ display: "inline-block", marginTop: 8, background: "#fff", color: gelap, fontWeight: 800, fontSize: 10.5, padding: "4px 10px", borderRadius: 20 }}>
                {b.label_tombol} ›
              </span>
            )}
          </div>
        </>
      )}
      <div
        style={{
          position: "absolute", left: 12, right: 12, bottom: -8, height: "26%", background: "rgba(255,255,255,0.94)",
          borderRadius: 12, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 10, color: "#64748B", fontWeight: 700,
        }}
      >
        Kartu BohPay menutup bagian ini
      </div>
    </div>
  );
}

export default function BannerPage() {
  const [daftar, setDaftar] = useState(null);
  const [form, setForm] = useState(null); // null = modal tertutup
  const [galat, setGalat] = useState("");
  const [sibuk, setSibuk] = useState(false);

  const muat = () =>
    api.getBanner()
      .then((res) => (res.status === "success" ? setDaftar(res.banner) : toast.error(res.error || "Gagal memuat banner")))
      .catch(() => toast.error("Gagal memuat banner"));
  useEffect(() => { muat(); }, []);

  const ubah = (kunci) => (e) => setForm({ ...form, [kunci]: e.target.type === "checkbox" ? e.target.checked : e.target.value });

  const simpan = async (b) => {
    const res = await api.simpanBanner({ ...b, urutan: Number(b.urutan) || 0 });
    if (res.status !== "success") throw new Error(res.error || "Gagal menyimpan banner");
    await muat();
  };

  const kirimForm = async (e) => {
    e.preventDefault();
    setSibuk(true);
    setGalat("");
    try {
      await simpan(form);
      toast.success("Banner tersimpan. Beranda aplikasi memakainya saat dibuka lagi.");
      setForm(null);
    } catch (err) {
      setGalat(err.message);
    } finally {
      setSibuk(false);
    }
  };

  const unggah = async (e) => {
    const berkas = e.target.files?.[0];
    e.target.value = "";
    if (!berkas) return;
    setSibuk(true);
    const res = await api.uploadFile(berkas).catch(() => ({}));
    setSibuk(false);
    if (res.status !== "success") return setGalat(res.error || "Gambar gagal diunggah");
    setForm((f) => ({ ...f, gambar_url: res.url }));
  };

  const alihAktif = async (b) => {
    try {
      await simpan({ ...b, aktif: !b.aktif });
      toast.success(b.aktif ? "Banner disembunyikan dari aplikasi" : "Banner tampil di aplikasi");
    } catch (err) {
      toast.error(err.message);
    }
  };

  const hapus = async (b) => {
    const yakin = await confirmDialog({ title: "Hapus banner?", message: `"${b.judul}" hilang dari beranda aplikasi.`, confirmText: "Hapus" });
    if (!yakin) return;
    const res = await api.hapusBanner(b.id);
    if (res.status !== "success") return toast.error(res.error || "Gagal menghapus banner");
    toast.success("Banner dihapus");
    muat();
  };

  return (
    <>
      <Topbar title="Banner Beranda" />
      <div className="page">
        <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12, flexWrap: "wrap" }}>
          <div>
            <h1>Banner Beranda</h1>
            <p>Spanduk geser di beranda aplikasi pelanggan, tepat di belakang kartu BohPay. Diurutkan dari angka urutan terkecil.</p>
          </div>
          <button className="btn btn-primary" onClick={() => { setGalat(""); setForm({ ...KOSONG }); }}>
            <Plus size={16} /> Tambah banner
          </button>
        </div>

        {daftar && daftar.length === 0 && (
          <div className="card">Belum ada banner. Aplikasi menampilkan banner bawaan "Tanpa tarif tambahan di BohFood" sampai ada banner aktif.</div>
        )}

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))", gap: 16 }}>
          {(daftar || []).map((b) => (
            <div key={b.id} className="card" style={{ opacity: b.aktif ? 1 : 0.6 }}>
              <PratinjauBanner b={b} />
              <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 12, flexWrap: "wrap" }}>
                <span className={`badge ${b.aktif ? "badge-success" : "badge-muted"}`}>{b.aktif ? "Tampil" : "Disembunyikan"}</span>
                <span className="badge badge-muted">Urutan {b.urutan}</span>
                {b.tujuan && <span className="badge badge-primary">→ {b.tujuan === "url" ? "Tautan" : b.tujuan}</span>}
              </div>
              <div style={{ fontWeight: 700, marginTop: 8 }}>{b.judul}</div>
              <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
                <button className="btn btn-ghost btn-sm" onClick={() => { setGalat(""); setForm({ ...b }); }}><Pencil size={14} /> Ubah</button>
                <button className="btn btn-ghost btn-sm" onClick={() => alihAktif(b)}>
                  {b.aktif ? <><EyeOff size={14} /> Sembunyikan</> : <><Eye size={14} /> Tampilkan</>}
                </button>
                <button className="btn btn-danger btn-sm" onClick={() => hapus(b)} aria-label="Hapus banner"><Trash2 size={14} /></button>
              </div>
            </div>
          ))}
        </div>
      </div>

      {form && (
        <div className="modal-overlay" onClick={() => !sibuk && setForm(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 560, position: "relative" }}>
            <button onClick={() => setForm(null)} aria-label="Tutup" style={{ position: "absolute", top: 16, right: 16, background: "none", border: "none", cursor: "pointer", color: "var(--text-muted)" }}>
              <X size={18} />
            </button>
            <h2>{form.id ? "Ubah banner" : "Banner baru"}</h2>
            <p className="modal-desc">Pratinjau di bawah mengikuti tampilan di aplikasi.</p>
            <div style={{ marginBottom: 18 }}><PratinjauBanner b={form} /></div>

            <form onSubmit={kirimForm}>
              <div className="input-group">
                <label>Judul (wajib)</label>
                <input className="input" value={form.judul} onChange={ubah("judul")} maxLength={80} required placeholder="Mis. Tanpa tarif tambahan di BohFood" />
              </div>
              <div className="input-group">
                <label>Keterangan</label>
                <input className="input" value={form.keterangan} onChange={ubah("keterangan")} maxLength={160} placeholder="Satu kalimat pendek" />
              </div>
              <div className="grid-2">
                <div className="input-group">
                  <label>Saat diketuk, buka</label>
                  <select className="input" value={form.tujuan} onChange={ubah("tujuan")}>
                    {TUJUAN.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                  </select>
                </div>
                <div className="input-group">
                  <label>Tulisan tombol</label>
                  <input className="input" value={form.label_tombol} onChange={ubah("label_tombol")} maxLength={30} placeholder="Mis. Pesan makanan" disabled={!form.tujuan} />
                </div>
              </div>
              {form.tujuan === "url" && (
                <div className="input-group">
                  <label>Tautan</label>
                  <input className="input" value={form.url} onChange={ubah("url")} placeholder="https://…" required />
                </div>
              )}

              <div className="input-group">
                <label>Warna (untuk banner tanpa gambar)</label>
                <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                  {Object.entries(WARNA).map(([nama, [a, z]]) => (
                    <button
                      key={nama} type="button" onClick={() => setForm({ ...form, warna: nama })} aria-label={nama} title={nama}
                      style={{
                        width: 36, height: 36, borderRadius: 10, cursor: "pointer", background: `linear-gradient(135deg, ${a}, ${z})`,
                        border: form.warna === nama ? "3px solid var(--text-primary)" : "3px solid transparent",
                      }}
                    />
                  ))}
                </div>
              </div>

              <div className="input-group">
                <label>Gambar sendiri (opsional)</label>
                <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
                  <label className="btn btn-ghost btn-sm" style={{ cursor: "pointer", marginBottom: 0 }}>
                    <ImagePlus size={14} /> {form.gambar_url ? "Ganti gambar" : "Unggah gambar"}
                    <input type="file" accept="image/png,image/jpeg,image/webp" onChange={unggah} hidden />
                  </label>
                  {form.gambar_url && (
                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => setForm({ ...form, gambar_url: "" })}>Pakai warna saja</button>
                  )}
                </div>
                <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 6 }}>
                  Ukuran 1200×600 px (2:1), maks. 5 MB. Gambar menggantikan judul &amp; warna — tulis teksnya di gambar.
                  Jangan taruh tulisan penting di ±20% bagian bawah: di aplikasi tertutup kartu BohPay.
                </div>
              </div>

              <div className="grid-2">
                <div className="input-group">
                  <label>Urutan</label>
                  <input className="input" type="number" min="0" max="999" value={form.urutan} onChange={ubah("urutan")} />
                </div>
                <div className="input-group">
                  <label>&nbsp;</label>
                  <label style={{ display: "flex", alignItems: "center", gap: 8, fontWeight: 600, fontSize: 13, cursor: "pointer" }}>
                    <input type="checkbox" checked={form.aktif} onChange={ubah("aktif")} /> Tampilkan di aplikasi
                  </label>
                </div>
              </div>

              {galat && <Alert type="error">{galat}</Alert>}
              <div className="modal-footer">
                <button type="button" className="btn btn-ghost" onClick={() => setForm(null)} disabled={sibuk}>Batal</button>
                <button type="submit" className="btn btn-primary" disabled={sibuk}>{sibuk ? "Menyimpan…" : "Simpan banner"}</button>
              </div>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
