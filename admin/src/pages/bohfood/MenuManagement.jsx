import { useState, useEffect } from "react";
import {
  Plus, Trash2, Salad, Search, Pencil, ChevronUp, ChevronDown, Layers, Tags,
  UtensilsCrossed, X, ImagePlus, Ban, CheckCircle2, EyeOff, Eye,
  FileSpreadsheet, Download, Upload, AlertTriangle,
} from "lucide-react";
import { BASE, authFetch, api, fileURL } from "../../api";
import { hargaMulaiDari, hargaBisaNaik } from "./harga";
import { toast, confirmDialog } from "../../components/Feedback";

/* Kelola menu warung BohFood, setara halaman Kasvo: tab Menu (status aktif =
   tampil di aplikasi, tandai habis = tampil abu-abu & tak bisa dipesan),
   Kategori (urutan = urutan di aplikasi, bisa dimatikan), dan Varian (grup
   pilihan yang dipakai bersama banyak menu). Aturan simpannya di
   backend/menu_warung.go. Toko Kasvo hanya melihat: menunya diatur di Kasvo. */

const urlFoto = (u) => (u && u.startsWith("/uploads/") ? fileURL(u) : u);
const rp = (n) => "Rp" + Math.round(n || 0).toLocaleString("id-ID");
const TANPA_KATEGORI = "Tanpa kategori";
const aturanGrup = (g) =>
  g.tipe === "single"
    ? `Pilih 1 · ${g.wajib ? "wajib" : "opsional"}`
    : `Pilih beberapa · ${g.wajib ? `wajib min ${g.min || 1}` : "opsional"}${g.max ? ` · maks ${g.max}` : ""}`;
const galatDari = (res, cadangan) => (res && res.error) || (!res ? cadangan : "");

function Sakelar({ checked, onChange, label, disabled }) {
  return (
    <label className="switch" title={label}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} aria-label={label} />
      <span />
    </label>
  );
}

function Modal({ judul, sub, onTutup, lebar = 560, children, footer }) {
  useEffect(() => {
    const esc = (e) => e.key === "Escape" && onTutup();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onTutup]);
  return (
    <div className="modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && onTutup()}>
      <div className="modal" style={{ maxWidth: lebar, padding: 0, display: "flex", flexDirection: "column" }} role="dialog" aria-modal="true" aria-label={judul}>
        <div style={{ display: "flex", alignItems: "flex-start", gap: 12, padding: "20px 24px 12px" }}>
          <div style={{ flex: 1 }}>
            <h2>{judul}</h2>
            {sub && <p className="modal-desc" style={{ marginBottom: 0 }}>{sub}</p>}
          </div>
          <button type="button" className="btn btn-ghost btn-sm" onClick={onTutup} aria-label="Tutup" style={{ padding: 6 }}><X size={18} /></button>
        </div>
        <div style={{ padding: "8px 24px", overflowY: "auto", flex: 1 }}>{children}</div>
        <div className="modal-footer" style={{ padding: "14px 24px 20px", marginTop: 0, borderTop: "1px solid var(--border)" }}>{footer}</div>
      </div>
    </div>
  );
}

// ====================== MENU ======================

