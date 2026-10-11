import { useState, useEffect } from "react";
import { Plus, Trash2, Salad, Save, Shield, Search } from "lucide-react";
import { BASE, authFetch, api, fileURL } from "../../api";

// Foto dari unggahan disimpan sebagai "/uploads/..."; tautan luar apa adanya.
const urlFoto = (u) => (u && u.startsWith("/uploads/") ? fileURL(u) : u);
import { hargaMulaiDari, hargaBisaNaik } from "./harga";
import { toast, confirmDialog, Alert } from "../../components/Feedback";

export default function MenuManagement({ ownerPhone }) {
  const [merchant, setMerchant] = useState(null);
  const [menus, setMenus] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showAddForm, setShowAddForm] = useState(false);

  // Form states
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [price, setPrice] = useState(15000);
  const [category, setCategory] = useState("Makanan");
  const [imageUrl, setImageUrl] = useState("");
  const [mengunggah, setMengunggah] = useState(false);
  const [isAvailable, setIsAvailable] = useState(true);
  const [error, setError] = useState("");
  const [cari, setCari] = useState("");

  const fetchMerchantAndMenus = () => {
    setLoading(true);
    authFetch(`${BASE}/food/merchant?owner_phone=${encodeURIComponent(ownerPhone)}`)
      .then(async r => {
        if (r.status === 404) return null;
        return r.json();
      })
      .then(mdata => {
        if (mdata) {
          setMerchant(mdata);
          // Fetch menus
          return authFetch(`${BASE}/food/menus?merchant_id=${mdata.id}`)
            .then(r => r.json())
            .then(menusData => {
              setMenus(Array.isArray(menusData) ? menusData : []);
              setLoading(false);
            });
        } else {
          setLoading(false);
        }
      })
      .catch(err => {
        console.error(err);
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchMerchantAndMenus();
  }, [ownerPhone]);

  const handleSubmit = (e) => {
    e.preventDefault();
    setError("");

    if (!name || !price) {
      setError("Nama menu dan harga sewa wajib diisi");
      return;
    }

    if (!merchant) {
      setError("Profil warung belum lengkap. Lengkapi dulu di halaman Dashboard.");
      return;
    }

    const payload = {
      merchant_id: merchant.id,
      name,
      description,
      price: parseFloat(price),
      category,
      image_url: imageUrl || "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=100",
      is_available: isAvailable
    };

    authFetch(`${BASE}/food/menus`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    })
      .then(r => r.json())
      .then(() => {
        // Clear form
        setName("");
        setDescription("");
        setPrice(15000);
        setCategory("Makanan");
        setImageUrl("");
        setIsAvailable(true);
        setShowAddForm(false);
        // Refresh menus
        fetchMerchantAndMenus();
        toast.success("Menu berhasil ditambahkan");
      })
      .catch(err => setError(err.message || "Gagal menyimpan menu"));
  };

  const handleDelete = async (id) => {
    const ok = await confirmDialog({
      title: "Hapus menu ini?",
      message: "Menu akan hilang dari daftar jualan warung Anda dan tidak bisa dikembalikan.",
      confirmText: "Hapus menu",
    });
    if (!ok) return;
    authFetch(`${BASE}/food/menus/${id}`, { method: "DELETE" })
      .then(r => r.json())
      .then(() => {
        fetchMerchantAndMenus();
        toast.success("Menu berhasil dihapus");
      })
      .catch(err => toast.error(err.message || "Gagal menghapus menu"));
  };

  // Toko Kasvo: menu dibaca langsung dari kasirnya, jadi di sini hanya dilihat.
  const dariKasvo = !!merchant?.kasvo_toko_uuid;

  const kata = cari.trim().toLowerCase();
  const tampil = kata ? menus.filter(m => `${m.name} ${m.category}`.toLowerCase().includes(kata)) : menus;

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1>Kelola Daftar Menu Jualan</h1>
          <p>{dariKasvo ? "Menu warung ini mengikuti Kasvo" : "Tambahkan, edit ketersediaan, serta atur harga jualan menu kuliner Anda"}</p>
        </div>
        {!dariKasvo && (
          <button onClick={() => setShowAddForm(!showAddForm)} className="btn btn-primary" style={{ background: "#F59E0B" }}>
            <Plus size={18} /> {showAddForm ? "Tutup Form" : "Tambah Menu"}
          </button>
        )}
      </div>

      {dariKasvo && (
        <div className="card" style={{ marginBottom: 20, fontSize: 13 }}>
          Menu, harga, varian, dan stok habis diatur di <b>Kasvo</b> dan langsung berlaku di bohFood.
          Yang tampil hanya menu yang aktif dan tampil ke publik di Kasvo.
        </div>
      )}

      {showAddForm && !dariKasvo && (
        <div className="card" style={{ marginBottom: 28, maxWidth: 600 }}>
          <div className="card-title">Form Tambah Menu Jualan Baru</div>
          <Alert type="error">{error}</Alert>
          <form onSubmit={handleSubmit}>
            <div className="grid-2">
              <div className="input-group">
                <label>Nama Makanan / Minuman</label>
                <input className="input" placeholder="Contoh: Soto Ayam Lamongan" value={name} onChange={e => setName(e.target.value)} required />
              </div>
              <div className="input-group">
                <label>Kategori</label>
                <select className="input" value={category} onChange={e => setCategory(e.target.value)}>
                  <option value="Makanan">Makanan</option>
                  <option value="Minuman">Minuman</option>
                  <option value="Cemilan">Cemilan / Snack</option>
                </select>
              </div>
            </div>

            <div className="grid-2">
              <div className="input-group">
                <label>Harga Jual (Rp)</label>
                <input className="input" type="number" step="1000" min="1000" value={price} onChange={e => setPrice(e.target.value)} required />
              </div>
              <div className="input-group" style={{ display: "flex", flexDirection: "column", justifyContent: "center" }}>
                <label style={{ marginBottom: 10 }}>Ketersediaan Menu</label>
                <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13, fontWeight: 500 }}>
                  <input type="checkbox" checked={isAvailable} onChange={e => setIsAvailable(e.target.checked)} style={{ width: 18, height: 18 }} />
                  Tersedia untuk Dipesan
                </label>
              </div>
            </div>

            <div className="input-group">
              <label>Deskripsi Menu Makanan</label>
              <input className="input" placeholder="Soto ayam hangat dengan koya melimpah" value={description} onChange={e => setDescription(e.target.value)} />
            </div>

            <div className="input-group">
              <label>Foto Makanan</label>
              {imageUrl && (
                <img src={urlFoto(imageUrl)} alt="" style={{ width: 120, height: 90, objectFit: "cover", borderRadius: 10, marginBottom: 8, display: "block" }} />
              )}
              <label className="btn btn-sm" style={{ cursor: mengunggah ? "wait" : "pointer", display: "inline-flex" }}>
                {mengunggah ? "Mengunggah..." : imageUrl ? "Ganti foto" : "Unggah foto"}
                <input
                  type="file" accept="image/*" hidden disabled={mengunggah}
                  onChange={e => {
                    const berkas = e.target.files?.[0];
                    e.target.value = "";
                    if (!berkas) return;
                    setMengunggah(true);
                    api.uploadFile(berkas)
                      .then(res => { if (!res.url) throw new Error(res.error || "Gagal mengunggah foto"); setImageUrl(res.url); })
                      .catch(err => toast.error(err.message || "Gagal mengunggah foto"))
                      .finally(() => setMengunggah(false));
                  }}
                />
              </label>
            </div>

            <button type="submit" className="btn btn-primary" style={{ background: "#F59E0B", width: "100%", justifyContent: "center", padding: 12 }}>
              Daftarkan Menu
            </button>
          </form>
        </div>
      )}

      {loading ? (
        <div className="spinner" style={{ margin: "50px auto" }}></div>
      ) : !merchant ? (
        <div className="card" style={{ textAlign: "center", padding: 50, color: "var(--text-muted)" }}>
          <Salad size={48} style={{ margin: "0 auto 16px", color: "var(--border)" }} />
          <h3>Profil Warung Belum Lengkap</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>Lengkapi profil warung di halaman Dashboard dulu supaya bisa mengelola menu.</p>
        </div>
      ) : menus.length === 0 ? (
        <div className="card" style={{ textAlign: "center", padding: 50, color: "var(--text-muted)" }}>
          <Salad size={48} style={{ margin: "0 auto 16px", color: "var(--border)" }} />
          <h3>Daftar Menu Masih Kosong</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>
            {dariKasvo ? "Belum ada menu yang aktif dan tampil ke publik di Kasvo" : "Klik tombol Tambah Menu untuk menambahkan menu jualan pertama Anda"}
          </p>
        </div>
      ) : (
        // Daftar berbaris, bukan kartu: toko Kasvo bisa punya puluhan menu, dan
        // pemilik mencari nama/harga, bukan memandangi foto besar.
        <div className="table-wrap">
          <div className="table-header" style={{ gap: 12, flexWrap: "wrap" }}>
            <h3>{tampil.length === menus.length ? `${menus.length} menu` : `${tampil.length} dari ${menus.length} menu`}</h3>
            <div className="search-bar">
              <Search size={15} style={{ color: "var(--text-muted)" }} />
              <input placeholder="Cari menu atau kategori..." value={cari} onChange={e => setCari(e.target.value)} />
            </div>
          </div>
          {tampil.length === 0 && (
            <p style={{ padding: "32px 20px", textAlign: "center", fontSize: 13, color: "var(--text-muted)" }}>Tidak ada menu yang cocok dengan "{cari}"</p>
          )}
          {tampil.map((menu, i) => {
            const grup = menu.option_groups || [];
            const satuBaris = { margin: 0, fontSize: 12, color: "var(--text-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" };
            return (
              <div key={menu.id} style={{ display: "flex", alignItems: "flex-start", gap: 12, padding: "12px 20px", borderBottom: i < tampil.length - 1 ? "1px solid var(--border)" : "none", opacity: menu.is_available ? 1 : 0.6 }}>
                <img
                  src={urlFoto(menu.image_url)}
                  alt=""
                  loading="lazy"
                  style={{ width: 52, height: 52, flexShrink: 0, objectFit: "cover", borderRadius: 10, background: "var(--bg-input)" }}
                  onError={(e) => { e.target.style.visibility = "hidden"; }}
                />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <b style={{ display: "block", fontSize: 14, lineHeight: 1.35 }}>{menu.name}</b>
                  <p style={satuBaris} title={menu.description}>
                    <span style={{ color: "var(--text-muted)", fontWeight: 600 }}>{menu.category}</span>
                    {menu.description && ` · ${menu.description}`}
                  </p>
                  {grup.length > 0 && (
                    // Menu Kasvo bisa punya 5 grup varian berisi puluhan opsi:
                    // ringkas nama grupnya, rinciannya dibuka kalau perlu.
                    <details style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 2 }}>
                      <summary style={{ ...satuBaris, cursor: "pointer", color: "var(--primary)" }}>
                        {grup.length} varian: {grup.map(g => g.name).join(", ")}
                      </summary>
                      {grup.map(g => (
                        <p key={g.id} style={{ margin: "4px 0 0" }}>
                          <b>{g.name}{g.required ? " (wajib)" : ""}:</b>{" "}
                          {g.options.map(o => o.price > 0 ? `${o.name} +Rp${o.price.toLocaleString("id-ID")}` : o.name).join(", ")}
                        </p>
                      ))}
                    </details>
                  )}
                </div>
                <div style={{ textAlign: "right", flexShrink: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 700, whiteSpace: "nowrap" }}>
                    {hargaBisaNaik(menu) && <span style={{ fontSize: 11, fontWeight: 500, color: "var(--text-muted)" }}>mulai </span>}
                    Rp{hargaMulaiDari(menu).toLocaleString("id-ID")}
                  </div>
                  <span className={`badge ${menu.is_available ? "badge-success" : "badge-danger"}`} style={{ padding: "1px 8px", marginTop: 4 }}>
                    {menu.is_available ? "Tersedia" : "Habis"}
                  </span>
                </div>
                {!dariKasvo && (
                  <button onClick={() => handleDelete(menu.id)} className="btn btn-danger btn-sm" style={{ padding: 8, flexShrink: 0 }} aria-label={`Hapus ${menu.name}`} title="Hapus menu">
                    <Trash2 size={16} />
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
