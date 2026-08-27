import { useState, useEffect } from "react";
import { Plus, Trash2, Shield, Eye, Settings, Car } from "lucide-react";
import { BASE, authFetch } from "../../api";
import { CAR_COLORS, carColor } from "./schedule";
import { toast, confirmDialog, Alert } from "../../components/Feedback";

// Deretan contoh warna; "Otomatis" mengembalikan pilihan ke urutan armada.
function PilihWarna({ nilai, onPilih, previewId, cars }) {
  return (
    <div className="input-group">
      <label>Warna di Kalender</label>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
        <button
          type="button"
          onClick={() => onPilih("")}
          title="Ikuti warna otomatis dari sistem"
          style={{
            display: "flex", alignItems: "center", gap: 6, cursor: "pointer",
            padding: "6px 10px", borderRadius: 8, fontSize: 12, fontWeight: 700,
            background: "var(--bg-input)", color: "var(--text-secondary)",
            border: `2px solid ${nilai === "" ? "var(--primary)" : "var(--border)"}`
          }}
        >
          <span style={{
            width: 12, height: 12, borderRadius: 3,
            background: previewId ? carColor(previewId, cars) : CAR_COLORS[cars.length % CAR_COLORS.length]
          }} />
          Otomatis
        </button>
        {CAR_COLORS.map(c => (
          <button
            key={c}
            type="button"
            onClick={() => onPilih(c)}
            aria-label={`Pilih warna ${c}`}
            style={{
              width: 30, height: 30, borderRadius: 8, cursor: "pointer", background: c,
              border: `2px solid ${nilai === c ? "var(--text-primary)" : "transparent"}`,
              outline: nilai === c ? "2px solid var(--bg-card)" : "none",
              outlineOffset: -4
            }}
          />
        ))}
      </div>
      <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 4 }}>
        Dipakai sebagai pembeda armada di Kalender Rental. Biarkan Otomatis kalau tidak ada preferensi.
      </div>
    </div>
  );
}