function FormMenu({ awal, merchantId, kategori, grup, onTutup, onTersimpan }) {
  const [f, setF] = useState(() => ({
    id: awal.id || "", name: awal.name || "", category: awal.category || kategori[0]?.nama || "",
    price: awal.price ?? "", description: awal.description || "", image_url: awal.image_url || "",
    is_available: awal.is_available ?? true, is_active: awal.is_active ?? true, grup_ids: awal.grup_ids || [],
  }));
  const [katBaru, setKatBaru] = useState(kategori.length === 0);
  const [unggah, setUnggah] = useState(false);
  const [simpan, setSimpan] = useState(false);
  const set = (k, v) => setF((x) => ({ ...x, [k]: v }));

  const kirim = async (e) => {
    e.preventDefault();
    if (!f.name.trim()) return toast.error("Nama menu wajib diisi");
    if (f.price === "" || Number(f.price) < 0) return toast.error("Isi harga menu (boleh 0 kalau harga ada di varian)");
    if (Number(f.price) === 0 && f.grup_ids.length === 0) return toast.error("Harga Rp0 hanya untuk menu yang harganya ada di varian. Pasang varian atau isi harga.");
    setSimpan(true);
    const res = await api.simpanMenu({ ...f, merchant_id: merchantId, name: f.name.trim(), category: f.category.trim(), price: Number(f.price) }).catch(() => null);
    setSimpan(false);
    const galat = galatDari(res, "Gagal terhubung ke server");
    if (galat) return toast.error(galat);
    toast.success(f.id ? "Menu diperbarui" : "Menu ditambahkan");
    onTersimpan();
  };

  const pilihFoto = (e) => {
    const berkas = e.target.files?.[0];
    e.target.value = "";
    if (!berkas) return;
    setUnggah(true);
    api.uploadFile(berkas)
      .then((res) => { if (!res.url) throw new Error(res.error || "Gagal mengunggah foto"); set("image_url", res.url); })
      .catch((err) => toast.error(err.message || "Gagal mengunggah foto"))
      .finally(() => setUnggah(false));
  };

  return (
    <Modal
      judul={f.id ? "Edit menu" : "Tambah menu"} sub="Yang diisi di sini tampil di aplikasi pemesan BohFood." lebar={640} onTutup={onTutup}
      footer={<>
        <button type="button" className="btn btn-ghost" onClick={onTutup}>Batal</button>
        <button type="submit" form="form-menu" className="btn btn-primary" disabled={simpan || unggah}>{simpan ? <span className="spinner" /> : "Simpan menu"}</button>
      </>}
    >
      <form id="form-menu" onSubmit={kirim}>
        <div style={{ display: "flex", gap: 16, alignItems: "flex-start", marginBottom: 16, flexWrap: "wrap" }}>
          <label style={{ width: 120, height: 120, borderRadius: 14, border: "2px dashed var(--border)", background: "var(--bg-input)", display: "flex", alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 6, cursor: unggah ? "wait" : "pointer", overflow: "hidden", flexShrink: 0, color: "var(--text-muted)", fontSize: 12 }}>
            {f.image_url ? <img src={urlFoto(f.image_url)} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} />
              : unggah ? <span className="spinner" /> : <><ImagePlus size={26} /> Unggah foto</>}
            <input type="file" accept="image/*" hidden disabled={unggah} onChange={pilihFoto} />
          </label>
          <div style={{ flex: 1, minWidth: 220 }}>
            <div className="input-group">
              <label>Nama menu</label>
              <input className="input" value={f.name} onChange={(e) => set("name", e.target.value)} placeholder="Contoh: Mie Goreng Spesial" maxLength={100} required autoFocus />
            </div>
            <div className="input-group" style={{ marginBottom: 0 }}>
              <label>Harga</label>
              <div style={{ position: "relative" }}>
                <span style={{ position: "absolute", left: 12, top: "50%", transform: "translateY(-50%)", fontSize: 13, color: "var(--text-muted)", fontWeight: 600 }}>Rp</span>
                <input className="input" type="number" min="0" step="500" inputMode="numeric" value={f.price} onChange={(e) => set("price", e.target.value)} placeholder="15000" style={{ paddingLeft: 38 }} required />
              </div>
            </div>
          </div>
        </div>
        {f.image_url && (
          <button type="button" className="btn btn-ghost btn-sm" style={{ marginTop: -8, marginBottom: 12 }} onClick={() => set("image_url", "")}>Hapus foto</button>
        )}

        <div className="input-group">
          <label>Kategori</label>
          {katBaru ? (
            <div style={{ display: "flex", gap: 8 }}>
              <input className="input" value={f.category} onChange={(e) => set("category", e.target.value)} placeholder="Contoh: Makanan Berat" maxLength={50} />
              {kategori.length > 0 && <button type="button" className="btn btn-ghost" onClick={() => { setKatBaru(false); set("category", kategori[0].nama); }}>Pilih yang ada</button>}
            </div>
          ) : (
            <select className="input" value={f.category} onChange={(e) => (e.target.value === "__baru" ? (setKatBaru(true), set("category", "")) : set("category", e.target.value))}>
              {kategori.map((k) => <option key={k.id} value={k.nama}>{k.nama}{k.is_active ? "" : " (nonaktif)"}</option>)}
              {f.category && !kategori.some((k) => k.nama === f.category) && <option value={f.category}>{f.category}</option>}
              <option value="__baru">+ Kategori baru…</option>
            </select>
          )}
        </div>

        <div className="input-group">
          <label>Deskripsi <span style={{ fontWeight: 400, color: "var(--text-muted)" }}>(opsional)</span></label>
          <textarea className="input" rows={2} value={f.description} onChange={(e) => set("description", e.target.value)} placeholder="Mie goreng dengan telur, bakso, dan sayur segar" maxLength={500} style={{ resize: "vertical" }} />
        </div>

        <div className="input-group">
          <label>Varian</label>
          {grup.length === 0 ? (
            <p style={{ fontSize: 12, color: "var(--text-muted)", margin: 0 }}>Belum ada grup varian. Buat di tab <b>Varian</b> (mis. Level pedas, Ukuran, Topping), lalu pasang ke menu ini.</p>
          ) : (
            <div style={{ display: "grid", gap: 8 }}>
              {grup.map((g) => {
                const dipilih = f.grup_ids.includes(g.id);
                return (
                  <label key={g.id} style={{ display: "flex", gap: 10, alignItems: "flex-start", padding: "10px 12px", borderRadius: 10, border: `1px solid ${dipilih ? "var(--primary)" : "var(--border)"}`, background: dipilih ? "var(--primary-glow)" : "transparent", cursor: "pointer" }}>
                    <input type="checkbox" checked={dipilih} style={{ marginTop: 3 }}
                      onChange={(e) => set("grup_ids", e.target.checked ? [...f.grup_ids, g.id] : f.grup_ids.filter((x) => x !== g.id))} />
                    <span style={{ minWidth: 0 }}>
                      <b style={{ fontSize: 13 }}>{g.nama}</b> <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{aturanGrup(g)}</span>
                      <span style={{ display: "block", fontSize: 12, color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                        {g.opsi.map((o) => (o.harga > 0 ? `${o.nama} +${rp(o.harga)}` : o.nama)).join(", ")}
                      </span>
                    </span>
                  </label>
                );
              })}
            </div>
          )}
        </div>

        <div style={{ display: "grid", gap: 10, padding: 14, borderRadius: 12, background: "var(--bg-input)", marginBottom: 8 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 12, cursor: "pointer" }}>
            <Sakelar checked={f.is_active} onChange={(v) => set("is_active", v)} label="Tampil di aplikasi" />
            <span><b style={{ fontSize: 13 }}>Tampil di aplikasi</b><span style={{ display: "block", fontSize: 12, color: "var(--text-muted)" }}>Matikan untuk menyembunyikan menu tanpa menghapusnya.</span></span>
          </label>
          <label style={{ display: "flex", alignItems: "center", gap: 12, cursor: "pointer" }}>
            <Sakelar checked={f.is_available} onChange={(v) => set("is_available", v)} label="Stok tersedia" />
            <span><b style={{ fontSize: 13 }}>Stok tersedia</b><span style={{ display: "block", fontSize: 12, color: "var(--text-muted)" }}>Matikan kalau sedang habis: menu tetap terlihat, tapi tidak bisa dipesan.</span></span>
          </label>
        </div>
      </form>
    </Modal>
  );
}

function BarisMenu({ menu, namaGrup, bisaUbah, onEdit, onStatus, onHapus }) {
  const grupMenu = menu.option_groups || [];
  const varian = grupMenu.length ? grupMenu.map((g) => g.name) : (menu.grup_ids || []).map((id) => namaGrup[id]).filter(Boolean);
  const redup = !menu.is_active;
  return (
    <div className="menu-baris" style={{ display: "flex", alignItems: "center", gap: 14, padding: "12px 20px", borderTop: "1px solid var(--border)", flexWrap: "wrap" }}>
      <div style={{ width: 56, height: 56, borderRadius: 12, overflow: "hidden", flexShrink: 0, background: "var(--bg-input)", display: "flex", alignItems: "center", justifyContent: "center", opacity: redup ? 0.5 : 1, position: "relative" }}>
        {menu.image_url ? <img src={urlFoto(menu.image_url)} alt="" loading="lazy" style={{ width: "100%", height: "100%", objectFit: "cover", filter: menu.is_available ? "none" : "grayscale(1)" }} onError={(e) => { e.target.style.display = "none"; }} />
          : <UtensilsCrossed size={22} style={{ color: "var(--text-muted)" }} />}
      </div>
      <div style={{ flex: "1 1 120px", minWidth: 0, opacity: redup ? 0.55 : 1 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap" }}>
          <b style={{ fontSize: 14 }}>{menu.name}</b>
          {!menu.is_available && <span className="badge badge-danger" style={{ padding: "1px 8px" }}>Habis</span>}
          {!menu.is_active && <span className="badge badge-muted" style={{ padding: "1px 8px" }}><EyeOff size={11} /> Disembunyikan</span>}
        </div>
        {menu.description && <p style={{ margin: "2px 0 0", fontSize: 12, color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }} title={menu.description}>{menu.description}</p>}
        {varian.length > 0 && (
          <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginTop: 4 }}>
            {varian.map((v) => <span key={v} className="chip"><Layers size={10} /> {v}</span>)}
          </div>
        )}
      </div>
      <div style={{ textAlign: "right", flexShrink: 0, opacity: redup ? 0.55 : 1 }}>
        {hargaBisaNaik(menu) && <div style={{ fontSize: 10, color: "var(--text-muted)" }}>mulai</div>}
        <div style={{ fontWeight: 800, fontSize: 14, whiteSpace: "nowrap" }}>{rp(hargaMulaiDari(menu))}</div>
      </div>
      {bisaUbah && (
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginLeft: "auto" }}>
          {menu.is_available ? (
            <button className="btn btn-ghost btn-sm" style={{ whiteSpace: "nowrap" }} onClick={() => onStatus(menu, { is_available: false })}><Ban size={14} /> Tandai habis</button>
          ) : (
            <button className="btn btn-sm" style={{ whiteSpace: "nowrap", background: "rgba(16,185,129,0.12)", color: "var(--success)", border: "1px solid rgba(16,185,129,0.35)" }} onClick={() => onStatus(menu, { is_available: true })}><CheckCircle2 size={14} /> Tersedia lagi</button>
          )}
          <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--text-secondary)", cursor: "pointer", minWidth: 92 }}>
            <Sakelar checked={menu.is_active} onChange={(v) => onStatus(menu, { is_active: v })} label={menu.is_active ? "Aktif — tampil di aplikasi" : "Nonaktif — disembunyikan"} />
            {menu.is_active ? "Aktif" : "Nonaktif"}
          </label>
          <button className="btn btn-ghost btn-sm" style={{ padding: 7 }} onClick={() => onEdit(menu)} aria-label={`Edit ${menu.name}`} title="Edit"><Pencil size={15} /></button>
          <button className="btn btn-danger btn-sm" style={{ padding: 7 }} onClick={() => onHapus(menu)} aria-label={`Hapus ${menu.name}`} title="Hapus"><Trash2 size={15} /></button>
        </div>
      )}
    </div>
  );
}

