import { useEffect, useState } from "react";
import { Search, Package } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

const STATUS_BADGE = {
  pending: "badge-warning", accepted: "badge-info", picked_up: "badge-info",
  completed: "badge-success", cancelled: "badge-danger",
};
const STATUS_LABEL = {
  pending: "Menunggu", accepted: "Diterima", picked_up: "Diambil",
  completed: "Selesai", cancelled: "Dibatalkan",
};

export default function OrdersPage() {
  const [orders, setOrders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState("");
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [limit, setLimit] = useState(10);
  const [totalRecords, setTotalRecords] = useState(0);

  const load = (status = filter, p = page, l = limit) => {
    setLoading(true);
    const params = { page: p, limit: l };
    if (status) params.status = status;
    api.getOrders(params).then(d => { 
      setOrders(d.orders || []); 
      if (d.pagination) {
        setPage(d.pagination.page);
        setTotalPages(d.pagination.total_pages);
        setTotalRecords(d.pagination.total);
      }
      setLoading(false); 
    });
  };

  useEffect(() => { load(filter, 1, limit); }, []);

  const filtered = orders.filter(o =>
    o.id?.toLowerCase().includes(search.toLowerCase()) ||
    o.rider_name?.toLowerCase().includes(search.toLowerCase()) ||
    o.driver_name?.toLowerCase().includes(search.toLowerCase()) ||
    o.pickup?.toLowerCase().includes(search.toLowerCase()) ||
    o.dropoff?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <>
      <Topbar title="Pesanan" />
      <div className="page">
        <div className="page-header"><h1>Semua Pesanan</h1><p>Monitor dan kelola alur pesanan bohAntar</p></div>
        <div className="filter-bar">
          {["", "pending", "accepted", "picked_up", "completed", "cancelled"].map(s => (
            <button key={s} className={`filter-btn${filter === s ? " active" : ""}`} onClick={() => { setFilter(s); setPage(1); load(s, 1, limit); }}>
              {s === "" ? "Semua" : STATUS_LABEL[s]}
            </button>
          ))}
          <div style={{ marginLeft: "auto" }}>
            <div className="search-bar"><Search size={15} style={{ color: "var(--text-muted)" }} /><input placeholder="Cari pesanan..." value={search} onChange={e => setSearch(e.target.value)} /></div>
          </div>
        </div>
        {loading ? <div className="loading-overlay"><div className="spinner" /><p>Memuat...</p></div> : (
          <div className="table-wrap">
            <div className="table-header"><h3>Total: {filtered.length} pesanan</h3></div>
            <table>
              <thead><tr><th>ID</th><th>Penumpang</th><th>Driver</th><th>Layanan</th><th>Jemput</th><th>Tujuan</th><th>Tarif</th><th>Status</th><th>Waktu</th></tr></thead>
              <tbody>
                {filtered.length === 0 ? (
                  <tr>
                    <td colSpan={9}>
                      <div className="empty-state">
                        <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                          <Package size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                        </div>
                        <h3>Tidak ada pesanan</h3>
                        <p>Belum ada pesanan dengan filter ini</p>
                      </div>
                    </td>
                  </tr>
                ) : filtered.map(o => (
                  <tr key={o.id}>
                    <td data-label="ID"><span className="chip">#{o.id?.slice(-6)}</span></td>
                    <td data-label="Penumpang">
                      <div><div style={{ fontWeight: 600 }}>{o.rider_name}</div><div style={{ fontSize: 11, color: "var(--text-muted)" }}>{o.rider_phone}</div></div>
                    </td>
                    <td data-label="Driver" style={{ color: o.driver_name ? "var(--text-primary)" : "var(--text-muted)" }}>
                      {o.driver_name || "—"}
                    </td>
                    <td data-label="Layanan"><span className="badge badge-primary">{o.service}</span></td>
                    <td style={{ maxWidth: 140, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: "var(--text-secondary)" }} data-label="Jemput">{o.pickup}</td>
                    <td style={{ maxWidth: 140, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: "var(--text-secondary)" }} data-label="Tujuan">{o.dropoff}</td>
                    <td data-label="Tarif" style={{ fontWeight: 600, color: "var(--success)" }}>Rp {(o.fare || 0).toLocaleString("id-ID")}</td>
                    <td data-label="Status"><span className={`badge ${STATUS_BADGE[o.status] || "badge-muted"}`}>{STATUS_LABEL[o.status] || o.status}</span></td>
                    <td data-label="Waktu" style={{ color: "var(--text-muted)", fontSize: 12 }}>{new Date(o.created_at).toLocaleString("id-ID")}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="table-pager">
              <div style={{ fontSize: 13, color: "var(--text-muted)", fontWeight: 500 }}>
                Menampilkan {orders.length} dari {totalRecords} pesanan
              </div>
              
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <button 
                  className="filter-btn" 
                  disabled={page <= 1} 
                  onClick={() => { setPage(page - 1); load(filter, page - 1, limit); }}
                  style={{ opacity: page <= 1 ? 0.4 : 1, cursor: page <= 1 ? "not-allowed" : "pointer" }}
                >
                  Sebelumnya
                </button>
                <span style={{ fontSize: 13, fontWeight: 700, color: "var(--text-primary)" }}>
                  Halaman {page} dari {totalPages}
                </span>
                <button 
                  className="filter-btn" 
                  disabled={page >= totalPages} 
                  onClick={() => { setPage(page + 1); load(filter, page + 1, limit); }}
                  style={{ opacity: page >= totalPages ? 0.4 : 1, cursor: page >= totalPages ? "not-allowed" : "pointer" }}
                >
                  Selanjutnya
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </>
  );
}
