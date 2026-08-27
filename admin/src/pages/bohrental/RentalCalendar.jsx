import { useState, useEffect } from "react";
import { Calendar, Clock, CheckCircle, Trash2, Plus, Info, Edit, FileText } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { parseSchedule, scheduleCost, parseDT, overlaps, rentalDays, carColor } from "./schedule";
import { toast, confirmDialog, Alert } from "../../components/Feedback";
import { bookingInvoice, scheduleInvoice, useRentalName } from "./invoice";
import InvoiceModal from "./InvoiceModal";

export default function RentalCalendar({ ownerPhone }) {
  const [cars, setCars] = useState([]);
  const [selectedCar, setSelectedCar] = useState("all");

  // Calendars & Schedules data
  const [bookings, setBookings] = useState([]);
  const [schedules, setSchedules] = useState([]);
  const [services, setServices] = useState([]);
  const [loading, setLoading] = useState(true);

  // Modal details states
  const rentalName = useRentalName();
  const [invoice, setInvoice] = useState(null);
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [showModal, setShowModal] = useState(false);

  // Custom confirmation modal states

  // Form Modal state
  const [showFormModal, setShowFormModal] = useState(false);

  // Form block states
  const [blockCarId, setBlockCarId] = useState("");
  const [startDate, setStartDate] = useState("");
  const [startTime, setStartTime] = useState("08:00");
  const [endDate, setEndDate] = useState("");
  const [endTime, setEndTime] = useState("17:00");
  const [blockType, setBlockType] = useState("booking"); // "booking" or "maintenance"
  const [customerName, setCustomerName] = useState("");
  const [customerPhone, setCustomerPhone] = useState("");
  const [paymentMethod, setPaymentMethod] = useState("Tunai"); // "Tunai" or "Transfer"
  const [paymentTerm, setPaymentTerm] = useState("Full");     // "Full" or "DP"
  const [dpAmount, setDpAmount] = useState("");
  const [documentFile, setDocumentFile] = useState(null);
  const [existingDocUrl, setExistingDocUrl] = useState("");
  const [reason, setReason] = useState("Servis Berkala");
  const [serviceId, setServiceId] = useState("");
  const [editScheduleId, setEditScheduleId] = useState(null);

  // Alert states
  const [errorMsg, setErrorMsg] = useState("");
  const [formLoading, setFormLoading] = useState(false);

  // Date states for Monthly Grid
  const [currentDate, setCurrentDate] = useState(new Date());

  // Day sheet: agenda satu hari, jalur utama di layar HP
  const [daySheet, setDaySheet] = useState(null);

  // Jadwal yang sudah ditutup tidak mengunci armada dan tidak lagi ditampilkan
  // di mana pun pada halaman ini; riwayatnya dibaca di Laporan.
  const activeSchedules = schedules.filter(s => s.status !== "completed");

  // Pesanan yang sudah tutup buku juga tidak perlu memenuhi kalender. Kalender
  // dipakai untuk melihat armada mana yang sedang atau akan terpakai.
  const SUDAH_TUTUP = new Set(["completed", "cancelled", "rejected"]);

  // Ketersediaan diukur pada periode yang sedang diisi di form. Selama tanggalnya
  // belum lengkap, patokannya "sekarang" supaya kendaraan yang lagi jalan tidak
  // ikut ditawarkan begitu form dibuka.
  // ponytail: "sekarang" dibaca ulang tiap render, bukan disimpan di state — nilainya
  // memang harus ikut bergeser, dan yang dipengaruhi cuma isi dropdown.
  const now = new Date();
  const [winStart, winEnd] = startDate && endDate
    ? [parseDT(`${startDate} ${startTime}:00`), parseDT(`${endDate} ${endTime}:00`)]
    : [now, new Date(now.getTime() + 60000)];

  // Aturan bentrok dipakai bersama backend, supaya pilihan yang tersisa di form
  // tidak lagi ditolak 409 saat disimpan. Keduanya dipanggil hanya untuk jadwal
  // yang belum ditutup, sehingga jatuh tempo yang sudah lewat berarti kendaraannya
  // masih di luar dengan waktu kembali tak diketahui: armadanya menolak jadwal
  // baru kapan pun sampai ditekan "Selesai".
  const clashes = (otherStart, otherEnd) =>
    overlaps(winStart, winEnd, otherStart, otherEnd) || parseDT(otherEnd) < now;

  const busyCarIds = new Set([
    ...bookings
      .filter(b => !["cancelled", "rejected", "completed"].includes(b.status) && clashes(b.start_time, b.end_time))
      .map(b => b.car_id),
    // Jadwal yang sedang diubah tidak dihitung bentrok dengan dirinya sendiri.
    ...activeSchedules
      .filter(s => s.id !== editScheduleId && clashes(s.start_time, s.end_time))
      .map(s => s.car_id)
  ]);

  const availableCars = cars.filter(c => !busyCarIds.has(c.id));

  const fetchData = () => {
    setLoading(true);
    Promise.all([
      authFetch(`${BASE}/rental/cars?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/bookings?owner_phone=${encodeURIComponent(ownerPhone)}`).then(r => r.json()),
      authFetch(`${BASE}/rental/schedules`).then(r => r.json()),
      authFetch(`${BASE}/rental/services`).then(r => r.json())
    ])
      .then(([carsData, bookingsData, schedulesData, servicesData]) => {
        const activeCars = Array.isArray(carsData) ? carsData : [];
        setCars(activeCars);
        setBookings(Array.isArray(bookingsData) ? bookingsData : []);
        setSchedules(Array.isArray(schedulesData) ? schedulesData : []);
        setServices(Array.isArray(servicesData) ? servicesData : []);

        if (activeCars.length > 0 && !blockCarId) {
          setBlockCarId(activeCars[0].id);
        }
        setLoading(false);
      })
      .catch(err => {
        console.error("Error fetching calendar data:", err);
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchData();
  }, [ownerPhone]);

  const handleBlockSchedule = (e) => {
    e.preventDefault();
    setErrorMsg("");
    setFormLoading(true);

    if (!startDate || !startTime || !endDate || !endTime) {
      setErrorMsg("Semua input tanggal & jam wajib diisi");
      setFormLoading(false);
      return;
    }

    // Daftar pilihan sudah disaring, tapi tanggal bisa diubah setelah kendaraan
    // dipilih; tanpa cek ini kiriman berakhir ditolak 409 oleh backend.
    if (!availableCars.some(c => c.id === blockCarId)) {
      setErrorMsg("Pilih kendaraan yang bebas pada periode tersebut");
      setFormLoading(false);
      return;
    }

    const startFull = `${startDate} ${startTime}:00`;
    const endFull = `${endDate} ${endTime}:00`;

    if (new Date(startFull) >= new Date(endFull)) {
      setErrorMsg("Waktu mulai harus sebelum waktu selesai!");
      setFormLoading(false);
      return;
    }

    const submitPayload = (docUrl) => {
      let finalReason = reason;

      if (blockType === "booking") {
        if (!customerName || !customerPhone) {
          setErrorMsg("Nama dan No. HP Customer wajib diisi");
          setFormLoading(false);
          return;
        }
        if (paymentTerm === "DP" && !dpAmount) {
          setErrorMsg("Nominal DP wajib diisi jika memilih tipe DP");
          setFormLoading(false);
          return;
        }
        const svc = services.find(s => s.id === serviceId);
        finalReason = `Booking - Customer: ${customerName} (${customerPhone}) | Pembayaran: ${paymentMethod} | Tipe: ${paymentTerm}${paymentTerm === "DP" ? ` | Nominal DP: ${dpAmount}` : ""}`;
        if (svc) finalReason += ` | Jasa: ${svc.name} | Biaya Jasa: ${svc.price}`;
        if (docUrl) finalReason += ` | KTP: ${docUrl}`;
      } else if (docUrl) {
        finalReason += ` | Dokumen: ${docUrl}`;
      }

      const payload = {
        car_id: blockCarId,
        start_time: startFull,
        end_time: endFull,
        reason: finalReason || "Maintenance"
      };

      authFetch(editScheduleId ? `${BASE}/rental/schedules/${editScheduleId}` : `${BASE}/rental/schedules`, {
        method: editScheduleId ? "PUT" : "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload)
      })
        .then(async r => {
          const data = await r.json();
          if (!r.ok) throw new Error(data.error || (editScheduleId ? "Gagal mengubah jadwal" : "Gagal menambah jadwal"));
          return data;
        })
        .then(() => {
          toast.success(editScheduleId ? "Jadwal kendaraan berhasil diubah" : "Jadwal kendaraan berhasil ditambahkan");
          if (blockType === "booking") {
            setCustomerName("");
            setCustomerPhone("");
            setPaymentMethod("Tunai");
            setPaymentTerm("Full");
            setDpAmount("");
            setServiceId("");
          } else {
            setReason("Servis Berkala");
          }
          setDocumentFile(null);
          setExistingDocUrl("");
          setEditScheduleId(null);
          fetchData();
          setFormLoading(false);
          setShowFormModal(false);
        })
        .catch(err => {
          setErrorMsg(err.message);
          setFormLoading(false);
        });
    };

    if (documentFile) {
      const formData = new FormData();
      formData.append("file", documentFile);
      authFetch(`${BASE}/upload`, { method: "POST", body: formData })
        .then(async r => {
          const data = await r.json();
          if (!r.ok) throw new Error(data.error || "Gagal mengupload dokumen");
          return data.url;
        })
        .then(url => submitPayload(url))
        .catch(err => {
          setErrorMsg(err.message);
          setFormLoading(false);
        });
    } else {
      submitPayload(existingDocUrl);
    }
  };

  const handleDeleteClick = async (id) => {
    const ok = await confirmDialog({
      title: "Batalkan jadwal ini?",
      message: "Jadwal dihapus permanen dan tidak ikut tercatat di Laporan. Kalau sewanya sudah berjalan, pakai tombol Selesai supaya masuk riwayat transaksi.",
      confirmText: "Ya, hapus",
    });
    if (!ok) return;
    authFetch(`${BASE}/rental/schedules/${id}`, { method: "DELETE" })
      .then(r => r.json())
      .then(() => {
        setShowModal(false);
        setSelectedEvent(null);
        authFetch(`${BASE}/rental/schedules`)
          .then(r => r.json())
          .then(data => setSchedules(Array.isArray(data) ? data : []));
        toast.success("Jadwal berhasil dihapus");
      })
      .catch(err => toast.error(err.message || "Gagal menghapus jadwal"));
  };

  const handleEditSchedule = (schedule) => {
    setEditScheduleId(schedule.id);
    setBlockCarId(schedule.car_id);

    setStartDate(schedule.start_time.split(" ")[0] || schedule.start_time.split("T")[0]);
    const sTime = schedule.start_time.split(" ")[1] || schedule.start_time.split("T")[1];
    setStartTime(sTime ? sTime.substring(0, 5) : "08:00");

    setEndDate(schedule.end_time.split(" ")[0] || schedule.end_time.split("T")[0]);
    const eTime = schedule.end_time.split(" ")[1] || schedule.end_time.split("T")[1];
    setEndTime(eTime ? eTime.substring(0, 5) : "17:00");

    setDocumentFile(null);
    setExistingDocUrl("");

    const info = parseSchedule(schedule.reason);
    setExistingDocUrl(info.docUrl);

    if (info.isManual) {
      setBlockType("booking");
      setCustomerName(info.customerName);
      setCustomerPhone(info.customerPhone);
      setPaymentMethod(info.paymentMethod);
      setPaymentTerm(info.paymentTerm);
      setDpAmount(info.dpAmount ? String(info.dpAmount) : "");
      // Jasa dicocokkan balik lewat nama; kalau jasanya sudah dihapus, pilihan dikosongkan.
      setServiceId(services.find(s => s.name === info.serviceName)?.id || "");
      setReason("Servis Berkala");
    } else {
      setBlockType("maintenance");
      setReason(info.note);
      setCustomerName("");
      setCustomerPhone("");
      setPaymentMethod("Tunai");
      setPaymentTerm("Full");
      setDpAmount("");
      setServiceId("");
    }

    setShowModal(false);
    setShowFormModal(true);
  };

  // Jadwal yang selesai tidak dihapus: statusnya ditutup supaya tetap muncul di
  // Laporan sebagai riwayat, sementara armadanya sudah bebas dipesan lagi.
  // Denda keterlambatannya dihitung server saat penutupan dan dikirim balik.
  const handleCompleteSchedule = async (scheduleId) => {
    const ok = await confirmDialog({
      title: "Selesaikan jadwal ini?",
      message: "Kendaraan akan bebas dipesan lagi. Datanya tetap tersimpan di Laporan.",
      confirmText: "Selesaikan",
      tone: "primary",
    });
    if (!ok) return;
    authFetch(`${BASE}/rental/schedules/${scheduleId}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: "completed" })
    })
      .then(async r => {
        const data = await r.json();
        if (!r.ok) throw new Error(data.error || "Gagal menyelesaikan jadwal");
        return data;
      })
      .then(data => {
        setShowModal(false);
        setSelectedEvent(null);
        if (data.late_fee > 0) {
          toast.warning(`Sewa ditutup. Denda keterlambatan Rp ${data.late_fee.toLocaleString("id-ID")} sudah ditambahkan ke total dan tercatat di Laporan.`, 8000);
        } else {
          toast.success("Jadwal diselesaikan, kendaraan sudah bebas dipesan lagi");
        }
        fetchData();
      })
      .catch(err => toast.error(err.message || "Gagal menyelesaikan jadwal"));
  };

  const handleCompleteBooking = async (bookingId) => {
    const ok = await confirmDialog({
      title: "Tandai pesanan selesai?",
      message: "Armada akan dibebaskan dan pesanan masuk ke riwayat transaksi.",
      confirmText: "Tandai selesai",
      tone: "primary",
    });
    if (!ok) return;
    authFetch(`${BASE}/rental/bookings/${bookingId}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: "completed" })
    })
      .then(async r => {
        const data = await r.json();
        if (!r.ok) throw new Error(data.error || "Gagal menyelesaikan penyewaan");
        return data;
      })
      .then(() => {
        setShowModal(false);
        setSelectedEvent(null);
        fetchData();
        toast.success("Penyewaan berhasil diselesaikan");
      })
      .catch(err => toast.error(err.message || "Gagal menyelesaikan penyewaan"));
  };

  // Calendar helpers
  const getDaysInMonth = (year, month) => new Date(year, month + 1, 0).getDate();
  const getFirstDayOfMonth = (year, month) => new Date(year, month, 1).getDay();

  const year = currentDate.getFullYear();
  const month = currentDate.getMonth();
  const daysInMonth = getDaysInMonth(year, month);
  const firstDay = getFirstDayOfMonth(year, month);

  const prevMonth = () => setCurrentDate(new Date(year, month - 1, 1));
  const nextMonth = () => setCurrentDate(new Date(year, month + 1, 1));

  const monthNames = [
    "Januari", "Februari", "Maret", "April", "Mei", "Juni",
    "Juli", "Agustus", "September", "Oktober", "November", "Desember"
  ];

  // Helper to parse dates from string format: "YYYY-MM-DD HH:mm:ss" or ISO string
  const checkDateOverlap = (checkDateStr, startStr, endStr) => {
    const checkDate = new Date(checkDateStr);
    checkDate.setHours(0, 0, 0, 0);

    // Format target start and end dates
    const start = new Date(startStr.replace(" ", "T"));
    const end = new Date(endStr.replace(" ", "T"));

    const sDay = new Date(start); sDay.setHours(0, 0, 0, 0);
    const eDay = new Date(end); eDay.setHours(0, 0, 0, 0);

    return checkDate >= sDay && checkDate <= eDay;
  };

  // Generate blank calendar cell slots
  const calendarCells = [];
  for (let i = 0; i < firstDay; i++) {
    calendarCells.push(null);
  }
  for (let i = 1; i <= daysInMonth; i++) {
    calendarCells.push(i);
  }

  // Filter schedules based on selectedCar
  const getDayEvents = (dayNum) => {
    if (!dayNum) return [];

    // Construct check date
    const checkDateStr = `${year}-${String(month + 1).padStart(2, "0")}-${String(dayNum).padStart(2, "0")}`;
    const dayEvents = [];

    // 1. Check Bookings
    bookings.forEach(b => {
      if (SUDAH_TUTUP.has(b.status)) return;
      if (selectedCar !== "all" && b.car_id !== selectedCar) return;
      if (checkDateOverlap(checkDateStr, b.start_time, b.end_time)) {
        const car = cars.find(c => c.id === b.car_id);
        const carLabel = car ? `${car.brand} ${car.model}` : "Kendaraan";
        dayEvents.push({
          id: b.id,
          type: "booking",
          label: `Booked: ${carLabel} (${b.customer_phone})`,
          status: b.status,
          time: `${b.start_time.split(" ")[1] || ""} - ${b.end_time.split(" ")[1] || ""}`,
          raw: b,
          car: car
        });
      }
    });

    // 2. Check Schedules/Blocks
    activeSchedules.forEach(s => {
      if (selectedCar !== "all" && s.car_id !== selectedCar) return;
      if (checkDateOverlap(checkDateStr, s.start_time, s.end_time)) {
        const car = cars.find(c => c.id === s.car_id);
        const carLabel = car ? `${car.brand} ${car.model}` : "Kendaraan";
        const isManualBooking = parseSchedule(s.reason).isManual;
        dayEvents.push({
          id: s.id,
          type: "schedule",
          label: `${isManualBooking ? "Manual" : "Maint"}: ${carLabel} (${s.reason})`,
          status: "blocked",
          time: `${s.start_time.split(" ")[1] || ""} - ${s.end_time.split(" ")[1] || ""}`,
          raw: s,
          car: car,
          isManualBooking: isManualBooking
        });
      }
    });

    return dayEvents;
  };

  // Warna chip mengikuti KENDARAAN-nya, bukan jenis jadwalnya: saat satu hari
  // berisi beberapa mobil, itu yang paling perlu dibedakan sekilas. Jenis jadwal
  // tetap terbaca lewat ikon dan gaya garis tepinya.
  const eventColor = (e) => (e.car ? carColor(e.car.id, cars) : "#64748B");

  const eventIcon = (e) => {
    if (e.type === "schedule" && !e.isManualBooking) return "🔧";
    return e.car?.vehicle_type === "motorcycle" ? "🏍️" : "🚗";
  };


  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h1>Kalender Penjadwalan Rental</h1>
          <p>Tambah jadwal sewa harian/jam serta tanggal perawatan kendaraan</p>
        </div>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
        {/* Interactive Calendar Monthly Grid */}
        <div className="card">
          {/* Calendar Controller Header */}
          <div style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            marginBottom: 20,
            flexWrap: "wrap",
            gap: "16px"
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 12, width: "100%", justifyContent: "space-between", maxWidth: 320 }}>
              <button onClick={prevMonth} className="filter-btn" aria-label="Bulan sebelumnya">&lt;</button>
              <h2 style={{ fontSize: 16, fontWeight: 800, textAlign: "center", flex: 1 }}>{monthNames[month]} {year}</h2>
              <button onClick={nextMonth} className="filter-btn" aria-label="Bulan berikutnya">&gt;</button>
            </div>

            {/* Actions: Filter & Tambah Jadwal */}
            <div style={{ display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap", width: "100%" }}>
              {/* Filter Car Dropdown */}
              <div style={{ display: "flex", alignItems: "center", gap: 8, flex: "1 1 200px", minWidth: 0 }}>
                <span style={{ fontSize: 12, color: "var(--text-secondary)", whiteSpace: "nowrap" }}>Filter:</span>
                <select className="input" style={{ flex: 1, minWidth: 0, padding: "8px 12px" }} value={selectedCar} onChange={e => setSelectedCar(e.target.value)}>
                  <option value="all">Semua Kendaraan</option>
                  {cars.map(c => (
                    <option key={c.id} value={c.id}>{c.brand} {c.model} ({c.plate_number})</option>
                  ))}
                </select>
              </div>

              {/* Tombol Tambah Jadwal */}
              <button
                onClick={() => {
                  setErrorMsg("");
                  setEditScheduleId(null);
                  setShowFormModal(true);
                }}
                className="btn btn-primary"
                style={{
                  padding: "8px 16px",
                  borderRadius: "8px",
                  border: "none",
                  color: "#fff",
                  fontWeight: 600,
                  fontSize: "13px",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 6,
                  cursor: "pointer",
                  flex: "1 1 160px"
                }}
              >
                <Plus size={16} />
                <span>Tambah Jadwal</span>
              </button>
            </div>
          </div>

          {/* Calendar Grid Container */}
          <div style={{ display: "flex", flexDirection: "column", border: "1px solid var(--border)", borderRadius: 12, overflow: "hidden" }}>
            {/* Calendar Days Header */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(7, 1fr)", background: "var(--bg-header)", textAlign: "center", borderBottom: "1px solid var(--border)", padding: "10px 0" }}>
              {["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"].map(day => (
                <div key={day} style={{ fontSize: 11, fontWeight: 700, color: "var(--text-muted)" }}>{day}</div>
              ))}
            </div>

            {/* Calendar Grid Cells */}
            <div style={{ display: "grid", gridTemplateColumns: "repeat(7, 1fr)", background: "var(--bg-card)" }}>
              {calendarCells.map((day, idx) => {
                const events = getDayEvents(day);
                return (
                  <div
                    key={idx}
                    className="calendar-cell"
                    onClick={() => { if (events.length) setDaySheet({ day, events }); }}
                    style={{
                      cursor: day && events.length ? "pointer" : "default",
                      minHeight: "82px",
                      padding: "6px",
                      borderRight: "1px solid var(--border)",
                      borderBottom: "1px solid var(--border)",
                      display: "flex",
                      flexDirection: "column",
                      background: day ? "transparent" : "var(--bg-hover)",
                      position: "relative"
                    }}
                  >
                    {day && (
                      <>
                        <div style={{
                          fontWeight: 700,
                          fontSize: "11px",
                          marginBottom: "4px",
                          color: "var(--text-primary)",
                          opacity: 0.8
                        }}>
                          {day}
                        </div>
                        <div style={{ display: "flex", flexDirection: "column", gap: "3px", overflow: "hidden", flex: 1 }}>
                          {events.slice(0, 3).map((e, evIdx) => (
                            <div
                              key={evIdx}
                              className="cal-chip"
                              onClick={(ev) => { ev.stopPropagation(); setSelectedEvent(e); setShowModal(true); }}
                              style={{
                                fontSize: "10px",
                                padding: "2px 5px",
                                borderRadius: "5px",
                                fontWeight: "700",
                                display: "flex",
                                alignItems: "center",
                                gap: "3px",
                                textOverflow: "ellipsis",
                                whiteSpace: "nowrap",
                                overflow: "hidden",
                                background: `${eventColor(e)}14`,
                                color: eventColor(e),
                                // Perawatan digambar bergaris putus-putus supaya beda
                                // dari sewa meski warnanya sama-sama warna mobilnya.
                                border: `1px ${e.type === "schedule" && !e.isManualBooking ? "dashed" : "solid"} ${eventColor(e)}59`,
                                cursor: "pointer",
                                transition: "all 0.15s ease"
                              }}
                              title={`${e.label} | ${e.time}`}
                            >
                              <span className="cal-chip-icon" style={{ fontSize: "9px" }}>
                                {eventIcon(e)}
                              </span>
                              <span className="cal-chip-label" style={{ overflow: "hidden", textOverflow: "ellipsis", fontSize: "9px" }}>
                                {e.car?.plate_number ? e.car.plate_number : (e.car ? `${e.car.brand} ${e.car.model}` : "Kendaraan")}
                              </span>
                            </div>
                          ))}
                          {events.length > 3 && (
                            <div style={{
                              fontSize: "8px",
                              fontWeight: "800",
                              color: "var(--text-muted)",
                              textAlign: "center",
                              paddingTop: "2px",
                              cursor: "pointer",
                              textTransform: "uppercase"
                            }}>
                              + {events.length - 3} lainnya
                            </div>
                          )}
                        </div>
                      </>
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {/* Legenda: tiap armada punya warnanya sendiri di kalender */}
          {cars.length > 0 && (
            <div style={{ display: "flex", flexWrap: "wrap", gap: 10, marginTop: 14, alignItems: "center" }}>
              {cars.map(c => (
                <button
                  key={c.id}
                  onClick={() => setSelectedCar(selectedCar === c.id ? "all" : c.id)}
                  title={`${c.brand} ${c.model} — klik untuk menyaring kalender`}
                  style={{
                    display: "flex", alignItems: "center", gap: 6, cursor: "pointer",
                    padding: "5px 10px", borderRadius: 999, fontSize: 11, fontWeight: 700,
                    background: selectedCar === c.id ? `${carColor(c.id, cars)}1A` : "transparent",
                    border: `1px solid ${selectedCar === c.id ? carColor(c.id, cars) : "var(--border)"}`,
                    color: "var(--text-secondary)"
                  }}
                >
                  <span style={{ width: 10, height: 10, borderRadius: 3, background: carColor(c.id, cars), flexShrink: 0 }} />
                  <span>{c.plate_number || `${c.brand} ${c.model}`}</span>
                </button>
              ))}
              <span style={{ fontSize: 11, color: "var(--text-muted)", marginLeft: 4 }}>
                🔧 garis putus-putus = perawatan · ✅ pudar = selesai
              </span>
            </div>
          )}
        </div>

        {/* Bottom Section: Jadwal yang sedang berjalan */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 16 }}>Jadwal Berjalan</div>
          {activeSchedules.length === 0 ? (
            <div style={{ fontSize: 13, color: "var(--text-muted)", textAlign: "center", padding: "20px 0" }}>Tidak ada jadwal yang sedang berjalan</div>
          ) : (
            <div style={{
              display: "grid",
              gridTemplateColumns: "repeat(auto-fill, minmax(280px, 1fr))",
              gap: 16,
              maxHeight: 400,
              overflowY: "auto"
            }}>
              {activeSchedules.map(s => {
                const car = cars.find(c => c.id === s.car_id);
                const info = parseSchedule(s.reason);
                const isManualBooking = info.isManual;
                const cost = isManualBooking
                  ? scheduleCost(s.start_time, s.end_time, car?.price_per_day, info.serviceFee)
                  : null;
                return (
                  <div
                    key={s.id}
                    style={{
                      display: "flex",
                      justifyContent: "space-between",
                      alignItems: "center",
                      padding: 16,
                      background: "var(--bg-input)",
                      borderRadius: 12,
                      border: "1px solid var(--border)",
                      transition: "all 0.2s ease",
                      gap: 12
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontWeight: 700, fontSize: 14, color: "var(--text-primary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                        {car ? `${car.brand} ${car.model}` : "Kendaraan"}
                      </div>
                      <div style={{ fontSize: 11, fontFamily: "monospace", color: "var(--text-muted)", marginTop: 2 }}>
                        Plat: {car?.plate_number || "-"}
                      </div>
                      <div style={{
                        fontSize: 12,
                        color: isManualBooking ? "#059669" : "#DC2626",
                        fontWeight: 600,
                        marginTop: 6,
                        display: "flex",
                        alignItems: "center",
                        gap: 6
                      }}>
                        <span style={{
                          width: 8,
                          height: 8,
                          borderRadius: 3,
                          background: carColor(s.car_id, cars),
                          flexShrink: 0
                        }} />
                        <span style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                          {isManualBooking ? `Sewa: ${info.customerName || "Offline"}` : info.note}
                        </span>
                      </div>
                      <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 6, whiteSpace: "nowrap" }}>
                        {s.start_time} s/d {s.end_time}
                      </div>
                      {parseDT(s.end_time) < now && (
                        <div style={{ fontSize: 11, color: "#B45309", fontWeight: 700, marginTop: 4 }}>
                          Telat {rentalDays(s.end_time, now)} hari — kendaraan terkunci sampai ditandai Selesai
                        </div>
                      )}
                      {cost && cost.total > 0 && (
                        <div style={{ fontSize: 11, color: "var(--text-primary)", marginTop: 4, fontWeight: 700 }}>
                          {cost.days} hari · Rp {cost.total.toLocaleString("id-ID")}
                          {info.serviceName ? ` (termasuk ${info.serviceName})` : ""}
                        </div>
                      )}
                    </div>

                    <div style={{ display: "flex", gap: 6 }}>
                      <button
                        onClick={() => handleCompleteSchedule(s.id)}
                        className="btn btn-success btn-sm"
                        style={{
                          padding: "8px 12px",
                          borderRadius: "8px",
                          background: "rgba(16, 185, 129, 0.1)",
                          color: "#10B981",
                          border: "none",
                          cursor: "pointer",
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "center",
                          gap: 4,
                          fontSize: "11px",
                          fontWeight: 700
                        }}
                        title="Tandai selesai, bebaskan kendaraan, dan catat ke Laporan"
                      >
                        <CheckCircle size={14} />
                        <span>Selesai</span>
                      </button>

                      <button
                        onClick={() => handleEditSchedule(s)}
                        className="btn btn-warning btn-sm"
                        style={{
                          padding: "8px",
                          borderRadius: "8px",
                          background: "rgba(245, 158, 11, 0.1)",
                          color: "#F59E0B",
                          border: "none",
                          cursor: "pointer",
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "center"
                        }}
                        title="Edit data penjadwalan"
                      >
                        <Edit size={16} />
                      </button>

                      <button
                        onClick={() => handleDeleteClick(s.id)}
                        className="btn btn-danger btn-sm"
                        style={{
                          padding: "8px",
                          borderRadius: "8px",
                          background: "rgba(239, 68, 68, 0.1)",
                          color: "#EF4444",
                          border: "none",
                          cursor: "pointer",
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "center"
                        }}
                        title="Batal / Hapus Jadwal"
                      >
                        <Trash2 size={16} />
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {/* Bottom sheet: agenda satu hari (muncul saat sel kalender ditap) */}
      {daySheet && (
        <div
          onClick={() => setDaySheet(null)}
          style={{
            position: "fixed", inset: 0, background: "rgba(15,23,42,0.45)",
            display: "flex", alignItems: "flex-end", justifyContent: "center",
            zIndex: 9997, backdropFilter: "blur(2px)"
          }}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              width: "100%", maxWidth: 520, background: "var(--bg-card)",
              borderRadius: "18px 18px 0 0", border: "1px solid var(--border)",
              borderBottom: "none", maxHeight: "78vh", overflowY: "auto",
              padding: "8px 16px calc(20px + env(safe-area-inset-bottom))"
            }}
          >
            <div style={{ width: 44, height: 4, borderRadius: 99, background: "var(--border)", margin: "8px auto 14px" }} />
            <div style={{ fontSize: 15, fontWeight: 800, marginBottom: 2 }}>
              {daySheet.day} {monthNames[month]} {year}
            </div>
            <div style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 14 }}>
              {daySheet.events.length} jadwal pada hari ini
            </div>

            {daySheet.events.map((e, i) => (
              <button
                key={i}
                onClick={() => { setSelectedEvent(e); setShowModal(true); setDaySheet(null); }}
                style={{
                  width: "100%", textAlign: "left", cursor: "pointer",
                  display: "flex", alignItems: "center", gap: 12, marginBottom: 8,
                  padding: "12px 14px", borderRadius: 12, background: "var(--bg-input)",
                  border: "1px solid var(--border)",
                  borderLeft: `4px solid ${eventColor(e)}`
                }}
              >
                <span style={{ fontSize: 18 }}>
                  {eventIcon(e)}
                </span>
                <span style={{ flex: 1, minWidth: 0 }}>
                  <span style={{ display: "block", fontSize: 13, fontWeight: 700, color: "var(--text-primary)" }}>
                    {e.car ? `${e.car.brand} ${e.car.model}` : "Kendaraan"}
                    {e.car?.plate_number ? ` · ${e.car.plate_number}` : ""}
                  </span>
                  <span style={{ display: "block", fontSize: 11, color: "var(--text-secondary)", marginTop: 2 }}>
                    {e.time} · {e.type === "booking" ? "Booking aplikasi" : (e.isManualBooking ? "Booking manual" : "Perawatan")}
                  </span>
                </span>
                <Info size={16} style={{ color: "var(--text-muted)", flexShrink: 0 }} />
              </button>
            ))}

            <button onClick={() => setDaySheet(null)} className="btn btn-ghost" style={{ width: "100%", justifyContent: "center", marginTop: 10 }}>
              Tutup
            </button>
          </div>
        </div>
      )}

      {/* Modal Detail Event */}
      {showModal && selectedEvent && (
        <div style={{
          position: "fixed",
          top: 0,
          left: 0,
          width: "100vw",
          height: "100vh",
          backgroundColor: "rgba(0, 0, 0, 0.6)",
          display: "flex",
          justifyContent: "center",
          alignItems: "flex-start",
          overflowY: "auto",
          padding: "clamp(12px, 5vw, 40px) 12px",
          zIndex: 9999,
          backdropFilter: "blur(4px)",
          boxSizing: "border-box"
        }}>
          <div className="card" style={{
            width: "100%",
            maxWidth: "500px",
            background: "var(--bg-card, #fff)",
            borderRadius: "16px",
            boxShadow: "0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04)",
            border: "1px solid var(--border)",
            margin: "auto",
            overflow: "hidden",
            padding: 0
          }}>
            {/* Modal Header */}
            <div style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              padding: "20px 24px",
              borderBottom: "1px solid var(--border)",
              background: "var(--bg-header, #f8fafc)"
            }}>
              <h3 style={{ margin: 0, fontSize: "18px", fontWeight: 800 }}>
                {selectedEvent.type === "booking" ? "Detail Pemesanan Sewa" : "Detail Jadwal"}
              </h3>
              <button
                onClick={() => { setShowModal(false); setSelectedEvent(null); }}
                style={{ background: "none", border: "none", fontSize: "20px", cursor: "pointer", color: "var(--text-secondary)", lineHeight: 1 }}
              >
                &times;
              </button>
            </div>

            {/* Modal Body */}
            <div style={{ padding: "24px", display: "flex", flexDirection: "column", gap: "16px" }}>
              <div style={{ display: "flex", gap: "12px", alignItems: "center", paddingBottom: "16px", borderBottom: "1px solid var(--border)" }}>
                <div style={{
                  width: "48px",
                  height: "48px",
                  borderRadius: "10px",
                  backgroundColor: "rgba(37, 99, 235, 0.08)",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  color: "var(--primary)"
                }}>
                  <Calendar size={24} />
                </div>
                <div>
                  <h4 style={{ margin: 0, fontSize: "16px", fontWeight: 700 }}>
                    {selectedEvent.car ? `${selectedEvent.car.brand} ${selectedEvent.car.model}` : "Kendaraan"}
                  </h4>
                  <div style={{ fontSize: "12px", color: "var(--text-secondary)", marginTop: "2px" }}>
                    Plat No: <span style={{ fontFamily: "monospace", fontWeight: 600 }}>{selectedEvent.car?.plate_number || "-"}</span>
                    {" | Tipe: "}
                    {selectedEvent.car?.vehicle_type === "motorcycle" ? "Motor" : "Mobil"}
                  </div>
                </div>
              </div>

              {selectedEvent.type === "booking" ? (
                <div style={{ display: "flex", flexDirection: "column", gap: "12px" }}>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-secondary)" }}>ID Booking:</span>
                    <strong style={{ fontFamily: "monospace" }}>{selectedEvent.raw.id}</strong>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-secondary)" }}>Nomor Penyewa:</span>
                    <strong>{selectedEvent.raw.customer_phone}</strong>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-secondary)" }}>Waktu Mulai:</span>
                    <strong>{selectedEvent.raw.start_time}</strong>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-secondary)" }}>Waktu Selesai:</span>
                    <strong>{selectedEvent.raw.end_time}</strong>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                    <span style={{ color: "var(--text-secondary)" }}>Total Harga:</span>
                    <strong style={{ color: "var(--primary)", fontSize: "15px" }}>
                      Rp {selectedEvent.raw.total_price.toLocaleString("id-ID")}
                    </strong>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", alignItems: "center" }}>
                    <span style={{ color: "var(--text-secondary)" }}>Status Sewa:</span>
                    <span className={`badge ${selectedEvent.raw.status === "pending" ? "badge-warning" :
                      selectedEvent.raw.status === "confirmed" ? "badge-info" :
                      selectedEvent.raw.status === "ongoing" ? "badge-primary" :
                      selectedEvent.raw.status === "completed" ? "badge-success" : "badge-danger"
                      }`}>
                      {selectedEvent.raw.status.toUpperCase()}
                    </span>
                  </div>
                </div>
              ) : (() => {
                const info = parseSchedule(selectedEvent.raw.reason);
                const isManual = info.isManual;
                const { customerName: custName, customerPhone: custPhone, paymentMethod: payMethod,
                  paymentTerm: payTerm, dpAmount: dpVal, serviceName: jasaName, serviceFee: jasaFee } = info;
                const ktpUrl = isManual ? info.docUrl : "";
                const docUrl = isManual ? "" : info.docUrl;

                const cost = isManual
                  ? scheduleCost(selectedEvent.raw.start_time, selectedEvent.raw.end_time, selectedEvent.car?.price_per_day, jasaFee)
                  : { days: 0, rental: 0, service: 0, total: 0 };
                const tagihan = cost.total + (selectedEvent.raw.late_fee || 0);
                const sisaBayar = payTerm === "DP" && dpVal ? Math.max(0, tagihan - dpVal) : 0;

                return (
                  <div style={{ display: "flex", flexDirection: "column", gap: "12px" }}>
                    <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                      <span style={{ color: "var(--text-secondary)" }}>ID Jadwal:</span>
                      <strong style={{ fontFamily: "monospace" }}>{selectedEvent.raw.id}</strong>
                    </div>

                    {isManual ? (
                      <>
                        <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                          <span style={{ color: "var(--text-secondary)" }}>Nama Penyewa:</span>
                          <strong>{custName || "-"}</strong>
                        </div>
                        <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                          <span style={{ color: "var(--text-secondary)" }}>No. HP Penyewa:</span>
                          <strong>{custPhone || "-"}</strong>
                        </div>
                        {jasaName && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                            <span style={{ color: "var(--text-secondary)" }}>Jasa / Layanan:</span>
                            <strong>{jasaName}{jasaFee > 0 ? ` (+Rp ${jasaFee.toLocaleString("id-ID")}/hari)` : ""}</strong>
                          </div>
                        )}
                        {cost.days > 0 && (
                          <div style={{ background: "var(--bg-input)", border: "1px solid var(--border)", borderRadius: 10, padding: 12, display: "flex", flexDirection: "column", gap: 6 }}>
                            <div style={{ display: "flex", justifyContent: "space-between", fontSize: "12px" }}>
                              <span style={{ color: "var(--text-secondary)" }}>
                                Sewa {cost.days} hari × Rp {(selectedEvent.car?.price_per_day || 0).toLocaleString("id-ID")}
                              </span>
                              <span>Rp {cost.rental.toLocaleString("id-ID")}</span>
                            </div>
                            {cost.service > 0 && (
                              <div style={{ display: "flex", justifyContent: "space-between", fontSize: "12px" }}>
                                <span style={{ color: "var(--text-secondary)" }}>
                                  Jasa {cost.days} hari × Rp {jasaFee.toLocaleString("id-ID")}
                                </span>
                                <span>Rp {cost.service.toLocaleString("id-ID")}</span>
                              </div>
                            )}
                            {selectedEvent.raw.late_fee > 0 && (
                              <div style={{ display: "flex", justifyContent: "space-between", fontSize: "12px" }}>
                                <span style={{ color: "#B45309" }}>Denda keterlambatan</span>
                                <span style={{ color: "#B45309", fontWeight: 700 }}>
                                  Rp {selectedEvent.raw.late_fee.toLocaleString("id-ID")}
                                </span>
                              </div>
                            )}
                            <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", paddingTop: 6, borderTop: "1px dashed var(--border)" }}>
                              <strong>Total Tarif Sewa:</strong>
                              <strong style={{ color: "var(--primary)" }}>
                                Rp {(cost.total + (selectedEvent.raw.late_fee || 0)).toLocaleString("id-ID")}
                              </strong>
                            </div>
                          </div>
                        )}
                        {payMethod && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                            <span style={{ color: "var(--text-secondary)" }}>Metode Pembayaran:</span>
                            <span className="badge badge-info" style={{ background: "rgba(59, 130, 246, 0.15)", color: "#3B82F6", fontWeight: 700 }}>
                              {payMethod.toUpperCase()}
                            </span>
                          </div>
                        )}
                        {payTerm && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                            <span style={{ color: "var(--text-secondary)" }}>Tipe Pembayaran:</span>
                            <span className="badge" style={{ background: "rgba(245, 158, 11, 0.15)", color: "#F59E0B", fontWeight: 700 }}>
                              {payTerm === "DP" ? "DP (Uang Muka)" : "LUNAS / FULL"}
                            </span>
                          </div>
                        )}
                        {payTerm === "DP" && dpVal && (
                          <>
                            <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                              <span style={{ color: "var(--text-secondary)" }}>Nominal DP:</span>
                              <strong style={{ color: "#10B981" }}>Rp {dpVal.toLocaleString("id-ID")}</strong>
                            </div>
                            <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", paddingTop: "6px", borderTop: "1px dashed var(--border)" }}>
                              <span style={{ color: "var(--text-secondary)", fontWeight: 700 }}>Sisa Pembayaran:</span>
                              <strong style={{ color: "#EF4444", fontSize: "14px" }}>Rp {sisaBayar.toLocaleString("id-ID")}</strong>
                            </div>
                          </>
                        )}
                        {ktpUrl && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", alignItems: "center" }}>
                            <span style={{ color: "var(--text-secondary)" }}>KTP / Dokumen:</span>
                            <a
                              href={`${BASE.replace("/api", "")}${ktpUrl}`}
                              target="_blank"
                              rel="noreferrer"
                              style={{ color: "#3B82F6", textDecoration: "underline", fontWeight: 600 }}
                            >
                              Lihat Lampiran
                            </a>
                          </div>
                        )}
                      </>
                    ) : (
                      <div style={{ display: "flex", flexDirection: "column", gap: "12px" }}>
                        <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                          <span style={{ color: "var(--text-secondary)" }}>Alasan / Keterangan:</span>
                          <strong>{info.note}</strong>
                        </div>
                        {docUrl && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", alignItems: "center" }}>
                            <span style={{ color: "var(--text-secondary)" }}>Dokumen Lampiran:</span>
                            <a
                              href={`${BASE.replace("/api", "")}${docUrl}`}
                              target="_blank"
                              rel="noreferrer"
                              style={{ color: "#3B82F6", textDecoration: "underline", fontWeight: 600 }}
                            >
                              Lihat Dokumen
                            </a>
                          </div>
                        )}
                      </div>
                    )}

                    <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                      <span style={{ color: "var(--text-secondary)" }}>Waktu Mulai:</span>
                      <strong>{selectedEvent.raw.start_time}</strong>
                    </div>
                    <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px" }}>
                      <span style={{ color: "var(--text-secondary)" }}>Waktu Selesai:</span>
                      <strong>{selectedEvent.raw.end_time}</strong>
                    </div>
                    <div style={{ display: "flex", justifyContent: "space-between", fontSize: "13px", alignItems: "center" }}>
                      <span style={{ color: "var(--text-secondary)" }}>Status:</span>
                      {selectedEvent.raw.status === "completed" ? (
                        <span className="badge" style={{ background: "rgba(100,116,139,0.2)", color: "#64748B" }}>
                          SELESAI
                        </span>
                      ) : isManual ? (
                        <span className="badge badge-success" style={{ background: "rgba(16,185,129,0.2)", color: "#10B981" }}>
                          SEWA MANUAL (OFFLINE)
                        </span>
                      ) : (
                        <span className="badge badge-danger" style={{ background: "rgba(239,68,68,0.2)", color: "#EF4444" }}>
                          BERJALAN / PERAWATAN
                        </span>
                      )}
                    </div>
                  </div>
                );
              })()}
            </div>

            {/* Modal Footer */}
            <div style={{
              padding: "16px 24px",
              borderTop: "1px solid var(--border)",
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              gap: 10,
              flexWrap: "wrap",
              background: "var(--bg-header, #f8fafc)"
            }}>
              <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
                {selectedEvent.type === "schedule" && selectedEvent.raw.status !== "completed" && (
                  <>
                    <button
                      onClick={() => handleEditSchedule(selectedEvent.raw)}
                      className="btn btn-warning"
                      style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "#F59E0B", color: "#fff", border: "none", fontWeight: 600 }}
                    >
                      Edit
                    </button>
                    <button
                      onClick={() => handleDeleteClick(selectedEvent.id)}
                      className="btn btn-danger"
                      style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "#EF4444", color: "#fff", border: "none" }}
                    >
                      Hapus
                    </button>
                    <button
                      onClick={() => handleCompleteSchedule(selectedEvent.id)}
                      className="btn btn-success"
                      style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "#10B981", color: "#fff", border: "none", fontWeight: 600 }}
                    >
                      Selesai &amp; Bebaskan
                    </button>
                  </>
                )}
                {/* Hanya pesanan yang sudah disetujui yang boleh ditutup di sini;
                    yang masih pending ditindak di halaman Pesanan Masuk. */}
                {selectedEvent.type === "booking" &&
                  (selectedEvent.raw.status === "confirmed" || selectedEvent.raw.status === "ongoing") && (
                    <button
                      onClick={() => handleCompleteBooking(selectedEvent.raw.id)}
                      className="btn btn-success"
                      style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "#10B981", color: "#fff", border: "none", fontWeight: 600 }}
                    >
                      Tandai Selesai (Bebaskan Armada)
                    </button>
                  )}
              </div>

              <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
                {(() => {
                  const isBooking = selectedEvent.type === "booking";
                  const info = isBooking ? null : parseSchedule(selectedEvent.raw.reason);
                  // Perawatan tidak punya penyewa, jadi tidak ada yang bisa ditagih.
                  if (!isBooking && !info.isManual) return null;
                  return (
                    <button
                      onClick={() => setInvoice(
                        isBooking
                          ? bookingInvoice(selectedEvent.raw, selectedEvent.car, rentalName)
                          : scheduleInvoice(selectedEvent.raw, selectedEvent.car, rentalName)
                      )}
                      className="btn btn-primary"
                      style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", fontWeight: 600 }}
                    >
                      <FileText size={15} /> Invoice
                    </button>
                  );
                })()}
                <button
                  onClick={() => { setShowModal(false); setSelectedEvent(null); }}
                  className="btn btn-secondary"
                  style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "var(--bg-input)", border: "1px solid var(--border)" }}
                >
                  Tutup
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Modal Form Tambah / Edit Jadwal */}
      {showFormModal && (
        <div style={{
          position: "fixed",
          top: 0,
          left: 0,
          width: "100vw",
          height: "100vh",
          backgroundColor: "rgba(0, 0, 0, 0.6)",
          display: "flex",
          justifyContent: "center",
          alignItems: "flex-start",
          overflowY: "auto",
          padding: "clamp(12px, 5vw, 40px) 12px",
          zIndex: 9998,
          backdropFilter: "blur(4px)",
          boxSizing: "border-box"
        }}>
          <div className="card" style={{
            width: "100%",
            maxWidth: "500px",
            background: "var(--bg-card, #fff)",
            borderRadius: "16px",
            boxShadow: "0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04)",
            border: "1px solid var(--border)",
            margin: "auto",
            overflow: "hidden",
            padding: 0
          }}>
            <div style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              padding: "20px 24px",
              borderBottom: "1px solid var(--border)",
              background: "var(--bg-header, #f8fafc)"
            }}>
              <h3 style={{ margin: 0, fontSize: "18px", fontWeight: 800, display: "flex", alignItems: "center", gap: 8 }}>
                <Clock size={20} style={{ color: "var(--primary)" }} />
                <span>{editScheduleId ? "Ubah Jadwal Kendaraan" : "Tambah Jadwal Kendaraan"}</span>
              </h3>
              <button
                onClick={() => setShowFormModal(false)}
                style={{ background: "none", border: "none", fontSize: "20px", cursor: "pointer", color: "var(--text-secondary)", lineHeight: 1 }}
              >
                &times;
              </button>
            </div>

            <form onSubmit={handleBlockSchedule} style={{ padding: "24px", display: "flex", flexDirection: "column", gap: "16px" }}>
              <Alert type="error" style={{ marginBottom: 0 }}>{errorMsg}</Alert>

              <div className="input-group">
                <label>Pilih Kendaraan</label>
                <select className="input" value={availableCars.some(c => c.id === blockCarId) ? blockCarId : ""} onChange={e => setBlockCarId(e.target.value)}>
                  {!availableCars.some(c => c.id === blockCarId) && (
                    <option value="">— Pilih kendaraan —</option>
                  )}
                  {availableCars.map(c => (
                    <option key={c.id} value={c.id}>{c.brand} {c.model} ({c.plate_number})</option>
                  ))}
                </select>
                {availableCars.length === 0 ? (
                  <div style={{ fontSize: 12, color: "#EF4444", marginTop: 4 }}>
                    Tidak ada kendaraan yang bebas pada {startDate && endDate ? "periode tersebut" : "saat ini"}.
                    Ubah tanggalnya, atau selesaikan dulu jadwal yang sedang berjalan.
                  </div>
                ) : cars.length > availableCars.length && (
                  <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>
                    {cars.length - availableCars.length} kendaraan disembunyikan karena sudah ada jadwal
                    {startDate && endDate ? " pada periode tersebut" : " yang sedang berjalan"}, atau belum
                    dikembalikan melewati jatuh tempo.
                  </div>
                )}
              </div>

              <div className="grid-2">
                <div className="input-group">
                  <label>Tanggal Mulai</label>
                  <input className="input" type="date" value={startDate} onChange={e => setStartDate(e.target.value)} required />
                </div>
                <div className="input-group">
                  <label>Jam Mulai</label>
                  <input className="input" type="time" value={startTime} onChange={e => setStartTime(e.target.value)} required />
                </div>
              </div>

              <div className="grid-2">
                <div className="input-group">
                  <label>Tanggal Selesai</label>
                  <input className="input" type="date" value={endDate} onChange={e => setEndDate(e.target.value)} required />
                </div>
                <div className="input-group">
                  <label>Jam Selesai</label>
                  <input className="input" type="time" value={endTime} onChange={e => setEndTime(e.target.value)} required />
                </div>
              </div>

              <div className="input-group">
                <label>Tipe Jadwal</label>
                <select className="input" value={blockType} onChange={e => setBlockType(e.target.value)}>
                  <option value="booking">Sewa Manual (Penyewa Offline)</option>
                  <option value="maintenance">Perawatan / Servis / Jadwal Lainnya</option>
                </select>
              </div>

              {blockType === "booking" ? (
                <>
                  <div className="grid-2">
                    <div className="input-group">
                      <label>Nama Penyewa</label>
                      <input className="input" placeholder="Nama lengkap penyewa" value={customerName} onChange={e => setCustomerName(e.target.value)} required />
                    </div>
                    <div className="input-group">
                      <label>No. HP Penyewa</label>
                      <input className="input" placeholder="Contoh: 0812345678" value={customerPhone} onChange={e => setCustomerPhone(e.target.value)} required />
                    </div>
                  </div>

                  <div className="input-group">
                    <label>Jasa / Layanan</label>
                    <select className="input" value={serviceId} onChange={e => setServiceId(e.target.value)}>
                      <option value="">Tanpa jasa tambahan</option>
                      {services.map(s => (
                        <option key={s.id} value={s.id}>
                          {s.name}{s.price > 0 ? ` (+Rp ${s.price.toLocaleString("id-ID")}/hari)` : ""}
                        </option>
                      ))}
                    </select>
                    {services.length === 0 && (
                      <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>
                        Belum ada jasa. Tambahkan di menu <a href="#/services" style={{ color: "#3B82F6", textDecoration: "underline" }}>Jasa Layanan</a>.
                      </div>
                    )}
                  </div>

                  <div className="grid-2">
                    <div className="input-group">
                      <label>Metode Pembayaran</label>
                      <select className="input" value={paymentMethod} onChange={e => setPaymentMethod(e.target.value)}>
                        <option value="Tunai">Tunai (Cash)</option>
                        <option value="Transfer">Transfer Bank</option>
                      </select>
                    </div>
                    <div className="input-group">
                      <label>Tipe Pembayaran</label>
                      <select className="input" value={paymentTerm} onChange={e => setPaymentTerm(e.target.value)}>
                        <option value="Full">Bayar Full (Lunas)</option>
                        <option value="DP">Bayar di Awal (DP)</option>
                      </select>
                    </div>
                  </div>

                  {paymentTerm === "DP" && (
                    <div className="input-group">
                      <label>Nominal Uang Muka / DP (Rp)</label>
                      <input
                        className="input"
                        type="number"
                        placeholder="Contoh: 150000"
                        value={dpAmount}
                        onChange={e => setDpAmount(e.target.value)}
                        required
                      />
                    </div>
                  )}

                  {/* Rincian tarif otomatis: lama sewa x harga mobil, ditambah jasa bila dipilih */}
                  {(() => {
                    const car = cars.find(c => c.id === blockCarId);
                    const svc = services.find(s => s.id === serviceId);
                    const est = scheduleCost(`${startDate} ${startTime}:00`, `${endDate} ${endTime}:00`, car?.price_per_day, svc?.price);
                    if (!car || !startDate || !endDate || est.days === 0) {
                      return (
                        <div style={{ fontSize: 12, color: "var(--text-muted)", background: "var(--bg-input)", border: "1px dashed var(--border)", borderRadius: 10, padding: 12 }}>
                          Lengkapi kendaraan dan tanggal untuk melihat total tarif sewa.
                        </div>
                      );
                    }
                    const sisa = paymentTerm === "DP" ? Math.max(0, est.total - (parseFloat(dpAmount) || 0)) : 0;
                    return (
                      <div style={{ background: "var(--bg-input)", border: "1px solid var(--border)", borderRadius: 10, padding: 14, display: "flex", flexDirection: "column", gap: 8 }}>
                        <div style={{ fontSize: 12, fontWeight: 800, color: "var(--text-primary)" }}>Rincian Tarif</div>
                        <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
                          <span style={{ color: "var(--text-secondary)" }}>
                            Sewa {est.days} hari × Rp {(car.price_per_day || 0).toLocaleString("id-ID")}
                          </span>
                          <span>Rp {est.rental.toLocaleString("id-ID")}</span>
                        </div>
                        {est.service > 0 && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
                            <span style={{ color: "var(--text-secondary)" }}>
                              {svc.name} {est.days} hari × Rp {svc.price.toLocaleString("id-ID")}
                            </span>
                            <span>Rp {est.service.toLocaleString("id-ID")}</span>
                          </div>
                        )}
                        <div style={{ display: "flex", justifyContent: "space-between", fontSize: 13, paddingTop: 8, borderTop: "1px dashed var(--border)" }}>
                          <strong>Total Tarif</strong>
                          <strong style={{ color: "var(--primary)" }}>Rp {est.total.toLocaleString("id-ID")}</strong>
                        </div>
                        {paymentTerm === "DP" && (
                          <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
                            <span style={{ color: "var(--text-secondary)" }}>Sisa setelah DP</span>
                            <strong style={{ color: "#EF4444" }}>Rp {sisa.toLocaleString("id-ID")}</strong>
                          </div>
                        )}
                      </div>
                    );
                  })()}
                </>
              ) : (
                <div className="input-group">
                  <label>Alasan / Keterangan Jadwal</label>
                  <input className="input" placeholder="Contoh: Servis Rutin / Ganti Oli" value={reason} onChange={e => setReason(e.target.value)} required />
                </div>
              )}

              <div className="input-group">
                <label>Upload {blockType === "booking" ? "KTP" : "Dokumen"} Pendukung (Opsional)</label>
                <input
                  type="file"
                  className="input"
                  accept="image/*,.pdf,.heic,.heif"
                  onChange={e => setDocumentFile(e.target.files[0])}
                  style={{ padding: "8px" }}
                />
                {existingDocUrl && !documentFile && (
                  <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>
                    File saat ini:{" "}
                    <a
                      href={`${BASE.replace("/api", "")}${existingDocUrl}`}
                      target="_blank"
                      rel="noreferrer"
                      style={{ color: "#3B82F6", textDecoration: "underline" }}
                    >
                      Lihat File
                    </a>
                  </div>
                )}
              </div>

              <div style={{
                margin: "8px -24px -24px -24px",
                padding: "16px 24px",
                borderTop: "1px solid var(--border)",
                display: "flex",
                justifyContent: "flex-end",
                gap: "12px",
                background: "var(--bg-header, #f8fafc)"
              }}>
                <button
                  type="button"
                  onClick={() => setShowFormModal(false)}
                  className="btn btn-secondary"
                  style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "var(--bg-input)", border: "1px solid var(--border)" }}
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="btn btn-primary"
                  style={{ padding: "8px 16px", borderRadius: "8px", color: "#fff", border: "none", fontWeight: 600, fontSize: "13px" }}
                  disabled={formLoading}
                >
                  {formLoading ? "Memvalidasi..." : "Simpan Jadwal"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
      <InvoiceModal data={invoice} onClose={() => setInvoice(null)} />
    </div>
  );
}