function TabMenu({ menus, kategori, grup, bisaUbah, onTambah, onImpor, onEdit, onStatus, onHapus }) {
  const [cari, setCari] = useState("");
  const [filterKat, setFilterKat] = useState("");
  const [filterStatus, setFilterStatus] = useState("semua");
  const namaGrup = Object.fromEntries(grup.map((g) => [g.id, g.nama]));

  const kata = cari.trim().toLowerCase();
  const cocok = (m) =>
    (!kata || `${m.name} ${m.description} ${m.category}`.toLowerCase().includes(kata)) &&
    (!filterKat || (m.category || TANPA_KATEGORI) === filterKat) &&
    (filterStatus === "semua" || (filterStatus === "aktif" && m.is_active) || (filterStatus === "nonaktif" && !m.is_active) || (filterStatus === "habis" && !m.is_available));
  const tampil = menus.filter(cocok);

  // Dikelompokkan per kategori, mengikuti urutan kategori (= urutan di aplikasi).
  const urutan = [...kategori.map((k) => k.nama), TANPA_KATEGORI];
  const kelompok = {};
  for (const m of tampil) {
    const k = urutan.includes(m.category) ? m.category : TANPA_KATEGORI;
    (kelompok[k] ||= []).push(m);
  }
  const katInfo = Object.fromEntries(kategori.map((k) => [k.nama, k]));

  if (menus.length === 0) {
    return (
      <div className="card empty-state">
        <Salad size={48} style={{ margin: "0 auto 12px", color: "var(--text-muted)" }} />
        <h3 style={{ marginBottom: 4 }}>Belum ada menu</h3>
        <p style={{ fontSize: 13, color: "var(--text-muted)", marginBottom: 16 }}>{bisaUbah ? "Tambahkan menu pertama warung Anda. Kategori dan varian bisa diatur kapan saja." : "Belum ada menu yang aktif dan tampil ke publik di Kasvo."}</p>
        {bisaUbah && (
          <div style={{ display: "flex", gap: 8, justifyContent: "center", flexWrap: "wrap" }}>
            <button className="btn btn-ghost" onClick={onImpor}><FileSpreadsheet size={16} /> Impor dari Excel</button>
            <button className="btn btn-primary" onClick={onTambah}><Plus size={16} /> Tambah menu</button>
          </div>
        )}
      </div>
    );
  }

  return (
    <>
      <div className="filter-bar" style={{ marginBottom: 16 }}>
        <div className="search-bar" style={{ flex: "1 1 240px" }}>
          <Search size={15} style={{ color: "var(--text-muted)" }} />
          <input placeholder="Cari nama menu…" value={cari} onChange={(e) => setCari(e.target.value)} style={{ width: "100%" }} />
        </div>
        <select className="input" style={{ width: "auto", minWidth: 170 }} value={filterKat} onChange={(e) => setFilterKat(e.target.value)} aria-label="Saring kategori">
          <option value="">Semua kategori</option>
          {urutan.filter((k) => menus.some((m) => (urutan.includes(m.category) ? m.category : TANPA_KATEGORI) === k)).map((k) => <option key={k} value={k}>{k}</option>)}
        </select>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {[["semua", "Semua"], ["aktif", "Aktif"], ["nonaktif", "Nonaktif"], ["habis", "Habis"]].map(([v, l]) => (
            <button key={v} className={`filter-btn${filterStatus === v ? " active" : ""}`} onClick={() => setFilterStatus(v)}>{l}</button>
          ))}
        </div>
      </div>

      {tampil.length === 0 ? (
        <div className="card empty-state"><p style={{ fontSize: 13, color: "var(--text-muted)" }}>Tidak ada menu yang cocok dengan saringan ini.</p></div>
      ) : (
        urutan.filter((k) => kelompok[k]).map((k) => (
          <div key={k} className="table-wrap" style={{ marginBottom: 16 }}>
            <div className="table-header" style={{ borderBottom: "none", padding: "14px 20px" }}>
              <h3 style={{ display: "flex", alignItems: "center", gap: 8 }}>
                {k} <span style={{ fontSize: 12, fontWeight: 500, color: "var(--text-muted)" }}>{kelompok[k].length} menu</span>
                {katInfo[k] && !katInfo[k].is_active && <span className="badge badge-muted">Kategori nonaktif</span>}
              </h3>
            </div>
            {kelompok[k].map((m) => (
              <BarisMenu key={m.id} menu={m} namaGrup={namaGrup} bisaUbah={bisaUbah} onEdit={onEdit} onStatus={onStatus} onHapus={onHapus} />
            ))}
          </div>
        ))
      )}
    </>
  );
}

// ====================== KATEGORI ======================

function FormKategori({ awal, merchantId, onTutup, onTersimpan }) {
  const [nama, setNama] = useState(awal.nama || "");
  const [simpan, setSimpan] = useState(false);
  const kirim = async (e) => {
    e.preventDefault();
    if (!nama.trim()) return toast.error("Nama kategori wajib diisi");
    setSimpan(true);
    const res = await api.simpanKategori({ id: awal.id || "", merchant_id: merchantId, nama: nama.trim(), is_active: awal.is_active ?? true }).catch(() => null);
    setSimpan(false);
    const galat = galatDari(res, "Gagal terhubung ke server");
    if (galat) return toast.error(galat);
    toast.success(awal.id ? "Kategori diperbarui" : "Kategori ditambahkan");
    onTersimpan();
  };
  return (
    <Modal judul={awal.id ? "Ubah kategori" : "Tambah kategori"} sub={awal.id ? "Nama baru ikut berganti di semua menu dalam kategori ini." : "Contoh: Makanan Berat, Minuman, Camilan, Paket Hemat."} lebar={440} onTutup={onTutup}
      footer={<>
        <button type="button" className="btn btn-ghost" onClick={onTutup}>Batal</button>
        <button type="submit" form="form-kategori" className="btn btn-primary" disabled={simpan}>{simpan ? <span className="spinner" /> : "Simpan"}</button>
      </>}>
      <form id="form-kategori" onSubmit={kirim}>
        <div className="input-group">
          <label>Nama kategori</label>
          <input className="input" value={nama} onChange={(e) => setNama(e.target.value)} maxLength={50} autoFocus required />
        </div>
      </form>
    </Modal>
  );
}

