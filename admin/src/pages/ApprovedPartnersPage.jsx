import { useEffect, useState } from "react";
import { CheckCircle, Store, KeyRound, Search, FileText, ShieldCheck } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

export default function ApprovedPartnersPage() {
  const [apps, setApps] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [typeFilter, setTypeFilter] = useState("");

  const load = () => {
    setLoading(true);
    // Fetch only approved partner applications
    api.getPartnerApplications({ status: "approved" }).then((d) => {
      setApps(d.applications || []);
      setLoading(false);
    });
  };

  useEffect(() => {
    load();
  }, []);

  // Filter applications
  const filtered = apps.filter((app) => {
    const matchesType = typeFilter === "" ? true : app.type === typeFilter;
    const matchesSearch =
      search === "" ||
      app.business_name?.toLowerCase().includes(search.toLowerCase()) ||
      app.name?.toLowerCase().includes(search.toLowerCase()) ||
      app.phone_number?.includes(search) ||
      app.email?.toLowerCase().includes(search.toLowerCase());
    return matchesType && matchesSearch;
  });

  // Calculate stats
  const totalCount = apps.length;
  const foodCount = apps.filter((a) => a.type === "food").length;
  const rentalCount = apps.filter((a) => a.type === "rental").length;

  return (
    <>
      <Topbar title="Mitra Disetujui" />
      <div className="page">
        <div className="page-header">
          <h1>Kemitraan Disetujui</h1>
          <p>Kelola dan pantau semua Mitra Resto Food & Mitra Rental Mobil yang aktif dalam sistem bohAntar</p>
        </div>

        {/* Stats Grid */}
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 16, marginBottom: 24 }}>
          {/* Card 1: Total */}
          <div className="card" style={{ display: "flex", alignItems: "center", gap: 16, padding: "20px 24px" }}>
            <div style={{ width: 48, height: 48, borderRadius: "50%", background: "var(--success-glow)", color: "var(--success)", display: "flex", alignItems: "center", justifyItems: "center", justifyContent: "center" }}>
              <ShieldCheck size={24} />
            </div>
            <div>
              <div style={{ fontSize: 13, color: "var(--text-muted)", fontWeight: 500 }}>Total Mitra Aktif</div>
              <div style={{ fontSize: 24, fontWeight: 800, color: "var(--text-primary)", marginTop: 2 }}>{totalCount}</div>
            </div>
          </div>
          {/* Card 2: Food */}
          <div className="card" style={{ display: "flex", alignItems: "center", gap: 16, padding: "20px 24px" }}>
            <div style={{ width: 48, height: 48, borderRadius: "50%", background: "rgba(245, 158, 11, 0.1)", color: "#d97706", display: "flex", alignItems: "center", justifyItems: "center", justifyContent: "center" }}>
              <Store size={24} />
            </div>
            <div>
              <div style={{ fontSize: 13, color: "var(--text-muted)", fontWeight: 500 }}>Mitra Resto Food</div>
              <div style={{ fontSize: 24, fontWeight: 800, color: "var(--text-primary)", marginTop: 2 }}>{foodCount}</div>
            </div>
          </div>
          {/* Card 3: Rental */}
          <div className="card" style={{ display: "flex", alignItems: "center", gap: 16, padding: "20px 24px" }}>
            <div style={{ width: 48, height: 48, borderRadius: "50%", background: "rgba(16, 185, 129, 0.1)", color: "#059669", display: "flex", alignItems: "center", justifyItems: "center", justifyContent: "center" }}>
              <KeyRound size={24} />
            </div>
            <div>
              <div style={{ fontSize: 13, color: "var(--text-muted)", fontWeight: 500 }}>Mitra Rental Mobil</div>
              <div style={{ fontSize: 24, fontWeight: 800, color: "var(--text-primary)", marginTop: 2 }}>{rentalCount}</div>
            </div>
          </div>
        </div>

        {/* Filter Bar */}
        <div className="filter-panel">
          {/* Filter Type */}
          <div style={{ display: "flex", gap: 8 }}>
            {[
              { value: "", label: "Semua Kemitraan", icon: null },
              { value: "food", label: "Mitra Resto Food", icon: Store },
              { value: "rental", label: "Mitra Rental Mobil", icon: KeyRound },
            ].map((f) => (
              <button
                key={f.value}
                className={`btn ${typeFilter === f.value ? "btn-primary" : "btn-ghost"}`}
                onClick={() => setTypeFilter(f.value)}
                style={{ display: "inline-flex", alignItems: "center", gap: 6, padding: "8px 14px", fontSize: 13, height: "auto" }}
              >
                {f.icon && <f.icon size={14} />}
                <span>{f.label}</span>
              </button>
            ))}
          </div>

          {/* Search bar */}
          <div className="filter-panel-search">
            <div className="search-bar">
              <Search size={15} style={{ color: "var(--text-muted)" }} />
              <input
                placeholder="Cari nama bisnis, pemilik, WhatsApp..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
          </div>
        </div>

        {/* Table list */}
        {loading ? (
          <div className="loading-overlay" style={{ minHeight: 200 }}>
            <div className="spinner" />
            <p>Memuat mitra...</p>
          </div>
        ) : (
          <div className="table-wrap">
            <div className="table-header">
              <h3>Total Terfilter: {filtered.length} mitra</h3>
            </div>
            <table>
              <thead>
                <tr>
                  <th>Nama Bisnis</th>
                  <th>Pemilik</th>
                  <th>Jenis Kemitraan</th>
                  <th>WhatsApp</th>
                  <th>Email</th>
                  <th>No. KTP</th>
                  <th>Alamat</th>
                  <th>Terdaftar</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {filtered.length === 0 ? (
                  <tr>
                    <td colSpan={9}>
                      <div className="empty-state" style={{ padding: "40px 0" }}>
                        <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                          <FileText size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                        </div>
                        <h3>Tidak ada mitra</h3>
                        <p>Belum ada mitra dengan kriteria pencarian tersebut</p>
                      </div>
                    </td>
                  </tr>
                ) : (
                  filtered.map((app) => {
                    const isFood = app.type === "food";
                    return (
                      <tr key={app.id}>
                        <td data-label="Nama Bisnis" style={{ fontWeight: 700, color: "var(--text-primary)" }}>{app.business_name}</td>
                        <td data-label="Pemilik">{app.name}</td>
                        <td data-label="Jenis Kemitraan">
                          <span className="badge" style={{ background: isFood ? "var(--warning-glow)" : "var(--success-glow)", color: isFood ? "#d97706" : "#059669", display: "inline-flex", alignItems: "center", gap: 4 }}>
                            {isFood ? <Store size={11} /> : <KeyRound size={11} />}
                            {isFood ? "Resto Food" : "Rental"}
                          </span>
                        </td>
                        <td data-label="WhatsApp">{app.phone_number}</td>
                        <td data-label="Email">{app.email || "—"}</td>
                        <td data-label="No. KTP">{app.ktp_number || "—"}</td>
                        <td data-label="Alamat" style={{ maxWidth: 220, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }} title={app.address}>
                          {app.address || "—"}
                        </td>
                        <td data-label="Terdaftar">{new Date(app.created_at).toLocaleDateString("id-ID")}</td>
                        <td data-label="Status">
                          <span className="badge badge-success" style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
                            <CheckCircle size={11} />
                            Aktif
                          </span>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}
