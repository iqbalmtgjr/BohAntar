import { useState, useEffect } from "react";
import { BarChart3, DollarSign, Clock, Car, Printer, RefreshCw, Filter, Search, FileText, Paperclip } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { buildRows, bucketOf, isOverdue, parseDT, rentalDays } from "./schedule";
import { bookingInvoice, scheduleInvoice, useRentalName } from "./invoice";
import InvoiceModal from "./InvoiceModal";

const BUCKET_LABEL = { selesai: "SELESAI", batal: "BATAL", menunggu: "MENUNGGU", berjalan: "BERJALAN" };
const BUCKET_BADGE = {
  selesai: "badge-success",
  batal: "badge-danger",
  menunggu: "badge-warning",
  berjalan: "badge-primary"
};

function formatDuration(startStr, endStr) {
  const ms = parseDT(endStr) - parseDT(startStr);
  if (!isFinite(ms) || ms <= 0) return "0 Jam";
  const totalHours = Math.floor(ms / 3600000);
  const days = Math.floor(totalHours / 24);
  const hours = totalHours % 24;
  return days > 0 ? `${days} Hari ${hours > 0 ? hours + " Jam" : ""}` : `${totalHours} Jam`;
}

export default function RentalReports({ ownerPhone }) {
  const [cars, setCars] = useState([]);
  const [bookings, setBookings] = useState([]);
  const [schedules, setSchedules] = useState([]);
  const [loading, setLoading] = useState(true);
  const rentalName = useRentalName();
  const [invoice, setInvoice] = useState(null);

  // Filter States
  const [startDate, setStartDate] = useState("");
  const [startTime, setStartTime] = useState("00:00");
  const [endDate, setEndDate] = useState("");
  const [endTime, setEndTime] = useState("23:59");
  const [selectedCarId, setSelectedCarId] = useState("all");
  const [selectedType, setSelectedType] = useState("all");
  const [selectedSource, setSelectedSource] = useState("all");
  const [selectedStatus, setSelectedStatus] = useState("all");
  const [searchQuery, setSearchQuery] = useState("");

  const fetchData = () => {
    setLoading(true);
    Promise.all([
      authFetch(`${BASE}/rental/cars?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/bookings?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/schedules`).then(r => r.json())
    ])
      .then(([carsData, bookingsData, schedulesData]) => {
        setCars(Array.isArray(carsData) ? carsData : []);
        setBookings(Array.isArray(bookingsData) ? bookingsData : []);
        setSchedules(Array.isArray(schedulesData) ? schedulesData : []);
        setLoading(false);
      })
      .catch(err => {
        console.error("Error loading reports data:", err);
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchData();
  }, [ownerPhone]);

  // Semua turunan dihitung saat render; tidak perlu state tambahan.
  const rows = buildRows(bookings, schedules, cars);

  const filterStart = startDate ? parseDT(`${startDate} ${startTime}:00`) : null;
  const filterEnd = endDate ? parseDT(`${endDate} ${endTime}:59`) : null;
  const q = searchQuery.trim().toLowerCase();

  const filtered = rows.filter(row => {
    // Periode dihitung sebagai irisan: sewa yang masih berjalan melewati tanggal
    // akhir filter tetap masuk, sama seperti yang mulai sebelum tanggal awal.
    if (filterStart && parseDT(row.end) < filterStart) return false;
    if (filterEnd && parseDT(row.start) > filterEnd) return false;

    if (selectedCarId !== "all" && row.carId !== selectedCarId) return false;

    const car = cars.find(c => c.id === row.carId);
    if (selectedType !== "all" && (!car || car.vehicle_type !== selectedType)) return false;
    if (selectedSource !== "all" && row.source !== selectedSource) return false;
    if (selectedStatus !== "all" && bucketOf(row.status) !== selectedStatus) return false;

    if (q) {
      const carName = car ? `${car.brand} ${car.model} ${car.plate_number}`.toLowerCase() : "";
      const haystack = `${carName} ${row.customer} ${row.contact} ${row.id}`.toLowerCase();
      if (!haystack.includes(q)) return false;
    }
    return true;
  });

  // Perawatan bukan transaksi, jadi tidak ikut dihitung di ringkasan angka.
  const transactions = filtered.filter(row => row.source !== "maintenance");
  const earning = transactions.filter(row => ["berjalan", "selesai"].includes(bucketOf(row.status)));
  const totalRevenue = earning.reduce((sum, row) => sum + (row.total || 0), 0);
  const settledRevenue = transactions
    .filter(row => bucketOf(row.status) === "selesai")
    .reduce((sum, row) => sum + (row.total || 0), 0);

  const totalDays = transactions.reduce((sum, row) => sum + rentalDays(row.start, row.end), 0);
  const avgDuration = transactions.length > 0
    ? `${(totalDays / transactions.length).toFixed(1)} Hari`
    : "0 Hari";

  const carCounts = {};
  transactions.forEach(row => { carCounts[row.carId] = (carCounts[row.carId] || 0) + 1; });
  const favCarId = Object.keys(carCounts).sort((a, b) => carCounts[b] - carCounts[a])[0];
  const favCar = cars.find(c => c.id === favCarId);
  const favVehicle = favCar
    ? `${favCar.brand} ${favCar.model} (${favCar.plate_number}) - ${carCounts[favCarId]}x Sewa`
    : "Tidak ada data";

  const handleResetFilters = () => {
    setStartDate("");
    setStartTime("00:00");
    setEndDate("");
    setEndTime("23:59");
    setSelectedCarId("all");
    setSelectedType("all");
    setSelectedSource("all");
    setSelectedStatus("all");
    setSearchQuery("");
  };

  const handlePrint = () => {
    window.print();
  };

  return (
    <div className="page">
      {/* Styles for printing only the report card structure cleanly */}
      <style>{`
        @media print {
          body {
            background: #fff !important;
            color: #000 !important;
          }
          .sidebar, .topbar, button, .filter-section, .no-print {
            display: none !important;
          }
          .main-content {
            margin: 0 !important;
            padding: 0 !important;
            width: 100% !important;
          }
          .card {
            border: none !important;
            box-shadow: none !important;
            padding: 0 !important;
            background: transparent !important;
          }
          .print-header {
            display: block !important;
            text-align: center;
            margin-bottom: 30px;
            border-bottom: 2px double #334155;
            padding-bottom: 10px;
          }
          table {
            border: 1px solid #cbd5e1 !important;
          }
          th, td {
            border: 1px solid #cbd5e1 !important;
            padding: 8px 12px !important;
            font-size: 11px !important;
            color: #000 !important;
          }
        }
        .print-header {
          display: none;
        }
      `}</style>

      {/* Header Cetak Resmi */}
      <div className="print-header">
        <h1 style={{ fontSize: 24, fontWeight: 900 }}>LAPORAN LENGKAP PENYEWAAN KENDARAAN</h1>
        <p style={{ fontSize: 13, color: "#475569", marginTop: 4 }}>
          Pemilik Rental: {ownerPhone} | Tanggal Cetak: {new Date().toLocaleDateString("id-ID")}
        </p>
        {(startDate || endDate) && (
          <p style={{ fontSize: 12, fontWeight: 600, marginTop: 8 }}>
            Periode Laporan: {startDate || "Awal"} s/d {endDate || "Sekarang"}
          </p>
        )}
      </div>

      {/* Page Title Header */}
      <div className="page-header no-print" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1>Laporan Lengkap & Analisis</h1>
          <p>Riwayat semua transaksi sewa — dari aplikasi maupun jadwal manual di kalender — yang sedang berjalan sampai yang sudah selesai</p>
        </div>
        <div style={{ display: "flex", gap: 12, width: "100%", maxWidth: 320 }}>
          <button onClick={fetchData} className="btn btn-ghost" style={{ padding: "8px 12px" }}>
            <RefreshCw size={16} />
          </button>
          <button onClick={handlePrint} className="btn btn-primary" style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <Printer size={16} />
            <span>Cetak Laporan</span>
          </button>
        </div>
      </div>

      {/* Interactive Filters Bar */}
      <div className="card filter-section no-print" style={{ padding: 20, marginBottom: 24 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 16 }}>
          <Filter size={16} style={{ color: "var(--primary)" }} />
          <span style={{ fontWeight: 700, fontSize: 14 }}>Filter Laporan Kustom</span>
        </div>
        <div className="grid-3" style={{ gap: 16 }}>
          {/* Start Date & Time */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Mulai Tanggal & Jam</label>
            <div style={{ display: "flex", gap: 8 }}>
              <input type="date" className="input" value={startDate} onChange={e => setStartDate(e.target.value)} />
              <input type="time" className="input" style={{ maxWidth: 120 }} value={startTime} onChange={e => setStartTime(e.target.value)} />
            </div>
          </div>

          {/* End Date & Time */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Sampai Tanggal & Jam</label>
            <div style={{ display: "flex", gap: 8 }}>
              <input type="date" className="input" value={endDate} onChange={e => setEndDate(e.target.value)} />
              <input type="time" className="input" style={{ maxWidth: 120 }} value={endTime} onChange={e => setEndTime(e.target.value)} />
            </div>
          </div>

          {/* Vehicle Dropdown */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Filter Armada</label>
            <select className="input" value={selectedCarId} onChange={e => setSelectedCarId(e.target.value)}>
              <option value="all">Semua Armada</option>
              {cars.map(c => (
                <option key={c.id} value={c.id}>{c.brand} {c.model} ({c.plate_number})</option>
              ))}
            </select>
          </div>
        </div>

        <div className="grid-3" style={{ gap: 16, marginTop: 16 }}>
          {/* Vehicle Type */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Jenis Kendaraan</label>
            <select className="input" value={selectedType} onChange={e => setSelectedType(e.target.value)}>
              <option value="all">Semua Tipe</option>
              <option value="car">Mobil saja</option>
              <option value="motorcycle">Motor saja</option>
            </select>
          </div>

          {/* Sumber Transaksi */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Sumber Transaksi</label>
            <select className="input" value={selectedSource} onChange={e => setSelectedSource(e.target.value)}>
              <option value="all">Semua Sumber</option>
              <option value="app">Pesanan Aplikasi</option>
              <option value="manual">Sewa Manual (Kalender)</option>
              <option value="maintenance">Perawatan / Servis</option>
            </select>
          </div>

          {/* Status */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Status</label>
            <select className="input" value={selectedStatus} onChange={e => setSelectedStatus(e.target.value)}>
              <option value="all">Semua Status</option>
              <option value="menunggu">Menunggu Konfirmasi</option>
              <option value="berjalan">Sedang Berjalan</option>
              <option value="selesai">Sudah Selesai</option>
              <option value="batal">Batal / Ditolak</option>
            </select>
          </div>
        </div>

        <div className="grid-3" style={{ gap: 16, marginTop: 16 }}>
          {/* Search Query */}
          <div className="input-group" style={{ marginBottom: 0 }}>
            <label>Pencarian</label>
            <div style={{ position: "relative" }}>
              <input
                type="text"
                className="input"
                placeholder="Cari plat nomor / nama / HP penyewa..."
                value={searchQuery}
                onChange={e => setSearchQuery(e.target.value)}
                style={{ paddingLeft: 34 }}
              />
              <Search size={16} style={{ position: "absolute", left: 12, top: "50%", transform: "translateY(-50%)", color: "var(--text-muted)" }} />
            </div>
          </div>

          {/* Reset Action */}
          <div style={{ display: "flex", alignItems: "flex-end" }}>
            <button
              onClick={handleResetFilters}
              className="btn btn-ghost"
              style={{ width: "100%", justifyContent: "center", padding: "10px 14px", height: "39px" }}
            >
              Reset Semua Filter
            </button>
          </div>
        </div>
      </div>

      {/* KPI Stats Cards Grid */}
      <div className="stats-grid" style={{ marginBottom: 24 }}>
        {/* Total Transaksi */}
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(59, 130, 246, 0.1)", color: "#3B82F6" }}>
            <BarChart3 size={24} />
          </div>
          <div>
            <div className="stat-label">Total Transaksi</div>
            <div className="stat-value">{transactions.length} Sewa</div>
            <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>
              Perawatan tidak dihitung
            </div>
          </div>
        </div>

        {/* Total Pendapatan */}
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(37, 99, 235, 0.08)", color: "#2563EB" }}>
            <DollarSign size={24} />
          </div>
          <div>
            <div className="stat-label">Pendapatan Kotor</div>
            <div className="stat-value">Rp {totalRevenue.toLocaleString("id-ID")}</div>
            <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>
              Selesai: Rp {settledRevenue.toLocaleString("id-ID")}
            </div>
          </div>
        </div>

        {/* Rata-rata Durasi */}
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(245, 158, 11, 0.1)", color: "#F59E0B" }}>
            <Clock size={24} />
          </div>
          <div>
            <div className="stat-label">Rata-rata Lama Sewa</div>
            <div className="stat-value">{avgDuration}</div>
          </div>
        </div>

        {/* Kendaraan Terfavorit */}
        <div className="stat-card">
          <div className="stat-icon" style={{ background: "rgba(29, 78, 216, 0.08)", color: "#1D4ED8" }}>
            <Car size={24} />
          </div>
          <div style={{ overflow: "hidden" }}>
            <div className="stat-label">Kendaraan Terlaris</div>
            <div className="stat-value" style={{ fontSize: 13, fontWeight: 800, whiteSpace: "nowrap", textOverflow: "ellipsis", overflow: "hidden" }}>
              {favVehicle}
            </div>
          </div>
        </div>
      </div>

      {/* Detailed Bookings Table */}
      <div className="table-wrap">
        <div className="table-header">
          <h3 style={{ fontSize: 15, fontWeight: 800 }}>Riwayat Transaksi Sewa</h3>
          <span className="no-print" style={{ fontSize: 12, color: "var(--text-muted)", fontWeight: 500 }}>
            Menampilkan {filtered.length} data
          </span>
        </div>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Sumber</th>
              <th>Kendaraan</th>
              <th>Penyewa</th>
              <th>Mulai Sewa</th>
              <th>Selesai Sewa</th>
              <th>Lama Sewa</th>
              <th>Denda</th>
              <th>Total Biaya</th>
              <th>Status</th>
              <th className="no-print">Lampiran</th>
              <th className="no-print">Invoice</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              <tr>
                <td colSpan="12" style={{ textAlign: "center", padding: 30 }}>
                  <div className="spinner" style={{ margin: "0 auto" }}></div>
                </td>
              </tr>
            ) : filtered.length === 0 ? (
              <tr>
                <td colSpan="12" style={{ textAlign: "center", padding: 30, color: "var(--text-muted)" }}>
                  Tidak ada data penyewaan yang cocok dengan filter.
                </td>
              </tr>
            ) : (
              filtered.map(row => {
                const car = cars.find(c => c.id === row.carId);
                const bucket = bucketOf(row.status);
                return (
                  <tr key={`${row.source}-${row.id}`}>
                    <td data-label="ID" style={{ fontWeight: 700, fontFamily: "monospace" }}>{row.id}</td>
                    <td data-label="Sumber">
                      <span className="badge" style={{
                        background: row.source === "app" ? "rgba(59,130,246,0.12)"
                          : row.source === "manual" ? "rgba(16,185,129,0.12)" : "rgba(239,68,68,0.12)",
                        color: row.source === "app" ? "#2563EB"
                          : row.source === "manual" ? "#059669" : "#DC2626",
                        fontWeight: 700
                      }}>
                        {row.sourceLabel}
                      </span>
                    </td>
                    <td data-label="Kendaraan">
                      <div style={{ fontWeight: 600 }}>{car ? `${car.brand} ${car.model}` : "Kendaraan"}</div>
                      <div style={{ fontSize: 11, color: "var(--text-secondary)", fontFamily: "monospace", marginTop: 2 }}>
                        {car?.plate_number || "-"}
                      </div>
                    </td>
                    <td data-label="Penyewa">
                      <div>{row.customer}</div>
                      {row.note && (
                        <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 2 }}>{row.note}</div>
                      )}
                    </td>
                    <td data-label="Mulai Sewa">{row.start}</td>
                    <td data-label="Selesai Sewa">{row.end}</td>
                    <td data-label="Lama Sewa" style={{ fontWeight: 600 }}>{formatDuration(row.start, row.end)}</td>
                    <td data-label="Denda" style={{ fontWeight: 700, color: row.lateFee > 0 ? "#B45309" : "var(--text-muted)" }}>
                      {row.lateFee > 0 ? `Rp ${row.lateFee.toLocaleString("id-ID")}` : "-"}
                    </td>
                    <td data-label="Total Biaya" style={{ fontWeight: 800, color: "var(--primary)" }}>
                      {row.source === "maintenance" ? "-" : `Rp ${(row.total || 0).toLocaleString("id-ID")}`}
                      {row.lateFee > 0 && (
                        <div style={{ fontSize: 11, fontWeight: 500, color: "var(--text-secondary)" }}>
                          Sewa Rp {(row.sewa || 0).toLocaleString("id-ID")} + denda
                        </div>
                      )}
                    </td>
                    <td data-label="Status">
                      {row.source !== "maintenance" && isOverdue(row) ? (
                        <span className="badge" style={{ background: "rgba(245,158,11,0.18)", color: "#B45309", fontWeight: 700 }}>
                          TERLAMBAT
                        </span>
                      ) : (
                        <span className={`badge ${BUCKET_BADGE[bucket]}`}>
                          {row.source === "maintenance" && bucket === "berjalan" ? "PERAWATAN" : BUCKET_LABEL[bucket]}
                        </span>
                      )}
                    </td>
                    <td data-label="Lampiran" className="no-print">
                      {/* Lampiran hanya ada pada jadwal buatan sendiri (KTP penyewa
                          manual / dokumen perawatan); pesanan aplikasi belum punya. */}
                      {row.docUrl ? (
                        <a
                          href={`${BASE.replace("/api", "")}${row.docUrl}`}
                          target="_blank"
                          rel="noreferrer"
                          className="btn btn-ghost btn-sm"
                          style={{ display: "inline-flex", alignItems: "center", gap: 6 }}
                        >
                          <Paperclip size={14} /> Lihat
                        </a>
                      ) : (
                        <span style={{ color: "var(--text-muted)" }}>-</span>
                      )}
                    </td>
                    <td data-label="Invoice" className="no-print">
                      {/* Hanya sewa yang sudah selesai yang boleh ditagihkan;
                          perawatan tidak punya penyewa untuk dikirimi invoice. */}
                      {bucket === "selesai" && row.source !== "maintenance" ? (
                        <button
                          className="btn btn-ghost btn-sm"
                          onClick={() => setInvoice(
                            row.source === "app"
                              ? bookingInvoice(row.raw, car, rentalName)
                              : scheduleInvoice(row.raw, car, rentalName)
                          )}
                        >
                          <FileText size={14} /> Invoice
                        </button>
                      ) : (
                        <span style={{ color: "var(--text-muted)" }}>-</span>
                      )}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
      <InvoiceModal data={invoice} onClose={() => setInvoice(null)} />
    </div>
  );
}