function TabKategori({ kategori, merchantId, onUbah, onEdit, onTambah }) {
  const [daftar, setDaftar] = useState(kategori);
  useEffect(() => setDaftar(kategori), [kategori]);

  const pindah = async (i, arah) => {
    const baru = [...daftar];
    [baru[i], baru[i + arah]] = [baru[i + arah], baru[i]];
    setDaftar(baru);
    const res = await api.urutkanKategori(merchantId, baru.map((k) => k.id)).catch(() => null);
    const galat = galatDari(res, "Gagal menyimpan urutan");
    if (galat) { toast.error(galat); setDaftar(daftar); return; }
    onUbah();
  };
  const ubahAktif = async (k, aktif) => {
    setDaftar((d) => d.map((x) => (x.id === k.id ? { ...x, is_active: aktif } : x)));
    const res = await api.simpanKategori({ id: k.id, merchant_id: merchantId, nama: k.nama, is_active: aktif }).catch(() => null);
    const galat = galatDari(res, "Gagal menyimpan");
    if (galat) { toast.error(galat); setDaftar(daftar); return; }
    toast.success(aktif ? `${k.nama} tampil lagi di aplikasi` : `${k.nama} dan menunya disembunyikan`);
    onUbah();
  };
  const hapus = async (k) => {
    if (!(await confirmDialog({ title: `Hapus kategori ${k.nama}?`, message: "Kategori ini kosong, jadi tidak ada menu yang terpengaruh.", confirmText: "Hapus" }))) return;
    const res = await api.hapusKategori(k.id).catch(() => null);
    const galat = galatDari(res, "Gagal menghapus");
    if (galat) return toast.error(galat);
    toast.success("Kategori dihapus");
    onUbah();
  };

  if (daftar.length === 0) {
    return (
      <div className="card empty-state">
        <Tags size={44} style={{ margin: "0 auto 12px", color: "var(--text-muted)" }} />
        <h3 style={{ marginBottom: 4 }}>Belum ada kategori</h3>
        <p style={{ fontSize: 13, color: "var(--text-muted)", marginBottom: 16 }}>Kategori membuat menu mudah dicari di aplikasi, mis. Makanan, Minuman, Camilan.</p>
        <button className="btn btn-primary" onClick={onTambah} style={{ margin: "0 auto" }}><Plus size={16} /> Tambah kategori</button>
      </div>
    );
  }
  return (
    <div className="table-wrap">
      <div className="table-header"><h3>Urutan kategori</h3><span style={{ fontSize: 12, color: "var(--text-muted)" }}>Urutan ini dipakai di aplikasi pemesan</span></div>
      {daftar.map((k, i) => (
        <div key={k.id} style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 20px", borderTop: i ? "1px solid var(--border)" : "none", flexWrap: "wrap" }}>
          <div style={{ display: "flex", flexDirection: "column" }}>
            <button className="btn btn-ghost btn-sm" style={{ padding: "1px 6px", border: "none" }} disabled={i === 0} onClick={() => pindah(i, -1)} aria-label={`Naikkan ${k.nama}`}><ChevronUp size={16} /></button>
            <button className="btn btn-ghost btn-sm" style={{ padding: "1px 6px", border: "none" }} disabled={i === daftar.length - 1} onClick={() => pindah(i, 1)} aria-label={`Turunkan ${k.nama}`}><ChevronDown size={16} /></button>
          </div>
          <span style={{ width: 26, height: 26, borderRadius: 8, background: "var(--primary-glow)", color: "var(--primary)", fontWeight: 800, fontSize: 12, display: "flex", alignItems: "center", justifyContent: "center" }}>{i + 1}</span>
          <div style={{ flex: "1 1 160px", minWidth: 0, opacity: k.is_active ? 1 : 0.55 }}>
            <b style={{ fontSize: 14 }}>{k.nama}</b>
            <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{k.jumlah_menu} menu{k.jumlah_menu ? ` · ${k.jumlah_aktif} aktif` : ""}</div>
          </div>
          <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--text-secondary)", cursor: "pointer", minWidth: 92 }}>
            <Sakelar checked={k.is_active} onChange={(v) => ubahAktif(k, v)} label={k.is_active ? "Kategori aktif" : "Kategori nonaktif"} />
            {k.is_active ? "Aktif" : "Nonaktif"}
          </label>
          <button className="btn btn-ghost btn-sm" style={{ padding: 7 }} onClick={() => onEdit(k)} aria-label={`Ubah ${k.nama}`} title="Ubah nama"><Pencil size={15} /></button>
          <button className="btn btn-danger btn-sm" style={{ padding: 7 }} disabled={k.jumlah_menu > 0} onClick={() => hapus(k)} aria-label={`Hapus ${k.nama}`}
            title={k.jumlah_menu > 0 ? "Pindahkan dulu menu di kategori ini" : "Hapus kategori"}><Trash2 size={15} /></button>
        </div>
      ))}
    </div>
  );
}

// ====================== VARIAN ======================

