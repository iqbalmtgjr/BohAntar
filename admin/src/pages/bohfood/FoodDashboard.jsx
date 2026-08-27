import { useState, useEffect } from "react";
import { Store, MapPin, Clock, Salad, Plus, Save, CheckCircle, Power, Tag } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { toast } from "../../components/Feedback";

/* Ilustrasi tudung saji: SVG murni supaya tetap tajam di layar HD/retina.
   Padanan WalletArt di dashboard bohRental. */
function ClocheArt() {
  return (
    <svg
      viewBox="0 0 128 128"
      width="106"
      height="106"
      aria-hidden="true"
      style={{
        position: "absolute",
        right: -10,
        bottom: -14,
        zIndex: 1,
        transform: "rotate(-6deg)",
        filter: "drop-shadow(0 12px 16px rgba(87, 32, 4, 0.45))"
      }}
    >
      <defs>
        <linearGradient id="bohDome" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#FFFDF6" />
          <stop offset="55%" stopColor="#FFE7BE" />
          <stop offset="100%" stopColor="#F6BE72" />
        </linearGradient>
        <linearGradient id="bohPlate" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#FFFFFF" />
          <stop offset="100%" stopColor="#F2CE99" />
        </linearGradient>
        <linearGradient id="bohKnob" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#F59E0B" />
          <stop offset="100%" stopColor="#B45309" />
        </linearGradient>
      </defs>

      {/* uap */}
      <path d="M50 30 q7 -9 0 -18" stroke="#FFFFFF" strokeWidth="3.5" strokeLinecap="round" fill="none" opacity="0.45" />
      <path d="M64 26 q7 -10 0 -20" stroke="#FFFFFF" strokeWidth="3.5" strokeLinecap="round" fill="none" opacity="0.6" />
      <path d="M78 30 q7 -9 0 -18" stroke="#FFFFFF" strokeWidth="3.5" strokeLinecap="round" fill="none" opacity="0.45" />

      {/* tudung saji */}
      <path d="M20 88 a44 44 0 0 1 88 0 z" fill="url(#bohDome)" />
      <ellipse cx="50" cy="62" rx="16" ry="9" fill="#FFFFFF" opacity="0.45" transform="rotate(-28 50 62)" />
      <circle cx="64" cy="46" r="6" fill="url(#bohKnob)" />

      {/* piring */}
      <rect x="12" y="88" width="104" height="11" rx="5.5" fill="url(#bohPlate)" />
      <ellipse cx="64" cy="105" rx="44" ry="4.5" fill="#7C2D12" opacity="0.22" />
    </svg>
  );
}

