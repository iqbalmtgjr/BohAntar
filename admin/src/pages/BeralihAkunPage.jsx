import { useEffect, useState } from "react";
import { Store, KeyRound, Search, LogIn } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

/* Super admin masuk ke portal mitra BohFood/BohRental untuk membantu mereka
   (impor menu, input kendaraan) tanpa meminta password. Selama di dalam, pita
   di atas portal menyediakan tombol kembali ke Super Admin (App.jsx). */
export default function BeralihAkunPage({ onMasuk }) {
  const [mitra, setMitra] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [sedangMasuk, setSedangMasuk] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    // ponytail: limit 1000 sekali ambil; beri halaman kalau mitra sudah ribuan.
    Promise.all([
      api.getUsers("food_merchant", 1, 1000),
      api.getUsers("rental_partner", 1, 1000),
      api.getPartnerApplications({ status: "approved" }),
    ]).then(([food, rental, apps]) => {
      const usaha = {};
      (apps.applications || []).forEach((a) => { usaha[a.phone_number] = a.business_name; });
      setMitra([...(food.users || []), ...(rental.users || [])].map((u) => ({ ...u, usaha: usaha[u.phone_number] || "" })));
    }).catch(() => setError("Daftar mitra gagal dimuat. Muat ulang halaman."))
      .finally(() => setLoading(false));
  }, []);

  const q = search.toLowerCase();
  const filtered = mitra.filter((m) =>
    !q || m.usaha.toLowerCase().includes(q) || m.name?.toLowerCase().includes(q) ||
    m.phone_number.includes(q) || m.email?.toLowerCase().includes(q));

  const masuk = async (m) => {
    setSedangMasuk(m.phone_number);
    setError("");
    try {
      const res = await api.masukSebagai(m.phone_number);
      if (!res.token) throw new Error(res.error || "Gagal masuk ke akun mitra");
      onMasuk(res.role === "food_merchant" ? "food" : "rental", res.phone, res.token);
    } catch (e) {
      setError(e.message);
      setSedangMasuk("");
    }
  };

  return (
    <>
      <Topbar title="Masuk Akun Mitra" />
      <div className="page">
        <div className="page-header">
          <h1>Masuk Akun Mitra</h1>
          <p>Buka portal mitra BohFood atau BohRental untuk membantu impor menu atau input kendaraan. Tekan "Kembali ke Super Admin" di pita atas untuk keluar.</p>
        </div>

        <div className="filter-panel">
          <div className="filter-panel-search">
            <div className="search-bar">
              <Search size={15} style={{ color: "var(--text-muted)" }} />
              <input placeholder="Cari nama usaha, pemilik, WhatsApp, email..." value={search} onChange={(e) => setSearch(e.target.value)} />
            </div>
          </div>
        </div>

        {error && <div className="card" style={{ color: "var(--danger)", marginBottom: 16, padding: "12px 16px" }}>{error}</div>}

        {loading ? (
          <div className="loading-overlay" style={{ minHeight: 200 }}><div className="spinner" /><p>Memuat mitra...</p></div>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>Nama Usaha</th><th>Pemilik</th><th>Jenis</th><th>WhatsApp</th><th>Email</th><th></th></tr>
              </thead>
              <tbody>
                {filtered.length === 0 ? (
                  <tr><td colSpan={6}><div className="empty-state" style={{ padding: "40px 0" }}><h3>Tidak ada mitra</h3></div></td></tr>
                ) : filtered.map((m) => {
                  const isFood = m.role === "food_merchant";
                  return (
                    <tr key={m.phone_number}>
                      <td data-label="Nama Usaha" style={{ fontWeight: 700, color: "var(--text-primary)" }}>{m.usaha || "—"}</td>
                      <td data-label="Pemilik">{m.name}</td>
                      <td data-label="Jenis">
                        <span className="badge" style={{ background: isFood ? "var(--warning-glow)" : "var(--success-glow)", color: isFood ? "#d97706" : "#059669", display: "inline-flex", alignItems: "center", gap: 4 }}>
                          {isFood ? <Store size={11} /> : <KeyRound size={11} />}
                          {isFood ? "BohFood" : "BohRental"}
                        </span>
                      </td>
                      <td data-label="WhatsApp">{m.phone_number}</td>
                      <td data-label="Email">{m.email || "—"}</td>
                      <td>
                        <button className="btn btn-primary" disabled={!!sedangMasuk} onClick={() => masuk(m)}
                          style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "6px 12px", fontSize: 13, height: "auto" }}>
                          <LogIn size={14} />{sedangMasuk === m.phone_number ? "Masuk..." : "Masuk"}
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