function FormVarian({ awal, merchantId, menus, onTutup, onTersimpan }) {
  const [g, setG] = useState(() => ({
    id: awal.id || "", nama: awal.nama || "", tipe: awal.tipe || "single", wajib: awal.wajib ?? true,
    min: awal.min || 1, max: awal.max || 0,
    opsi: awal.opsi?.length ? awal.opsi.map((o) => ({ ...o })) : [{ id: "", nama: "", harga: 0, is_active: true }],
    menu_ids: awal.menu_ids || [],
  }));
  const [cariMenu, setCariMenu] = useState("");
  const [simpan, setSimpan] = useState(false);
  const set = (k, v) => setG((x) => ({ ...x, [k]: v }));
  const setOpsi = (i, k, v) => setG((x) => ({ ...x, opsi: x.opsi.map((o, j) => (j === i ? { ...o, [k]: v } : o)) }));
  const geserOpsi = (i, arah) => setG((x) => { const o = [...x.opsi]; [o[i], o[i + arah]] = [o[i + arah], o[i]]; return { ...x, opsi: o }; });

  const kirim = async (e) => {
    e.preventDefault();
    const opsi = g.opsi.filter((o) => o.nama.trim());
    if (!g.nama.trim()) return toast.error("Nama grup wajib diisi");
    if (opsi.length === 0) return toast.error("Isi minimal satu pilihan");
    setSimpan(true);
    const res = await api.simpanVarian({
      ...g, merchant_id: merchantId, nama: g.nama.trim(),
      min: Number(g.min) || 0, max: Number(g.max) || 0,
      opsi: opsi.map((o) => ({ ...o, nama: o.nama.trim(), harga: Number(o.harga) || 0 })),
    }).catch(() => null);
    setSimpan(false);
    const galat = galatDari(res, "Gagal terhubung ke server");
    if (galat) return toast.error(galat);
    toast.success(g.id ? "Grup varian diperbarui" : "Grup varian ditambahkan");
    onTersimpan();
  };

  const kata = cariMenu.trim().toLowerCase();
  const menuTampil = menus.filter((m) => !kata || m.name.toLowerCase().includes(kata));

  return (
    <Modal judul={g.id ? "Edit grup varian" : "Tambah grup varian"} sub="Contoh: Level pedas (pilih 1, wajib), Topping (pilih beberapa, opsional)." lebar={680} onTutup={onTutup}
      footer={<>
        <button type="button" className="btn btn-ghost" onClick={onTutup}>Batal</button>
        <button type="submit" form="form-varian" className="btn btn-primary" disabled={simpan}>{simpan ? <span className="spinner" /> : "Simpan varian"}</button>
      </>}>
      <form id="form-varian" onSubmit={kirim}>
        <div className="input-group">
          <label>Nama grup</label>
          <input className="input" value={g.nama} onChange={(e) => set("nama", e.target.value)} placeholder="Contoh: Level pedas" maxLength={50} autoFocus required />
        </div>

        <div className="input-group">
          <label>Cara memilih</label>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 8 }}>
            {[["single", "Pilih satu", "Mis. ukuran, level pedas, suhu"], ["multiple", "Pilih beberapa", "Mis. topping, tambahan"]].map(([v, j, d]) => (
              <label key={v} style={{ padding: "10px 12px", borderRadius: 10, border: `1px solid ${g.tipe === v ? "var(--primary)" : "var(--border)"}`, background: g.tipe === v ? "var(--primary-glow)" : "transparent", cursor: "pointer", display: "flex", gap: 8 }}>
                <input type="radio" name="tipe" checked={g.tipe === v} onChange={() => set("tipe", v)} style={{ marginTop: 3 }} />
                <span><b style={{ fontSize: 13 }}>{j}</b><span style={{ display: "block", fontSize: 12, color: "var(--text-muted)" }}>{d}</span></span>
              </label>
            ))}
          </div>
        </div>

        <div style={{ display: "flex", gap: 16, alignItems: "flex-end", flexWrap: "wrap", marginBottom: 16 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 10, cursor: "pointer" }}>
            <Sakelar checked={g.wajib} onChange={(v) => set("wajib", v)} label="Wajib dipilih" />
            <span style={{ fontSize: 13 }}><b>Wajib dipilih</b> <span style={{ color: "var(--text-muted)" }}>{g.wajib ? "pemesan harus memilih" : "boleh dilewati"}</span></span>
          </label>
          {g.tipe === "multiple" && (
            <>
              {g.wajib && (
                <div className="input-group" style={{ marginBottom: 0, width: 110 }}>
                  <label>Minimal</label>
                  <input className="input" type="number" min="1" value={g.min} onChange={(e) => set("min", e.target.value)} />
                </div>
              )}
              <div className="input-group" style={{ marginBottom: 0, width: 140 }}>
                <label>Maksimal</label>
                <input className="input" type="number" min="0" value={g.max || ""} placeholder="Tanpa batas" onChange={(e) => set("max", e.target.value)} />
              </div>
            </>
          )}
        </div>

        <div className="input-group">
          <label>Pilihan</label>
          <div style={{ display: "grid", gap: 8 }}>
            {g.opsi.map((o, i) => (
              <div key={i} style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
                <div style={{ display: "flex", flexDirection: "column" }}>
                  <button type="button" className="btn btn-ghost btn-sm" style={{ padding: "0 4px", border: "none" }} disabled={i === 0} onClick={() => geserOpsi(i, -1)} aria-label="Naikkan"><ChevronUp size={14} /></button>
                  <button type="button" className="btn btn-ghost btn-sm" style={{ padding: "0 4px", border: "none" }} disabled={i === g.opsi.length - 1} onClick={() => geserOpsi(i, 1)} aria-label="Turunkan"><ChevronDown size={14} /></button>
                </div>
                <input className="input" style={{ flex: "2 1 160px" }} value={o.nama} onChange={(e) => setOpsi(i, "nama", e.target.value)} placeholder={i === 0 ? "Contoh: Tidak pedas" : "Nama pilihan"} maxLength={50} />
                <div style={{ position: "relative", flex: "1 1 120px" }}>
                  <span style={{ position: "absolute", left: 10, top: "50%", transform: "translateY(-50%)", fontSize: 12, color: "var(--text-muted)" }}>+Rp</span>
                  <input className="input" type="number" min="0" step="500" value={o.harga} onChange={(e) => setOpsi(i, "harga", e.target.value)} style={{ paddingLeft: 40 }} aria-label="Harga tambahan" />
                </div>
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--text-secondary)", cursor: "pointer", width: 96 }}>
                  <Sakelar checked={o.is_active} onChange={(v) => setOpsi(i, "is_active", v)} label="Pilihan tersedia" />
                  {o.is_active ? "Tersedia" : "Habis"}
                </label>
                <button type="button" className="btn btn-danger btn-sm" style={{ padding: 7 }} disabled={g.opsi.length === 1} onClick={() => set("opsi", g.opsi.filter((_, j) => j !== i))} aria-label="Hapus pilihan"><Trash2 size={14} /></button>
              </div>
            ))}
          </div>
          <button type="button" className="btn btn-ghost btn-sm" style={{ marginTop: 10 }} onClick={() => set("opsi", [...g.opsi, { id: "", nama: "", harga: 0, is_active: true }])}><Plus size={14} /> Tambah pilihan</button>
          <p style={{ fontSize: 12, color: "var(--text-muted)", margin: "8px 0 0" }}>Harga tambahan 0 = gratis. Pilihan yang habis disembunyikan dari pemesan.</p>
        </div>

        <div className="input-group">
          <label>Pakai di menu <span style={{ fontWeight: 400, color: "var(--text-muted)" }}>({g.menu_ids.length} dipilih)</span></label>
          {menus.length === 0 ? (
            <p style={{ fontSize: 12, color: "var(--text-muted)", margin: 0 }}>Belum ada menu. Grup ini bisa dipasang nanti dari formulir menu.</p>
          ) : (
            <>
              <div style={{ display: "flex", gap: 8, marginBottom: 8, flexWrap: "wrap" }}>
                <div className="search-bar" style={{ flex: 1, padding: "6px 12px" }}>
                  <Search size={14} style={{ color: "var(--text-muted)" }} />
                  <input placeholder="Cari menu…" value={cariMenu} onChange={(e) => setCariMenu(e.target.value)} style={{ width: "100%" }} />
                </div>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => set("menu_ids", [...new Set([...g.menu_ids, ...menuTampil.map((m) => m.id)])])}>Pilih semua</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => set("menu_ids", g.menu_ids.filter((id) => !menuTampil.some((m) => m.id === id)))}>Kosongkan</button>
              </div>
              <div style={{ maxHeight: 200, overflowY: "auto", border: "1px solid var(--border)", borderRadius: 10 }}>
                {menuTampil.map((m, i) => (
                  <label key={m.id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 12px", borderTop: i ? "1px solid var(--border)" : "none", cursor: "pointer", fontSize: 13 }}>
                    <input type="checkbox" checked={g.menu_ids.includes(m.id)}
                      onChange={(e) => set("menu_ids", e.target.checked ? [...g.menu_ids, m.id] : g.menu_ids.filter((x) => x !== m.id))} />
                    <span style={{ flex: 1 }}>{m.name}</span>
                    <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{m.category || TANPA_KATEGORI}</span>
                  </label>
                ))}
              </div>
            </>
          )}
        </div>
      </form>
    </Modal>
  );
}