export default function FoodDashboard({ ownerPhone }) {
  const [merchant, setMerchant] = useState(null);
  const [loading, setLoading] = useState(true);
  const [menus, setMenus] = useState([]);

  // Form states
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [imageUrl, setImageUrl] = useState("");
  const [isOpen, setIsOpen] = useState(true);
  const [saving, setSaving] = useState(false);

  const fetchMerchantAndMenus = () => {
    authFetch(`${BASE}/food/merchant?owner_phone=${encodeURIComponent(ownerPhone)}`)
      .then(async r => {
        if (r.status === 404) {
          return null; // Merchant doesn't exist yet
        }
        return r.json();
      })
      .then(mdata => {
        if (mdata) {
          setMerchant(mdata);
          setName(mdata.restaurant_name);
          setAddress(mdata.address);
          setImageUrl(mdata.image_url);
          setIsOpen(mdata.is_open);

          // Fetch menus
          return authFetch(`${BASE}/food/menus?merchant_id=${mdata.id}`)
            .then(r => r.json())
            .then(menusData => setMenus(Array.isArray(menusData) ? menusData : []));
        }
        setLoading(false);
      })
      .then(() => setLoading(false))
      .catch(err => {
        console.error(err);
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchMerchantAndMenus();
  }, [ownerPhone]);

  const handleSaveMerchant = (e) => {
    e.preventDefault();
    setSaving(true);

    const payload = {
      id: merchant ? merchant.id : "",
      owner_phone: ownerPhone,
      restaurant_name: name,
      address,
      image_url: imageUrl || "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400",
      is_open: isOpen
    };

    authFetch(`${BASE}/food/merchant`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    })
      .then(r => r.json())
      .then(data => {
        setMerchant(data);
        setSaving(false);
        toast.success("Profil toko berhasil diperbarui");
      })
      .catch(err => {
        setSaving(false);
        toast.error(err.message || "Gagal menyimpan profil toko");
      });
  };

  const toggleShopStatus = () => {
    if (!merchant) return;
    const updatedStatus = !isOpen;
    setIsOpen(updatedStatus);

    authFetch(`${BASE}/food/merchant`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...merchant,
        is_open: updatedStatus
      })
    })
      .then(r => r.json())
      .then(data => {
        setMerchant(data);
        toast.success(updatedStatus ? "Toko sekarang BUKA" : "Toko sekarang TUTUP");
      })
      .catch(err => {
        // Status di server gagal berubah; kembalikan tombol ke keadaan sebenarnya.
        setIsOpen(!updatedStatus);
        toast.error(err.message || "Gagal mengubah status toko");
      });
  };

  if (loading) {
    return <div className="page"><div className="spinner" style={{ margin: "100px auto" }}></div></div>;
  }

  // Metrik untuk strip statistik mobile
  const availableCount = menus.filter(m => m.is_available).length;
  const avgPrice = menus.length
    ? Math.round(menus.reduce((sum, m) => sum + (m.price || 0), 0) / menus.length)
    : 0;
  const avgPriceLabel = avgPrice >= 1000
    ? `Rp ${Math.round(avgPrice / 1000)}rb`
    : `Rp ${avgPrice.toLocaleString("id-ID")}`;

  return (
    <div className="page">
      <div className="page-header dash-header">
        <h1>Dashboard bohFood</h1>
        <p>Kelola kedai kuliner dan pantau menu penjualan Anda</p>
      </div>

      {/* ===== MOBILE: kartu status toko + strip statistik ===== */}
      {merchant && (
        <div className="portal-mobile-only">
          <div style={{
            position: "relative",
            overflow: "hidden",
            borderRadius: 24,
            padding: "20px 20px 24px",
            color: "#fff",
            background: "linear-gradient(135deg, #FBBF24 0%, #F59E0B 45%, #C2410C 100%)",
            boxShadow: "0 20px 34px -18px rgba(194, 65, 12, 0.9), 0 2px 8px -2px rgba(15, 23, 42, 0.18)"
          }}>
            {/* cahaya dekoratif */}
            <div style={{
              position: "absolute", top: -80, right: -60, width: 200, height: 200, borderRadius: "50%",
              background: "radial-gradient(circle at 30% 30%, rgba(255,255,255,0.32), rgba(255,255,255,0) 70%)"
            }} />
            <div style={{
              position: "absolute", bottom: -100, left: -50, width: 210, height: 210, borderRadius: "50%",
              background: "radial-gradient(circle, rgba(254,215,170,0.40), rgba(254,215,170,0) 70%)"
            }} />

            <ClocheArt />

            <div style={{ position: "relative", zIndex: 2 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <div style={{
                  width: 34, height: 34, borderRadius: 11, flexShrink: 0,
                  display: "flex", alignItems: "center", justifyContent: "center",
                  background: "rgba(255,255,255,0.18)", border: "1px solid rgba(255,255,255,0.28)"
                }}>
                  <Store size={18} />
                </div>
                <div style={{
                  fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: "uppercase",
                  color: "rgba(255,255,255,0.88)"
                }}>
                  Status Toko
                </div>
                <button
                  onClick={toggleShopStatus}
                  aria-label={isOpen ? "Tutup toko" : "Buka toko"}
                  title={isOpen ? "Tutup toko" : "Buka toko"}
                  style={{
                    marginLeft: "auto", width: 32, height: 32, borderRadius: 10, cursor: "pointer",
                    display: "flex", alignItems: "center", justifyContent: "center",
                    background: "rgba(255,255,255,0.14)", border: "1px solid rgba(255,255,255,0.22)", color: "#fff"
                  }}
                >
                  <Power size={16} />
                </button>
              </div>

              {/* sisakan ruang kanan untuk ilustrasi tudung saji */}
              <div style={{ marginTop: 16, maxWidth: "calc(100% - 84px)" }}>
                <div style={{ fontSize: "clamp(22px, 7vw, 32px)", fontWeight: 800, letterSpacing: -0.6, lineHeight: 1.1, whiteSpace: "nowrap" }}>
                  {isOpen ? "Toko Buka" : "Toko Tutup"}
                </div>
                <div style={{ fontSize: 12, color: "rgba(255,255,255,0.82)", marginTop: 4 }}>
                  {isOpen ? "Sedang menerima pesanan" : "Sementara tidak menerima pesanan"}
                </div>
              </div>

              <div style={{ marginTop: 18, display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", maxWidth: "calc(100% - 84px)" }}>
                <span style={{
                  display: "inline-flex", alignItems: "center", gap: 5,
                  fontSize: 11, fontWeight: 700, padding: "5px 10px", borderRadius: 999,
                  background: "rgba(255,255,255,0.16)", border: "1px solid rgba(255,255,255,0.24)"
                }}>
                  <Salad size={13} /> {menus.length} menu terdaftar
                </span>
                <span style={{ fontSize: 11, color: "rgba(255,255,255,0.75)" }}>{name}</span>
              </div>
            </div>
          </div>

          {/* strip statistik yang menimpa kartu status */}
          <div style={{
            position: "relative", zIndex: 3, margin: "-20px 10px 22px",
            display: "grid", gridTemplateColumns: "repeat(3, 1fr)",
            background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 18,
            boxShadow: "0 12px 26px -16px rgba(15, 23, 42, 0.45)", overflow: "hidden"
          }}>
            {[
              { icon: Salad, label: "Menu", value: menus.length, tint: "rgba(217, 119, 6, 0.12)", color: "#D97706" },
              { icon: CheckCircle, label: "Tersedia", value: availableCount, tint: "rgba(5, 150, 105, 0.12)", color: "#059669" },
              { icon: Tag, label: "Rata Harga", value: avgPriceLabel, tint: "rgba(37, 99, 235, 0.10)", color: "#2563EB" }
            ].map((s, i) => (
              <div key={s.label} style={{ padding: "15px 6px 13px", textAlign: "center", borderLeft: i ? "1px solid var(--border)" : "none" }}>
                <div style={{
                  width: 34, height: 34, margin: "0 auto 8px", borderRadius: 11,
                  background: s.tint, color: s.color,
                  display: "flex", alignItems: "center", justifyContent: "center"
                }}>
                  <s.icon size={17} />
                </div>
                <div style={{ fontSize: 19, fontWeight: 800, lineHeight: 1.1, color: "var(--text-primary)" }}>{s.value}</div>
                <div style={{
                  fontSize: 10, fontWeight: 700, letterSpacing: 0.4, textTransform: "uppercase",
                  color: "var(--text-muted)", marginTop: 3
                }}>
                  {s.label}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="grid-3" style={{ gridTemplateColumns: "1fr 2fr", gap: 24, alignItems: "start" }}>
        
        {/* Left Card: Resto Profile Management */}
        <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
          <div className="card">
            <div className="card-title" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <span>Profil Restoran</span>
              {merchant && (
                <button 
                  onClick={toggleShopStatus}
                  className={`btn btn-sm ${isOpen ? "btn-success" : "btn-danger"}`}
                  style={{ fontSize: 11 }}
                >
                  {isOpen ? "Toko BUKA" : "Toko TUTUP"}
                </button>
              )}
            </div>

            <form onSubmit={handleSaveMerchant}>
              <div className="input-group">
                <label>Nama Kedai / Restoran</label>
                <input className="input" placeholder="Contoh: Soto Mak Nyus" value={name} onChange={e => setName(e.target.value)} required />
              </div>
              <div className="input-group">
                <label>Alamat Restoran</label>
                <textarea className="input" placeholder="Jl. Gajah Mada No. 12, Pontianak" value={address} onChange={e => setAddress(e.target.value)} required style={{ resize: "none", height: 80 }} />
              </div>
              <div className="input-group">
                <label>Foto Banner Resto (URL)</label>
                <input className="input" placeholder="https://images.unsplash.com/..." value={imageUrl} onChange={e => setImageUrl(e.target.value)} />
              </div>

              <button type="submit" className="btn btn-primary" style={{ background: "#F59E0B", width: "100%", justifyContent: "center", padding: 12 }} disabled={saving}>
                <Save size={16} /> {saving ? "Menyimpan..." : "Simpan Profil Resto"}
              </button>
            </form>
          </div>
        </div>

        {/* Right Section: Statistics & Summary */}
        <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
          {merchant ? (
            <>
              {/* Stats overview (desktop; di mobile diganti kartu status + strip statistik) */}
              <div className="grid-2 portal-desktop-only">
                <div className="stat-card" style={{ border: "1px solid rgba(245,158,11,0.2)" }}>
                  <div className="stat-icon" style={{ background: "rgba(245,158,11,0.1)", color: "#F59E0B" }}>
                    <Salad size={24} />
                  </div>
                  <div>
                    <div className="stat-label">Total Menu Jualan</div>
                    <div className="stat-value">{menus.length} Item</div>
                  </div>
                </div>

                <div className="stat-card" style={{ border: `1px solid ${isOpen ? "rgba(16,185,129,0.2)" : "rgba(239,68,68,0.2)"}` }}>
                  <div className="stat-icon" style={{ background: isOpen ? "rgba(16,185,129,0.1)" : "rgba(239,68,68,0.1)", color: isOpen ? "#10B981" : "#EF4444" }}>
                    <Store size={24} />
                  </div>
                  <div>
                    <div className="stat-label">Status Toko</div>
                    <div className="stat-value">{isOpen ? "Buka (Menerima Order)" : "Tutup Sementara"}</div>
                  </div>
                </div>
              </div>

              {/* Cover Banner */}
              <div className="card" style={{ padding: 0, overflow: "hidden", position: "relative" }}>
                <div style={{ height: 260, background: "#1E293B" }}>
                  <img 
                    src={imageUrl || "https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=600"} 
                    alt={name} 
                    style={{ width: "100%", height: "100%", objectFit: "cover", opacity: 0.8 }}
                  />
                  <div style={{ position: "absolute", bottom: 0, left: 0, right: 0, background: "linear-gradient(to top, rgba(15,23,42,0.9) 0%, rgba(15,23,42,0) 100%)", padding: 24, display: "flex", flexDirection: "column", gap: 6 }}>
                    <h2 style={{ fontSize: 24, fontWeight: 900, color: "white" }}>{name}</h2>
                    <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: "var(--text-secondary)" }}>
                      <MapPin size={15} style={{ color: "#F59E0B" }} />
                      <span>{address}</span>
                    </div>
                  </div>
                </div>
              </div>
            </>
          ) : (
            <div className="card" style={{ textAlign: "center", padding: "60px 40px" }}>
              <Store size={48} style={{ color: "var(--border)", margin: "0 auto 16px" }} />
              <h2>Lengkapi Profil Restoran Pertama Anda</h2>
              <p style={{ color: "var(--text-secondary)", fontSize: 13, marginTop: 4, maxWidth: 400, margin: "8px auto 20px" }}>
                Anda belum menginput data toko jualan Anda. Silakan isi form di sebelah kiri untuk mengaktifkan dashboard bohFood Anda.
              </p>
            </div>
          )}
        </div>

      </div>
    </div>
  );
}