export default function CarManagement({ ownerPhone }) {
  const [cars, setCars] = useState([]);
  const [showAddForm, setShowAddForm] = useState(false);
  const [loading, setLoading] = useState(true);

  // Form states
  const [brand, setBrand] = useState("");
  const [model, setModel] = useState("");
  const [plate, setPlate] = useState("");
  const [transmission, setTransmission] = useState("Automatic");
  const [seats, setSeats] = useState(5);
  const [price, setPrice] = useState(300000);
  const [imageUrl, setImageUrl] = useState("");
  const [vehicleType, setVehicleType] = useState("car");
  // Kosong = warna dipilih otomatis dari urutan armada.
  const [color, setColor] = useState("");
  const [error, setError] = useState("");

  // Edit form states
  const [editingCar, setEditingCar] = useState(null);
  const [editBrand, setEditBrand] = useState("");
  const [editModel, setEditModel] = useState("");
  const [editPlate, setEditPlate] = useState("");
  const [editTransmission, setEditTransmission] = useState("Automatic");
  const [editSeats, setEditSeats] = useState(5);
  const [editPrice, setEditPrice] = useState(300000);
  const [editImageUrl, setEditImageUrl] = useState("");
  const [editVehicleType, setEditVehicleType] = useState("car");
  const [editStatus, setEditStatus] = useState("active");
  const [editColor, setEditColor] = useState("");

  const fetchCars = () => {
    setLoading(true);
    authFetch(`${BASE}/rental/cars?owner_phone=${encodeURIComponent(ownerPhone)}`)
      .then(r => r.json())
      .then(data => {
        setCars(Array.isArray(data) ? data : []);
        setLoading(false);
      })
      .catch(err => {
        console.error(err);
        setLoading(false);
      });
  };

  useEffect(() => {
    fetchCars();
  }, [ownerPhone]);

  const handleSubmit = (e) => {
    e.preventDefault();
    setError("");

    if (!brand || !model || !plate || !price) {
      setError("Semua field wajib diisi");
      return;
    }

    const defaultPlaceholder = vehicleType === "motorcycle" 
      ? "https://images.unsplash.com/photo-1558981806-ec527fa84c39?w=400"
      : "https://images.unsplash.com/photo-1549399542-7e3f8b79c341?w=400";

    const payload = {
      owner_phone: ownerPhone,
      brand,
      model,
      plate_number: plate,
      transmission,
      seats: parseInt(seats),
      price_per_day: parseFloat(price),
      image_url: imageUrl || defaultPlaceholder,
      vehicle_type: vehicleType,
      color,
      status: "active"
    };

    authFetch(`${BASE}/rental/cars`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) {
          setError(data.error);
        } else {
          // Clear form & close
          setBrand("");
          setModel("");
          setPlate("");
          setTransmission("Automatic");
          setSeats(5);
          setPrice(300000);
          setImageUrl("");
          setVehicleType("car");
          setColor("");
          setShowAddForm(false);
          fetchCars();
          toast.success("Kendaraan berhasil ditambahkan");
        }
      })
      .catch(err => setError(err.message || "Gagal menyimpan kendaraan"));
  };

  const handleDelete = async (id) => {
    const ok = await confirmDialog({
      title: "Hapus kendaraan ini?",
      message: "Kendaraan akan dihapus dari armada Anda. Riwayat sewa yang sudah tercatat tidak ikut terhapus.",
      confirmText: "Hapus kendaraan",
    });
    if (!ok) return;
    authFetch(`${BASE}/rental/cars/${id}`, { method: "DELETE" })
      .then(r => r.json())
      .then(() => {
        fetchCars();
        toast.success("Kendaraan berhasil dihapus");
      })
      .catch(err => toast.error(err.message || "Gagal menghapus kendaraan"));
  };

  const handleEditClick = (car) => {
    setError("");
    setEditingCar(car);
    setEditBrand(car.brand);
    setEditModel(car.model);
    setEditPlate(car.plate_number);
    setEditTransmission(car.transmission);
    setEditSeats(car.seats);
    setEditPrice(car.price_per_day);
    setEditImageUrl(car.image_url);
    setEditVehicleType(car.vehicle_type);
    setEditStatus(car.status);
    setEditColor(car.color || "");
  };

  const handleUpdate = (e) => {
    e.preventDefault();
    setError("");

    if (!editBrand || !editModel || !editPlate || !editPrice) {
      setError("Semua field wajib diisi");
      return;
    }

    const payload = {
      id: editingCar.id,
      owner_phone: ownerPhone,
      brand: editBrand,
      model: editModel,
      plate_number: editPlate,
      transmission: editTransmission,
      seats: parseInt(editSeats),
      price_per_day: parseFloat(editPrice),
      image_url: editImageUrl,
      vehicle_type: editVehicleType,
      color: editColor,
      status: editStatus
    };

    authFetch(`${BASE}/rental/cars/${editingCar.id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    })
      .then(r => r.json())
      .then(data => {
        if (data.error) {
          setError(data.error);
        } else {
          setEditingCar(null);
          fetchCars();
          toast.success("Data kendaraan berhasil diperbarui");
        }
      })
      .catch(err => setError(err.message || "Gagal memperbarui kendaraan"));
  };

  return (
    <div className="page">
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
        <div>
          <h1>Kelola Armada Kendaraan</h1>
          <p>Tambahkan dan atur data spesifikasi serta tarif sewa harian mobil & motor Anda</p>
        </div>
        <button onClick={() => setShowAddForm(!showAddForm)} className="btn btn-primary">
          <Plus size={18} /> {showAddForm ? "Tutup Form" : "Tambah Armada"}
        </button>
      </div>

      {showAddForm && (
        <div className="card" style={{ marginBottom: 28, maxWidth: 600 }}>
          <div className="card-title">Form Tambah Kendaraan Baru</div>
          <Alert type="error">{error}</Alert>
          <form onSubmit={handleSubmit}>
            <div className="grid-2">
              <div className="input-group">
                <label>Jenis Kendaraan</label>
                <select className="input" value={vehicleType} onChange={e => {
                  setVehicleType(e.target.value);
                  if (e.target.value === "motorcycle") {
                    setSeats(2);
                  } else {
                    setSeats(5);
                  }
                }}>
                  <option value="car">Mobil</option>
                  <option value="motorcycle">Motor</option>
                </select>
              </div>
              <div className="input-group">
                <label>Merk Kendaraan</label>
                <input className="input" placeholder={vehicleType === "motorcycle" ? "Contoh: Honda" : "Contoh: Toyota"} value={brand} onChange={e => setBrand(e.target.value)} required />
              </div>
            </div>

            <div className="grid-2">
              <div className="input-group">
                <label>Tipe / Model</label>
                <input className="input" placeholder={vehicleType === "motorcycle" ? "Contoh: Vario 160" : "Contoh: Avanza Veloz"} value={model} onChange={e => setModel(e.target.value)} required />
              </div>
              <div className="input-group">
                <label>Nomor Plat Kendaraan</label>
                <input className="input" placeholder="Contoh: KB 1234 XX" value={plate} onChange={e => setPlate(e.target.value)} required />
              </div>
            </div>

            <div className="grid-2">
              <div className="input-group">
                <label>Transmisi</label>
                <select className="input" value={transmission} onChange={e => setTransmission(e.target.value)}>
                  <option value="Automatic">Automatic (AT)</option>
                  <option value="Manual">Manual (MT)</option>
                </select>
              </div>
              <div className="input-group">
                <label>Kapasitas Kursi</label>
                <input className="input" type="number" min="1" max="15" value={seats} onChange={e => setSeats(e.target.value)} required />
              </div>
            </div>

            <div className="grid-2">
              <div className="input-group">
                <label>Tarif Harian (Rp)</label>
                <input className="input" type="number" step="5000" min="20000" value={price} onChange={e => setPrice(e.target.value)} required />
              </div>
              <div className="input-group">
                <label>Link Foto Kendaraan (URL)</label>
                <input className="input" placeholder="https://images.unsplash.com/..." value={imageUrl} onChange={e => setImageUrl(e.target.value)} />
              </div>
            </div>

            <PilihWarna nilai={color} onPilih={setColor} cars={cars} />

            <button type="submit" className="btn btn-primary" style={{ width: "100%", justifyContent: "center", padding: 12 }}>
              Daftarkan Kendaraan ke System
            </button>
          </form>
        </div>
      )}

      {loading ? (
        <div className="spinner" style={{ margin: "50px auto" }}></div>
      ) : cars.length === 0 ? (
        <div className="card" style={{ textAlign: "center", padding: 50, color: "var(--text-muted)" }}>
          <Car size={48} style={{ margin: "0 auto 16px", color: "var(--border)" }} />
          <h3>Belum ada kendaraan yang didaftarkan</h3>
          <p style={{ fontSize: 13, marginTop: 4 }}>Klik tombol Tambah Armada untuk mendaftarkan armada pertama Anda</p>
        </div>
      ) : (
        <div className="grid-3">
          {cars.map(car => (
            <div key={car.id} className="card" style={{ padding: 0, overflow: "hidden", display: "flex", flexDirection: "column" }}>
              <div style={{ height: "clamp(140px, 40vw, 180px)", width: "100%", overflow: "hidden", background: "var(--bg-input)", position: "relative" }}>
                <img 
                  src={car.image_url} 
                  alt={`${car.brand} ${car.model}`}
                  style={{ width: "100%", height: "100%", objectFit: "cover" }}
                  onError={(e) => {
                    e.target.src = car.vehicle_type === "motorcycle" 
                      ? "https://images.unsplash.com/photo-1558981806-ec527fa84c39?w=400"
                      : "https://images.unsplash.com/photo-1549399542-7e3f8b79c341?w=400";
                  }}
                />
                <span className="badge badge-success" style={{ position: "absolute", top: 12, right: 12, background: "rgba(37,99,235,0.92)", color: "white" }}>
                  {car.status.toUpperCase()}
                </span>
                <span className="badge badge-info" style={{ position: "absolute", top: 12, left: 12, background: "rgba(59,130,246,0.9)", color: "white" }}>
                  {car.vehicle_type === "motorcycle" ? "MOTOR" : "MOBIL"}
                </span>
              </div>
              <div style={{ padding: 20, flex: 1, display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
                <div>
                  <h3 style={{ fontSize: 18, fontWeight: 800 }}>{car.brand} {car.model}</h3>
                  <div style={{ display: "flex", gap: 8, fontSize: 12, color: "var(--text-secondary)", marginTop: 6, marginBottom: 16 }}>
                    <span style={{ background: "var(--bg-input)", padding: "2px 8px", borderRadius: 4 }}>{car.transmission}</span>
                    <span style={{ background: "var(--bg-input)", padding: "2px 8px", borderRadius: 4 }}>{car.seats} Kursi</span>
                    <span style={{ background: "var(--bg-input)", padding: "2px 8px", borderRadius: 4, fontFamily: "monospace" }}>{car.plate_number}</span>
                  </div>
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", borderTop: "1px solid var(--border)", paddingTop: 16 }}>
                  <div>
                    <span style={{ fontSize: 11, color: "var(--text-muted)" }}>Tarif Sewa</span>
                    <div style={{ fontSize: 18, fontWeight: 900, color: "var(--primary)" }}>
                      Rp {car.price_per_day.toLocaleString("id-ID")}<span style={{ fontSize: 12, fontWeight: 500, color: "var(--text-secondary)" }}>/hari</span>
                    </div>
                  </div>
                  <div style={{ display: "flex", gap: 8 }}>
                    <button onClick={() => handleEditClick(car)} className="btn btn-ghost btn-sm" style={{ padding: 8 }}>
                      <Settings size={16} />
                    </button>
                    <button onClick={() => handleDelete(car.id)} className="btn btn-danger btn-sm" style={{ padding: 8 }}>
                      <Trash2 size={16} />
                    </button>
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Modal Edit Kendaraan */}
      {editingCar && (
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
            maxWidth: "600px",
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
              <h3 style={{ margin: 0, fontSize: "18px", fontWeight: 800, display: "flex", alignItems: "center", gap: 8 }}>
                <Settings size={20} style={{ color: "var(--primary)" }} />
                <span>Edit Informasi Kendaraan</span>
              </h3>
              <button 
                onClick={() => setEditingCar(null)}
                style={{
                  background: "none",
                  border: "none",
                  fontSize: "20px",
                  cursor: "pointer",
                  color: "var(--text-secondary)",
                  lineHeight: 1
                }}
              >
                &times;
              </button>
            </div>

            {/* Modal Body */}
            <form onSubmit={handleUpdate} style={{ padding: "24px", display: "flex", flexDirection: "column", gap: "16px" }}>
              <Alert type="error" style={{ marginBottom: 0 }}>{error}</Alert>

              <div className="grid-2">
                <div className="input-group">
                  <label>Jenis Kendaraan</label>
                  <select className="input" value={editVehicleType} onChange={e => {
                    setEditVehicleType(e.target.value);
                    if (e.target.value === "motorcycle") {
                      setEditSeats(2);
                    } else {
                      setEditSeats(5);
                    }
                  }}>
                    <option value="car">Mobil</option>
                    <option value="motorcycle">Motor</option>
                  </select>
                </div>
                <div className="input-group">
                  <label>Merk Kendaraan</label>
                  <input className="input" placeholder="Contoh: Toyota" value={editBrand} onChange={e => setEditBrand(e.target.value)} required />
                </div>
              </div>

              <div className="grid-2">
                <div className="input-group">
                  <label>Tipe / Model</label>
                  <input className="input" placeholder="Contoh: Avanza" value={editModel} onChange={e => setEditModel(e.target.value)} required />
                </div>
                <div className="input-group">
                  <label>Nomor Plat Kendaraan</label>
                  <input className="input" placeholder="Contoh: KB 1234 XX" value={editPlate} onChange={e => setEditPlate(e.target.value)} required />
                </div>
              </div>

              <div className="grid-2">
                <div className="input-group">
                  <label>Transmisi</label>
                  <select className="input" value={editTransmission} onChange={e => setEditTransmission(e.target.value)}>
                    <option value="Automatic">Automatic (AT)</option>
                    <option value="Manual">Manual (MT)</option>
                  </select>
                </div>
                <div className="input-group">
                  <label>Kapasitas Kursi</label>
                  <input className="input" type="number" min="1" max="15" value={editSeats} onChange={e => setEditSeats(e.target.value)} required />
                </div>
              </div>

              <div className="grid-2">
                <div className="input-group">
                  <label>Tarif Harian (Rp)</label>
                  <input className="input" type="number" step="5000" min="20000" value={editPrice} onChange={e => setEditPrice(e.target.value)} required />
                </div>
                <div className="input-group">
                  <label>Status Armada</label>
                  <select className="input" value={editStatus} onChange={e => setEditStatus(e.target.value)}>
                    <option value="active">Aktif (Tersedia)</option>
                    <option value="inactive">Nonaktif</option>
                  </select>
                </div>
              </div>

              <div className="input-group">
                <label>Link Foto Kendaraan (URL)</label>
                <input className="input" placeholder="https://images.unsplash.com/..." value={editImageUrl} onChange={e => setEditImageUrl(e.target.value)} />
              </div>

              <PilihWarna nilai={editColor} onPilih={setEditColor} previewId={editingCar?.id} cars={cars} />

              {/* Modal Footer */}
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
                  onClick={() => setEditingCar(null)}
                  className="btn btn-secondary"
                  style={{ padding: "8px 16px", borderRadius: "8px", cursor: "pointer", fontSize: "13px", background: "var(--bg-input)", border: "1px solid var(--border)" }}
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="btn btn-primary"
                  style={{ padding: "8px 16px", borderRadius: "8px", color: "#fff", border: "none", fontWeight: 600, fontSize: "13px" }}
                >
                  Simpan Perubahan
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
