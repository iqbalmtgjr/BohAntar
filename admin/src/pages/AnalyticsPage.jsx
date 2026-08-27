import { useEffect, useState } from "react";
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from "recharts";
import { BarChart3 } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

export default function AnalyticsPage() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.getAnalytics().then(d => { if (d.status === "success") setData(d.analytics); setLoading(false); });
  }, []);

  if (loading) return (<><Topbar title="Analitik" /><div className="loading-overlay"><div className="spinner" /><p>Memuat analitik...</p></div></>);

  const a = data || {};
  const drivers = (a.driver_stats || []).sort((x, y) => (y.order_count || 0) - (x.order_count || 0));

  return (
    <>
      <Topbar title="Analitik" />
      <div className="page">
        <div className="page-header"><h1>Analitik Performa</h1><p>Pantau performa driver dan tren pesanan</p></div>

        <div style={{ marginBottom: 24 }}>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 16 }}>Peringkat Driver — Total Pesanan Selesai</div>
            <table style={{ width: "100%" }}>
              <thead><tr><th>#</th><th>Driver</th><th>Pesanan</th><th>Total Pendapatan</th><th>Rata-rata per Order</th><th>Performa</th></tr></thead>
              <tbody>
                {drivers.length === 0 ? (
                  <tr>
                    <td colSpan={6}>
                      <div className="empty-state">
                        <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                          <BarChart3 size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                        </div>
                        <h3>Belum ada data</h3>
                        <p>Pesanan yang selesai akan muncul di sini</p>
                      </div>
                    </td>
                  </tr>
                ) : drivers.map((d, i) => {
                  const avg = d.order_count > 0 ? (d.total_income / d.order_count) : 0;
                  const maxOrders = drivers[0]?.order_count || 1;
                  const pct = Math.round((d.order_count / maxOrders) * 100);
                  return (
                    <tr key={d.driver_phone}>
                      <td data-label="Peringkat"><span style={{ fontWeight: 800, color: i === 0 ? "#F59E0B" : i === 1 ? "#94A3B8" : i === 2 ? "#CD7F32" : "var(--text-muted)" }}>#{i + 1}</span></td>
                      <td data-label="Driver">
                        <div className="user-cell">
                          <div className="user-avatar" style={{ background: "rgba(37,99,235,0.1)", color: "#3B82F6" }}>{d.driver_name?.[0]}</div>
                          <div><div className="user-name">{d.driver_name}</div><div className="user-sub">{d.driver_phone}</div></div>
                        </div>
                      </td>
                      <td data-label="Pesanan" style={{ fontWeight: 700 }}>{d.order_count}</td>
                      <td data-label="Total Pendapatan" style={{ color: "var(--success)", fontWeight: 600 }}>Rp {(d.total_income || 0).toLocaleString("id-ID")}</td>
                      <td data-label="Rata-rata" style={{ color: "var(--text-secondary)" }}>Rp {Math.round(avg).toLocaleString("id-ID")}</td>
                      <td data-label="Performa" style={{ width: 140 }}>
                        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                          <div style={{ flex: 1, height: 6, background: "var(--bg-input)", borderRadius: 3, overflow: "hidden" }}>
                            <div style={{ width: pct + "%", height: "100%", background: i === 0 ? "#F59E0B" : "var(--primary)", borderRadius: 3 }} />
                          </div>
                          <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{pct}%</span>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>

        <div className="grid-2">
          <div className="card">
            <div className="card-title">Pesanan per Driver</div>
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={drivers.slice(0,6).map(d => ({ name: d.driver_name?.split(" ")[0], value: d.order_count }))}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="name" stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
                <YAxis stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
                <Tooltip contentStyle={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 8, color: "var(--text-primary)" }} />
                <Bar dataKey="value" fill="var(--primary)" radius={[6,6,0,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
          <div className="card">
            <div className="card-title">Pendapatan per Driver (Rp)</div>
            <ResponsiveContainer width="100%" height={240}>
              <BarChart data={drivers.slice(0,6).map(d => ({ name: d.driver_name?.split(" ")[0], value: Math.round(d.total_income / 1000) }))}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="name" stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
                <YAxis stroke="var(--text-secondary)" tick={{ fontSize: 12 }} />
                <Tooltip contentStyle={{ background: "var(--bg-card)", border: "1px solid var(--border)", borderRadius: 8, color: "var(--text-primary)" }} formatter={v => ["Rp " + v + "K", "Pendapatan"]} />
                <Bar dataKey="value" fill="var(--success)" radius={[6,6,0,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>
    </>
  );
}
