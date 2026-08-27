import { useState, useEffect } from "react";
import { Plus, Trash2, Salad, Save, Shield } from "lucide-react";
import { BASE, authFetch } from "../../api";
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
  const [isAvailable, setIsAvailable] = useState(true);
  const [error, setError] = useState("");

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
      setError("Profil restoran belum lengkap. Silakan lengkapi di halaman Dashboard terlebih dahulu!");
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
      message: "Menu akan hilang dari daftar jualan restoran Anda dan tidak bisa dikembalikan.",
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

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1>Kelola Daftar Menu Jualan</h1>
          <p>Tambahkan, edit ketersediaan, serta atur harga jualan menu kuliner Anda</p>
        </div>
        <button onClick={() => setShowAddForm(!showAddForm)} className="btn btn-primary" style={{ background: "#F59E0B" }}>
          <Plus size={18} /> {showAddForm ? "Tutup Form" : "Tambah Menu"}
        </button>
      </div>

      {showAddForm && (
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
              <label>Link Foto Makanan (URL)</label>
              <input className="input" placeholder="https://images.unsplash.com/..." value={imageUrl} onChange={e => setImageUrl(e.target.value)} />
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
          <h3>Profil Restoran Belum Lengkap</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>Silakan lengkapi profil restoran Anda terlebih dahulu di menu Dashboard agar bisa mengelola menu jualan.</p>
        </div>
      ) : menus.length === 0 ? (
        <div className="card" style={{ textAlign: "center", padding: 50, color: "var(--text-muted)" }}>
          <Salad size={48} style={{ margin: "0 auto 16px", color: "var(--border)" }} />
          <h3>Daftar Menu Masih Kosong</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>Klik tombol Tambah Menu untuk menambahkan menu jualan pertama Anda</p>
        </div>
      ) : (
        <div className="grid-3">
          {menus.map(menu => (
            <div key={menu.id} className="card" style={{ padding: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
              <div style={{ height: 180, width: "100%", overflow: "hidden", background: "#334155", position: "relative" }}>
                <img 
                  src={menu.image_url} 
                  alt={menu.name}
                  style={{ width: "100%", height: "100%", objectFit: "cover" }}
                  onError={(e) => {
                    e.target.src = "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=200";
                  }}
                />
                <span className={`badge ${menu.is_available ? "badge-success" : "badge-danger"}`} style={{ position: "absolute", top: 12, right: 12, background: menu.is_available ? "rgba(16,185,129,0.9)" : "rgba(239,68,68,0.9)", color: "white" }}>
                  {menu.is_available ? "TERSEDIA" : "HABIS"}
                </span>
              </div>
              <div style={{ padding: 20, flex: 1, display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
                <div>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "start" }}>
                    <h3 style={{ fontSize: 18, fontWeight: 800 }}>{menu.name}</h3>
                    <span className="badge badge-info" style={{ background: "rgba(245,158,11,0.15)", color: "#F59E0B" }}>{menu.category}</span>
                  </div>
                  <p style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 6, marginBottom: 16 }}>
                    {menu.description || "Tidak ada deskripsi"}
                  </p>
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", borderTop: "1px solid var(--border)", paddingTop: 16 }}>
                  <div>
                    <span style={{ fontSize: 11, color: "var(--text-muted)" }}>Harga Menu</span>
                    <div style={{ fontSize: 18, fontWeight: 900, color: "#F59E0B" }}>
                      Rp {menu.price.toLocaleString("id-ID")}
                    </div>
                  </div>
                  <button onClick={() => handleDelete(menu.id)} className="btn btn-danger btn-sm" style={{ padding: 8 }}>
                    <Trash2 size={16} />
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