function TabVarian({ grup, menus, onEdit, onHapus, onTambah }) {
  const namaMenu = Object.fromEntries(menus.map((m) => [m.id, m.name]));
  if (grup.length === 0) {
    return (
      <div className="card empty-state">
        <Layers size={44} style={{ margin: "0 auto 12px", color: "var(--text-muted)" }} />
        <h3 style={{ marginBottom: 4 }}>Belum ada grup varian</h3>
        <p style={{ fontSize: 13, color: "var(--text-muted)", marginBottom: 16, maxWidth: 460, marginInline: "auto" }}>
          Varian membuat pemesan bisa memilih ukuran, level pedas, atau topping. Satu grup bisa dipasang ke banyak menu sekaligus.
        </p>
        <button className="btn btn-primary" onClick={onTambah} style={{ margin: "0 auto" }}><Plus size={16} /> Tambah grup varian</button>
      </div>
    );
  }
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(300px, 1fr))", gap: 16 }}>
      {grup.map((g) => {
        const dipakai = g.menu_ids.map((id) => namaMenu[id]).filter(Boolean);
        return (
          <div key={g.id} className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <b style={{ fontSize: 15 }}>{g.nama}</b>
                <div style={{ display: "flex", gap: 6, marginTop: 4, flexWrap: "wrap" }}>
                  <span className="badge badge-primary">{g.tipe === "single" ? "Pilih 1" : g.max ? `Pilih maks ${g.max}` : "Pilih beberapa"}</span>
                  <span className={`badge ${g.wajib ? "badge-warning" : "badge-muted"}`}>{g.wajib ? (g.tipe === "multiple" && g.min > 1 ? `Wajib min ${g.min}` : "Wajib") : "Opsional"}</span>
                </div>
              </div>
              <button className="btn btn-ghost btn-sm" style={{ padding: 7 }} onClick={() => onEdit(g)} aria-label={`Edit ${g.nama}`}><Pencil size={15} /></button>
              <button className="btn btn-danger btn-sm" style={{ padding: 7 }} onClick={() => onHapus(g)} aria-label={`Hapus ${g.nama}`}><Trash2 size={15} /></button>
            </div>
            <div style={{ display: "grid", gap: 4 }}>
              {g.opsi.map((o) => (
                <div key={o.id} style={{ display: "flex", justifyContent: "space-between", fontSize: 13, color: o.is_active ? "var(--text-primary)" : "var(--text-muted)" }}>
                  <span style={{ textDecoration: o.is_active ? "none" : "line-through" }}>{o.nama}{!o.is_active && " · habis"}</span>
                  <span style={{ fontWeight: 600 }}>{o.harga > 0 ? `+${rp(o.harga)}` : "Gratis"}</span>
                </div>
              ))}
            </div>
            <div style={{ marginTop: "auto", paddingTop: 10, borderTop: "1px solid var(--border)", fontSize: 12, color: "var(--text-muted)" }}>
              {dipakai.length ? <>Dipakai di <b style={{ color: "var(--text-secondary)" }}>{dipakai.length} menu</b>: {dipakai.slice(0, 3).join(", ")}{dipakai.length > 3 ? `, +${dipakai.length - 3} lagi` : ""}</> : <span style={{ color: "var(--warning)" }}>Belum dipasang ke menu mana pun</span>}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ====================== IMPOR EXCEL ======================

const LABEL_AKSI = { baru: ["Baru", "badge-success"], perbarui: ["Diperbarui", "badge-info"], lewati: ["Dilewati (sudah ada)", "badge-muted"] };

function ImporExcel({ merchantId, onTutup, onSelesai }) {
  const [berkas, setBerkas] = useState(null);
  const [perbarui, setPerbarui] = useState(false);
  const [hasil, setHasil] = useState(null); // balasan server
  const [sibuk, setSibuk] = useState("");   // "periksa" / "simpan" / "template"
  const [seret, setSeret] = useState(false);

  const periksa = async (b, perb) => {
    setSibuk("periksa");
    const res = await api.imporMenu(merchantId, b, false, perb).catch(() => ({ error: "Gagal terhubung ke server" }));
    setSibuk("");
    setHasil(res);
  };
  const pilih = (b) => {
    if (!b) return;
    if (!/\.xlsx$/i.test(b.name)) {
      setBerkas(null);
      setHasil({ error: "Pilih berkas Excel berakhiran .xlsx. Berkas .xls atau .csv: buka di Excel lalu Simpan Sebagai \"Excel Workbook (.xlsx)\"." });
      return;
    }
    setBerkas(b);
    periksa(b, perbarui);
  };
  const unduhTemplate = async () => {
    setSibuk("template");
    try {
      const blob = await api.templateImporMenu();
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "template-menu-bohfood.xlsx";
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    } catch (err) {
      toast.error(err.message || "Gagal mengunduh template");
    }
    setSibuk("");
  };
  const simpan = async () => {
    setSibuk("simpan");
    const res = await api.imporMenu(merchantId, berkas, true, perbarui).catch(() => ({ error: "Gagal terhubung ke server" }));
    setSibuk("");
    if (res.status !== "success") return setHasil(res);
    const m = res.hasil.menu;
    const n = m.filter((x) => x.aksi !== "lewati").length;
    toast.success(`${n} menu berhasil diimpor`, 6000);
    onSelesai();
  };

  const h = hasil?.hasil;
  const menu = h?.menu || [];
  const jml = (a) => menu.filter((x) => x.aksi === a).length;
  const dikerjakan = jml("baru") + jml("perbarui");
  const lolos = hasil?.status === "success";

  return (
    <Modal judul="Impor menu dari Excel" sub="Tambah banyak menu sekaligus, lengkap dengan kategori dan varian." lebar={760} onTutup={onTutup}
      footer={<>
        <button type="button" className="btn btn-ghost" onClick={onTutup}>Batal</button>
        <button type="button" className="btn btn-primary" disabled={!lolos || dikerjakan === 0 || !!sibuk} onClick={simpan}>
          {sibuk === "simpan" ? <span className="spinner" /> : <><Upload size={16} /> {lolos ? `Impor ${dikerjakan} menu` : "Impor"}</>}
        </button>
      </>}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 10, marginBottom: 16 }}>
        {[
          ["1", "Unduh template", "Berisi contoh menu, varian, dan petunjuk pengisian."],
          ["2", "Isi di Excel", "Kategori & varian yang belum ada dibuat otomatis."],
          ["3", "Unggah & periksa", "Lihat pratinjau dulu, baru simpan."],
        ].map(([n, j, d]) => (
          <div key={n} style={{ display: "flex", gap: 10, padding: 12, borderRadius: 12, background: "var(--bg-input)" }}>
            <span style={{ width: 24, height: 24, borderRadius: 8, background: "var(--primary)", color: "#fff", fontWeight: 800, fontSize: 12, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>{n}</span>
            <span><b style={{ fontSize: 13 }}>{j}</b><span style={{ display: "block", fontSize: 12, color: "var(--text-muted)" }}>{d}</span></span>
          </div>
        ))}
      </div>

      <button type="button" className="btn btn-ghost" onClick={unduhTemplate} disabled={sibuk === "template"} style={{ marginBottom: 14 }}>
        {sibuk === "template" ? <span className="spinner" /> : <><Download size={16} /> Unduh template Excel</>}
      </button>

      <label
        onDragOver={(e) => { e.preventDefault(); setSeret(true); }}
        onDragLeave={() => setSeret(false)}
        onDrop={(e) => { e.preventDefault(); setSeret(false); pilih(e.dataTransfer.files?.[0]); }}
        style={{ display: "flex", alignItems: "center", gap: 14, padding: 18, borderRadius: 14, border: `2px dashed ${seret ? "var(--primary)" : "var(--border)"}`, background: seret ? "var(--primary-glow)" : "transparent", cursor: "pointer", marginBottom: 12 }}>
        <FileSpreadsheet size={34} style={{ color: "var(--success)", flexShrink: 0 }} />
        <span style={{ flex: 1, minWidth: 0 }}>
          <b style={{ fontSize: 14, display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{berkas ? berkas.name : "Pilih atau seret berkas .xlsx ke sini"}</b>
          <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{berkas ? "Klik untuk mengganti berkas" : "Maksimal 5 MB, 1.000 menu"}</span>
        </span>
        {sibuk === "periksa" && <span className="spinner" />}
        <input type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" hidden
          onChange={(e) => { const b = e.target.files?.[0]; e.target.value = ""; pilih(b); }} />
      </label>

      <label style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 13, cursor: "pointer", marginBottom: 16 }}>
        <Sakelar checked={perbarui} onChange={(v) => { setPerbarui(v); if (berkas) periksa(berkas, v); }} label="Perbarui menu yang sudah ada" />
        <span><b>Perbarui menu yang sudah ada</b> <span style={{ color: "var(--text-muted)" }}>— harga, kategori, status, varian ditimpa dari Excel. Kalau mati, menu bernama sama dilewati.</span></span>
      </label>

      {hasil && !lolos && (
        <div style={{ borderRadius: 12, border: "1px solid rgba(239,68,68,0.35)", background: "rgba(239,68,68,0.06)", padding: 14 }}>
          <div style={{ display: "flex", gap: 8, alignItems: "center", fontWeight: 700, color: "var(--danger)", fontSize: 14 }}>
            <AlertTriangle size={18} /> {hasil.error || "Berkas belum bisa diimpor"}
          </div>
          {h?.galat?.length > 0 && (
            <>
              <p style={{ fontSize: 12, color: "var(--text-secondary)", margin: "6px 0 8px" }}>Belum ada yang tersimpan. Perbaiki baris berikut di Excel, simpan, lalu pilih berkasnya lagi.</p>
              <div style={{ maxHeight: 220, overflowY: "auto", display: "grid", gap: 4 }}>
                {h.galat.map((g, i) => (
                  <div key={i} style={{ fontSize: 13, display: "flex", gap: 8 }}>
                    <span className="chip" style={{ flexShrink: 0 }}>{g.lembar}{g.baris ? ` · baris ${g.baris}` : ""}</span>
                    <span>{g.pesan}</span>
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      )}

      {lolos && (
        <>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 12 }}>
            <span className="badge badge-success">{jml("baru")} menu baru</span>
            {jml("perbarui") > 0 && <span className="badge badge-info">{jml("perbarui")} diperbarui</span>}
            {jml("lewati") > 0 && <span className="badge badge-muted">{jml("lewati")} dilewati</span>}
            {h.kategori_baru.length > 0 && <span className="badge badge-primary">Kategori baru: {h.kategori_baru.join(", ")}</span>}
            {h.varian_baru.length > 0 && <span className="badge badge-warning">Varian baru: {h.varian_baru.join(", ")}</span>}
          </div>
          {h.varian_ada.length > 0 && (
            <p style={{ fontSize: 12, color: "var(--text-muted)", margin: "0 0 10px" }}>Grup varian {h.varian_ada.join(", ")} sudah ada di warung, jadi dipakai apa adanya (isinya tidak diubah).</p>
          )}
          <div style={{ border: "1px solid var(--border)", borderRadius: 12, maxHeight: 280, overflow: "auto" }}>
            <table style={{ fontSize: 13 }}>
              <thead><tr><th>Baris</th><th>Menu</th><th>Kategori</th><th style={{ textAlign: "right" }}>Harga</th><th>Varian</th><th>Hasil</th></tr></thead>
              <tbody>
                {menu.map((m) => (
                  <tr key={m.baris} style={{ opacity: m.aksi === "lewati" ? 0.55 : 1 }}>
                    <td style={{ color: "var(--text-muted)" }}>{m.baris}</td>
                    <td><b>{m.nama}</b>{!m.aktif && <span className="badge badge-muted" style={{ marginLeft: 6 }}>Nonaktif</span>}{!m.tersedia && <span className="badge badge-danger" style={{ marginLeft: 6 }}>Habis</span>}</td>
                    <td>{m.kategori}</td>
                    <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>{rp(m.harga)}</td>
                    <td style={{ fontSize: 12, color: "var(--text-secondary)" }}>{(m.varian || []).join(", ") || "-"}</td>
                    <td><span className={`badge ${LABEL_AKSI[m.aksi][1]}`}>{LABEL_AKSI[m.aksi][0]}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {dikerjakan === 0 && <p style={{ fontSize: 12, color: "var(--warning)", marginTop: 8 }}>Semua menu di berkas sudah ada. Nyalakan "Perbarui menu yang sudah ada" untuk menimpanya.</p>}
        </>
      )}
    </Modal>
  );
}

// ====================== HALAMAN ======================

export default function MenuManagement({ ownerPhone }) {
  const [merchant, setMerchant] = useState(null);
  const [menus, setMenus] = useState([]);
  const [kategori, setKategori] = useState([]);
  const [grup, setGrup] = useState([]);
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState("menu");
  const [formMenu, setFormMenu] = useState(null); // null = tertutup, {} = baru, menu = edit
  const [formKat, setFormKat] = useState(null);
  const [formGrup, setFormGrup] = useState(null);
  const [imporBuka, setImporBuka] = useState(false);

  const dariKasvo = !!merchant?.kasvo_toko_uuid;

  const muatIsi = async (m) => {
    if (m.kasvo_toko_uuid) {
      const data = await authFetch(`${BASE}/food/menus?merchant_id=${m.id}`).then((r) => r.json()).catch(() => []);
      setMenus(Array.isArray(data) ? data : []);
      return;
    }
    const [mn, kt, vr] = await Promise.all([
      api.getMenuSemua(m.id).catch(() => null),
      api.getKategori(m.id).catch(() => null),
      api.getVarian(m.id).catch(() => null),
    ]);
    if (!Array.isArray(mn) || !kt?.kategori || !vr?.grup) toast.error("Sebagian data menu gagal dimuat. Muat ulang halaman.");
    if (Array.isArray(mn)) setMenus(mn);
    if (kt?.kategori) setKategori(kt.kategori);
    if (vr?.grup) setGrup(vr.grup);
  };

  useEffect(() => {
    setLoading(true);
    authFetch(`${BASE}/food/merchant?owner_phone=${encodeURIComponent(ownerPhone)}`)
      .then((r) => (r.status === 404 ? null : r.json()))
      .then(async (m) => {
        if (m?.id) {
          setMerchant(m);
          await muatIsi(m);
        }
      })
      .catch(() => toast.error("Gagal memuat data warung"))
      .finally(() => setLoading(false));
  }, [ownerPhone]);

  const muatUlang = () => merchant && muatIsi(merchant);

  const ubahStatus = async (menu, data) => {
    setMenus((ms) => ms.map((m) => (m.id === menu.id ? { ...m, ...data } : m)));
    const res = await api.statusMenu(menu.id, data).catch(() => null);
    const galat = galatDari(res, "Gagal terhubung ke server");
    if (galat) {
      setMenus((ms) => ms.map((m) => (m.id === menu.id ? menu : m)));
      return toast.error(galat);
    }
    toast.success(
      "is_available" in data
        ? data.is_available ? `${menu.name} tersedia lagi` : `${menu.name} ditandai habis`
        : data.is_active ? `${menu.name} tampil di aplikasi` : `${menu.name} disembunyikan dari aplikasi`
    );
    if ("is_active" in data) api.getKategori(merchant.id).then((kt) => kt?.kategori && setKategori(kt.kategori)).catch(() => {});
  };

  const hapusMenu = async (menu) => {
    const ok = await confirmDialog({
      title: `Hapus ${menu.name}?`,
      message: "Menu hilang permanen dari daftar jualan. Kalau hanya ingin menyembunyikan sementara, matikan saja status Aktif-nya.",
      confirmText: "Hapus menu",
    });
    if (!ok) return;
    const res = await api.hapusMenu(menu.id).catch(() => null);
    const galat = galatDari(res, "Gagal menghapus menu");
    if (galat) return toast.error(galat);
    toast.success("Menu dihapus");
    muatUlang();
  };

  const hapusGrup = async (g) => {
    const ok = await confirmDialog({
      title: `Hapus grup ${g.nama}?`,
      message: g.menu_ids.length ? `Grup ini dilepas dari ${g.menu_ids.length} menu. Menunya tetap ada, hanya tanpa pilihan ${g.nama}.` : "Grup ini belum dipakai menu mana pun.",
      confirmText: "Hapus grup",
    });
    if (!ok) return;
    const res = await api.hapusVarian(g.id).catch(() => null);
    const galat = galatDari(res, "Gagal menghapus");
    if (galat) return toast.error(galat);
    toast.success("Grup varian dihapus");
    muatUlang();
  };

  const jumlahAktif = menus.filter((m) => m.is_active).length;
  const jumlahHabis = menus.filter((m) => !m.is_available).length;
  const tombolTambah = {
    menu: ["Tambah menu", () => setFormMenu({})],
    kategori: ["Tambah kategori", () => setFormKat({})],
    varian: ["Tambah grup varian", () => setFormGrup({})],
  }[tab];

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
        <div>
          <h1>Kelola Menu</h1>
          <p>{dariKasvo ? "Menu warung ini mengikuti Kasvo" : "Atur menu, kategori, dan varian yang tampil di aplikasi BohFood"}</p>
        </div>
        {merchant && !dariKasvo && (
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            {tab === "menu" && (
              <button onClick={() => setImporBuka(true)} className="btn btn-ghost"><FileSpreadsheet size={18} /> Impor Excel</button>
            )}
            <button onClick={tombolTambah[1]} className="btn btn-primary"><Plus size={18} /> {tombolTambah[0]}</button>
          </div>
        )}
      </div>

      {loading ? (
        <div className="spinner" style={{ margin: "50px auto" }} />
      ) : !merchant ? (
        <div className="card empty-state">
          <Salad size={48} style={{ margin: "0 auto 12px", color: "var(--text-muted)" }} />
          <h3>Profil warung belum lengkap</h3>
          <p style={{ fontSize: 13, marginTop: 4, color: "var(--text-muted)" }}>Lengkapi profil warung di halaman Dashboard dulu supaya bisa mengelola menu.</p>
        </div>
      ) : (
        <>
          {dariKasvo && (
            <div className="card" style={{ marginBottom: 20, fontSize: 13 }}>
              Menu, kategori, harga, varian, dan stok habis diatur di <b>Kasvo</b> dan langsung berlaku di BohFood.
              Yang tampil di sini hanya menu yang aktif dan tampil ke publik di Kasvo.
            </div>
          )}

          <div className="stats-grid" style={{ marginBottom: 20 }}>
            {[
              { label: "Total menu", value: menus.length, Ikon: UtensilsCrossed, warna: "var(--primary)" },
              { label: "Tampil di aplikasi", value: jumlahAktif, Ikon: Eye, warna: "var(--success)" },
              { label: "Sedang habis", value: jumlahHabis, Ikon: Ban, warna: "var(--danger)" },
              ...(dariKasvo ? [] : [{ label: "Grup varian", value: grup.length, Ikon: Layers, warna: "var(--info)" }]),
            ].map(({ label, value, Ikon, warna }) => (
              <div key={label} className="stat-card">
                <div style={{ width: 40, height: 40, borderRadius: 12, display: "flex", alignItems: "center", justifyContent: "center", background: "var(--bg-input)", color: warna, flexShrink: 0 }}><Ikon size={20} /></div>
                <div><div className="stat-value">{value}</div><div className="stat-label">{label}</div></div>
              </div>
            ))}
          </div>

          {!dariKasvo && (
            <div style={{ display: "flex", gap: 4, padding: 4, borderRadius: 12, background: "var(--bg-input)", border: "1px solid var(--border)", width: "fit-content", maxWidth: "100%", marginBottom: 20, overflowX: "auto" }} role="tablist">
              {[["menu", "Menu", UtensilsCrossed, menus.length], ["kategori", "Kategori", Tags, kategori.length], ["varian", "Varian", Layers, grup.length]].map(([v, l, Ikon, n]) => (
                <button key={v} role="tab" aria-selected={tab === v} onClick={() => setTab(v)}
                  style={{ display: "flex", alignItems: "center", gap: 6, padding: "8px 12px", borderRadius: 9, border: "none", cursor: "pointer", fontSize: 13, fontWeight: 700, whiteSpace: "nowrap", background: tab === v ? "var(--bg-card)" : "transparent", color: tab === v ? "var(--primary)" : "var(--text-secondary)", boxShadow: tab === v ? "0 1px 3px rgba(0,0,0,0.12)" : "none" }}>
                  <Ikon size={15} /> {l} <span style={{ fontSize: 11, fontWeight: 600, padding: "0 6px", borderRadius: 999, background: tab === v ? "var(--primary-glow)" : "transparent" }}>{n}</span>
                </button>
              ))}
            </div>
          )}

          {(dariKasvo || tab === "menu") && (
            <TabMenu menus={menus} kategori={kategori} grup={grup} bisaUbah={!dariKasvo}
              onTambah={() => setFormMenu({})} onImpor={() => setImporBuka(true)} onEdit={setFormMenu} onStatus={ubahStatus} onHapus={hapusMenu} />
          )}
          {!dariKasvo && tab === "kategori" && (
            <TabKategori kategori={kategori} merchantId={merchant.id} onUbah={muatUlang} onEdit={setFormKat} onTambah={() => setFormKat({})} />
          )}
          {!dariKasvo && tab === "varian" && (
            <TabVarian grup={grup} menus={menus} onEdit={setFormGrup} onHapus={hapusGrup} onTambah={() => setFormGrup({})} />
          )}
        </>
      )}

      {formMenu && (
        <FormMenu awal={formMenu} merchantId={merchant.id} kategori={kategori} grup={grup}
          onTutup={() => setFormMenu(null)} onTersimpan={() => { setFormMenu(null); muatUlang(); }} />
      )}
      {formKat && (
        <FormKategori awal={formKat} merchantId={merchant.id} onTutup={() => setFormKat(null)} onTersimpan={() => { setFormKat(null); muatUlang(); }} />
      )}
      {formGrup && (
        <FormVarian awal={formGrup} merchantId={merchant.id} menus={menus} onTutup={() => setFormGrup(null)} onTersimpan={() => { setFormGrup(null); muatUlang(); }} />
      )}
      {imporBuka && (
        <ImporExcel merchantId={merchant.id} onTutup={() => setImporBuka(false)} onSelesai={() => { setImporBuka(false); muatUlang(); }} />
      )}
    </div>
  );
}
