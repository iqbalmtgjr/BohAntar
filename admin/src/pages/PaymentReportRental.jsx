import { useState, useEffect } from "react";
import { DollarSign, CheckCircle2, AlertCircle, Search, RefreshCw, Filter } from "lucide-react";
import { BASE, authFetch } from "../api";
import { Alert } from "../components/Feedback";

export default function PaymentReportRental() {
  const [invoices, setInvoices] = useState([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState("");
  const [statusFilter, setStatusFilter] = useState("ALL");
  const [error, setError] = useState("");

  const fetchReports = () => {
    setLoading(true);
    setError("");
    authFetch(`${BASE}/admin/reports/subscriptions`)
      .then(r => {
        if (!r.ok) throw new Error("Gagal mengambil data laporan");
        return r.json();
      })
      .then(data => {
        setInvoices(Array.isArray(data) ? data : []);
        setLoading(false)
      })
      .catch(err => {
        console.error(err);
        setError("Gagal menghubungi server untuk memuat laporan");
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchReports();
  }, []);

  if (loading) {
    return <div className="page"><div className="spinner" style={{ margin: "100px auto" }}></div></div>;
  }

  // Calculate metrics
  const paidInvoices = invoices.filter(i => i.status === "PAID");
  const pendingInvoices = invoices.filter(i => i.status === "PENDING");
  const totalRevenue = paidInvoices.reduce((sum, i) => sum + i.amount, 0);

  // Filter invoices based on search & status filter
  const filteredInvoices = invoices.filter(i => {
    const matchesSearch = 
      (i.partner_name && i.partner_name.toLowerCase().includes(searchTerm.toLowerCase())) ||
      (i.phone_number && i.phone_number.includes(searchTerm)) ||
      (i.id && i.id.toLowerCase().includes(searchTerm.toLowerCase()));
    
    const matchesStatus = 
      statusFilter === "ALL" || 
      i.status === statusFilter;

    return matchesSearch && matchesStatus;
  });

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1>Laporan Pembayaran bohRental</h1>
          <p>Daftar riwayat pembayaran langganan SaaS bohRental (Rp 100.000 / Bulan)</p>
        </div>
        <button 
          onClick={fetchReports} 
          className="btn btn-sm" 
          style={{ 
            display: "flex", 
            alignItems: "center", 
            gap: 6, 
            background: "var(--bg-input)", 
            color: "var(--text-primary)", 
            border: "1px solid var(--border)",
            borderRadius: 8,
            cursor: "pointer",
            padding: "8px 16px"
          }}
        >
          <RefreshCw size={14} /> Refresh Data
        </button>
      </div>

      <Alert type="error" style={{ marginBottom: 24 }}>{error}</Alert>

      {/* Metrics Grid */}
      <div className="stats-grid" style={{ marginBottom: 32 }}>
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(16, 185, 129, 0.1)", color: "#10B981" }}>
            <DollarSign size={24} />
          </div>
          <div>
            <div className="stat-label">Total Omset (Lunas)</div>
            <div className="stat-value" style={{ color: "#10B981" }}>
              Rp {totalRevenue.toLocaleString("id-ID")}
            </div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(59, 130, 246, 0.1)", color: "#3B82F6" }}>
            <CheckCircle2 size={24} />
          </div>
          <div>
            <div className="stat-label">Transaksi Lunas</div>
            <div className="stat-value">{paidInvoices.length} Pembayaran</div>
          </div>
        </div>

        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(245, 158, 11, 0.1)", color: "#F59E0B" }}>
            <AlertCircle size={24} />
          </div>
          <div>
            <div className="stat-label">Transaksi Pending</div>
            <div className="stat-value">{pendingInvoices.length} Invoice</div>
          </div>
        </div>
      </div>

      {/* Filters & Table */}
      <div className="table-wrap">
        <div className="table-header" style={{ display: "flex", justifyContent: "space-between", flexWrap: "wrap", gap: 16 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, background: "var(--bg-input)", padding: "8px 16px", borderRadius: 10, border: "1px solid var(--border)", width: "100%", maxWidth: 320 }}>
            <Search size={18} style={{ color: "var(--text-muted)" }} />
            <input 
              type="text" 
              placeholder="Cari Mitra, No HP, atau ID..." 
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              style={{ background: "none", border: "none", color: "var(--text-primary)", outline: "none", width: "100%", fontSize: 14 }}
            />
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: "var(--text-secondary)" }}>
              <Filter size={14} /> Filter Status:
            </div>
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              style={{
                background: "var(--bg-input)",
                color: "var(--text-primary)",
                border: "1px solid var(--border)",
                borderRadius: 8,
                padding: "8px 16px",
                fontSize: 13,
                outline: "none",
                cursor: "pointer"
              }}
            >
              <option value="ALL">Semua Transaksi</option>
              <option value="PAID">Lunas</option>
              <option value="PENDING">Pending</option>
              <option value="EXPIRED">Expired</option>
            </select>
          </div>
        </div>

        <table>
          <thead>
            <tr>
              <th>ID Invoice</th>
              <th>Nama Mitra</th>
              <th>Nomor HP</th>
              <th>Jumlah Bayar</th>
              <th>Tanggal Transaksi</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {filteredInvoices.length === 0 ? (
              <tr>
                <td colSpan="6" style={{ textAlign: "center", color: "var(--text-muted)", padding: 40 }}>
                  Tidak menemukan data transaksi pembayaran langganan.
                </td>
              </tr>
            ) : (
              filteredInvoices.map(inv => (
                <tr key={inv.id}>
                  <td data-label="ID Invoice"><strong style={{ fontFamily: "monospace", fontSize: 13 }}>{inv.id}</strong></td>
                  <td data-label="Nama Mitra"><strong>{inv.partner_name || "Mitra Rental"}</strong></td>
                  <td data-label="Nomor HP">{inv.phone_number}</td>
                  <td data-label="Jumlah Bayar"><strong>Rp {inv.amount.toLocaleString("id-ID")}</strong></td>
                  <td data-label="Tanggal">
                    {new Date(inv.created_at).toLocaleDateString("id-ID", {
                      year: "numeric",
                      month: "long",
                      day: "numeric",
                      hour: "2-digit",
                      minute: "2-digit"
                    })}
                  </td>
                  <td data-label="Status">
                    <span className={`badge ${
                      inv.status === "PAID" ? "badge-success" :
                      inv.status === "PENDING" ? "badge-warning" : "badge-danger"
                    }`}>
                      {inv.status === "PAID" ? "LUNAS" : inv.status}
                    </span>
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
