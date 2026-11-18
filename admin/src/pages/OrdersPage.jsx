import { useEffect, useRef, useState } from "react";
import { Search, Package, X } from "lucide-react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { api, fileURL } from "../api";
import Topbar from "../components/Topbar";

const rp = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");
const adaTitik = (lat, lng) => Number(lat) !== 0 || Number(lng) !== 0;

// Jemput hijau, tujuan merah, garis lurus di antaranya (bukan rute jalan).
function PetaPesanan({ o }) {
  const wadah = useRef(null);
  useEffect(() => {
    const titik = [];
    if (adaTitik(o.pickup_lat, o.pickup_lng)) titik.push([[o.pickup_lat, o.pickup_lng], "#16A34A", "Jemput: " + o.pickup]);
    if (adaTitik(o.dropoff_lat, o.dropoff_lng)) titik.push([[o.dropoff_lat, o.dropoff_lng], "#DC2626", "Tujuan: " + o.dropoff]);
    const m = L.map(wadah.current);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "© OpenStreetMap" }).addTo(m);
    if (titik.length === 2) L.polyline(titik.map(t => t[0]), { color: "#4F46E5", weight: 3, dashArray: "6 6" }).addTo(m);
    titik.forEach(([p, warna, label]) =>
      L.circleMarker(p, { radius: 9, color: "#fff", weight: 2, fillColor: warna, fillOpacity: 1 }).bindTooltip(label).addTo(m));
    if (titik.length) m.fitBounds(titik.map(t => t[0]), { padding: [40, 40], maxZoom: 16 });
    else m.setView([0.0785, 111.4940], 13); // pusat Sintang
    return () => m.remove();
  }, [o]);
  return <div ref={wadah} style={{ height: 280, borderRadius: 12, overflow: "hidden", border: "1px solid var(--border)" }} />;
}

function Baris({ label, children }) {
  if (children === "" || children == null || children === false) return null;
  return (
    <div style={{ display: "flex", gap: 12, padding: "6px 0", borderBottom: "1px dashed var(--border)", fontSize: 13 }}>
      <div style={{ width: 130, flexShrink: 0, color: "var(--text-muted)" }}>{label}</div>
      <div style={{ flex: 1, color: "var(--text-primary)", wordBreak: "break-word" }}>{children}</div>
    </div>
  );
}

function DetailPesanan({ o, dilepas, onTutup }) {
  useEffect(() => {
    const esc = (e) => e.key === "Escape" && onTutup();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onTutup]);
  const gmaps = (lat, lng) => `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
  const rute = adaTitik(o.pickup_lat, o.pickup_lng) && adaTitik(o.dropoff_lat, o.dropoff_lng)
    ? `https://www.google.com/maps/dir/?api=1&origin=${o.pickup_lat},${o.pickup_lng}&destination=${o.dropoff_lat},${o.dropoff_lng}` : "";
  const koordinat = (lat, lng) => adaTitik(lat, lng)
    ? <a href={gmaps(lat, lng)} target="_blank" rel="noreferrer" style={{ fontSize: 11 }}>{Number(lat).toFixed(6)}, {Number(lng).toFixed(6)} ↗</a> : null;

  return (
    <div className="modal-overlay" onClick={onTutup}>
      <div className="modal" onClick={e => e.stopPropagation()} style={{ maxWidth: 720, position: "relative" }} role="dialog" aria-modal="true">
        <button className="filter-btn" onClick={onTutup} aria-label="Tutup" style={{ position: "absolute", top: 16, right: 16, padding: 6 }}><X size={16} /></button>
        <h2>Pesanan #{o.id?.slice(-6)}</h2>
        <p className="modal-desc" style={{ marginBottom: 16 }}>
          <span className="badge badge-primary">{o.service}{o.kelas ? ` ${o.kelas}` : ""}</span>{" "}
          <span className={`badge ${STATUS_BADGE[o.status] || "badge-muted"}`}>{STATUS_LABEL[o.status] || o.status}</span>{" "}
          <span style={{ fontSize: 11 }}>{o.id}</span>
        </p>

        <PetaPesanan o={o} />
        <div style={{ display: "flex", gap: 16, fontSize: 12, margin: "8px 0 16px", flexWrap: "wrap" }}>
          <span><span style={{ color: "#16A34A" }}>●</span> Jemput</span>
          <span><span style={{ color: "#DC2626" }}>●</span> Tujuan</span>
          {rute && <a href={rute} target="_blank" rel="noreferrer" style={{ marginLeft: "auto" }}>Lihat rute di Google Maps ↗</a>}
        </div>

        <Baris label="Jemput"><div>{o.pickup}</div>{koordinat(o.pickup_lat, o.pickup_lng)}</Baris>
        <Baris label="Tujuan"><div>{o.dropoff}</div>{koordinat(o.dropoff_lat, o.dropoff_lng)}</Baris>
        <Baris label="Penumpang">{o.rider_name} · {o.rider_phone}</Baris>
        <Baris label="Driver">{o.driver_name ? `${o.driver_name} · ${o.driver_phone}` : "—"}</Baris>
        <Baris label="Penerima">{o.receiver_name && `${o.receiver_name}${o.receiver_phone ? " · " + o.receiver_phone : ""}`}</Baris>
        <Baris label="Diterima oleh">{o.received_by}</Baris>
        <Baris label="Dibuat">{new Date(o.created_at).toLocaleString("id-ID")}</Baris>
        <Baris label="Terakhir diubah">{o.updated_at && new Date(o.updated_at).toLocaleString("id-ID")}</Baris>
        <Baris label="Pembayaran">{o.payment_method === "cash" ? "Tunai" : "Saldo"}</Baris>

        {o.merchant_name && <Baris label="Warung">{o.merchant_name}</Baris>}
        {o.items?.length > 0 && (
          <Baris label="Isi pesanan">
            {o.items.map((it, i) => (
              <div key={i} style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
                <span>{it.qty}× {it.name}{it.options?.length ? <span style={{ color: "var(--text-muted)" }}> ({it.options.map(x => x.name).join(", ")})</span> : null}</span>
                <span>{rp((it.price + (it.options || []).reduce((s, x) => s + x.price, 0)) * it.qty)}</span>
              </div>
            ))}
          </Baris>
        )}
        {o.package_type && (
          <Baris label="Paket">
            {o.package_type}{o.package_quantity ? ` · ${o.package_quantity} koli` : ""}{o.package_weight ? ` · ${o.package_weight}` : ""}
            {o.insurance ? " · asuransi" : ""}{o.special_handling ? " · penanganan khusus" : ""}
            {o.package_notes && <div style={{ color: "var(--text-muted)" }}>{o.package_notes}</div>}
          </Baris>
        )}

        <Baris label="Ongkos">{rp(o.fare)}</Baris>
        <Baris label="Biaya jasa">{o.biaya_jasa > 0 && rp(o.biaya_jasa)}</Baris>
        <Baris label="Makanan">{o.food_total > 0 && rp(o.food_total)}</Baris>
        <Baris label="Diskon voucher">{o.diskon > 0 && "− " + rp(o.diskon)}</Baris>
        <Baris label="Dibayar penumpang"><b>{rp(o.fare + o.biaya_jasa + o.food_total - o.diskon)}</b></Baris>
        <Baris label="Komisi aplikator">{rp(o.komisi)} <span style={{ color: "var(--text-muted)" }}>(driver terima {rp(o.fare - o.komisi)})</span></Baris>

        <Baris label="Alasan batal">{o.alasan_batal}</Baris>
        <Baris label="Batal ditolak">{o.tolak_batal}</Baris>
        {dilepas?.length > 0 && (
          <Baris label="Dilepas driver">
            {dilepas.map((x, i) => <div key={i}>{x.driver}{x.alasan ? `: ${x.alasan}` : ""} <span style={{ color: "var(--text-muted)" }}>({new Date(x.waktu).toLocaleString("id-ID")})</span></div>)}
          </Baris>
        )}
        <Baris label="Kasir Kasvo">{o.kasvo_pesanan_id > 0 && `#${o.kasvo_pesanan_id}`}</Baris>

        {(o.pickup_photo_url || o.delivery_photo_url) && (
          <div style={{ display: "flex", gap: 12, marginTop: 16, flexWrap: "wrap" }}>
            {[["Foto saat diambil", o.pickup_photo_url], ["Foto saat diserahkan", o.delivery_photo_url]].filter(f => f[1]).map(([judul, url]) => (
              <a key={judul} href={fileURL(url)} target="_blank" rel="noreferrer" style={{ fontSize: 12, textAlign: "center" }}>
                <img src={fileURL(url)} alt={judul} style={{ width: 140, height: 140, objectFit: "cover", borderRadius: 10, border: "1px solid var(--border)", display: "block", marginBottom: 4 }} />
                {judul}
              </a>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

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
  // Riwayat driver melepas pesanan, per id pesanan: [{driver, alasan, waktu}].
  const [dilepas, setDilepas] = useState({});
  const [detail, setDetail] = useState(null);

  const load = (status = filter, p = page, l = limit) => {
    setLoading(true);
    const params = { page: p, limit: l };
    if (status) params.status = status;
    if (search.trim()) params.q = search.trim();
    api.getOrders(params).then(d => {
      setOrders(d.orders || []);
      setDilepas(d.dilepas || {});
      if (d.pagination) {
        setPage(d.pagination.page);
        setTotalPages(d.pagination.total_pages);
        setTotalRecords(d.pagination.total);
      }
      setLoading(false); 
    });
  };

  // Dicari di server supaya pesanan di halaman lain ikut ketemu; ketikan
  // ditunggu 300 ms dulu agar tidak memanggil API tiap huruf.
  useEffect(() => {
    const t = setTimeout(() => load(filter, 1, limit), search ? 300 : 0);
    return () => clearTimeout(t);
  }, [search]);

  return (
    <>
      <Topbar title="Pesanan" />
      <div className="page">
        <div className="page-header"><h1>Semua Pesanan</h1><p>Monitor dan kelola alur pesanan BohAntar</p></div>
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
            <div className="table-header"><h3>Total: {totalRecords} pesanan</h3></div>
            <table>
              <thead><tr><th>ID</th><th>Penumpang</th><th>Driver</th><th>Layanan</th><th>Jemput</th><th>Tujuan</th><th>Tarif</th><th>Status</th><th>Waktu</th></tr></thead>
              <tbody>
                {orders.length === 0 ? (
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
                ) : orders.map(o => (
                  <tr key={o.id} onClick={() => setDetail(o)} style={{ cursor: "pointer" }} title="Klik untuk lihat detail">
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
                    <td data-label="Tarif" style={{ fontWeight: 600, color: "var(--success)" }}>
                      Rp {(o.fare || 0).toLocaleString("id-ID")}
                      {o.diskon > 0 && <div style={{ fontSize: 11, fontWeight: 500, color: "var(--text-muted)" }}>diskon Rp {o.diskon.toLocaleString("id-ID")}</div>}
                    </td>
                    <td data-label="Status">
                      <span className={`badge ${STATUS_BADGE[o.status] || "badge-muted"}`}>{STATUS_LABEL[o.status] || o.status}</span>
                      {o.status === "cancelled" && o.alasan_batal && (
                        <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 4, maxWidth: 160 }}>Alasan: {o.alasan_batal}</div>
                      )}
                      {/* BohFood: pengajuan batal penumpang yang menunggu / ditolak driver */}
                      {o.status !== "cancelled" && o.minta_batal_at && (
                        <div style={{ fontSize: 11, color: "#B45309", marginTop: 4, maxWidth: 160 }}>Minta batal (menunggu driver): {o.alasan_batal}</div>
                      )}
                      {o.status !== "cancelled" && !o.minta_batal_at && o.tolak_batal && (
                        <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 4, maxWidth: 160 }}>Batal ditolak driver: {o.tolak_batal}</div>
                      )}
                      {dilepas[o.id]?.map((x, i) => (
                        <div key={i} style={{ fontSize: 11, color: "#B45309", marginTop: 4, maxWidth: 160 }}
                          title={new Date(x.waktu).toLocaleString("id-ID")}>
                          Dilepas {x.driver}{x.alasan ? `: ${x.alasan}` : ""}
                        </div>
                      ))}
                    </td>
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
      {detail && <DetailPesanan o={detail} dilepas={dilepas[detail.id]} onTutup={() => setDetail(null)} />}
    </>
  );
}
