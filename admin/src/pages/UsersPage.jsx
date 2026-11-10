import { useEffect, useState } from "react";
import { Search, Bike, User, Trash2, X, Star, Store, KeyRound, Edit, Ban, ShieldCheck, Camera } from "lucide-react";


import { useNavigate } from "react-router-dom";
import { api, fileURL } from "../api";
import Topbar from "../components/Topbar";
import { toast, confirmDialog } from "../components/Feedback";

const ROLE_COLORS = { 
  driver: { bg: "rgba(37,99,235,0.1)", text: "#3B82F6", label: "Driver" }, 
  rider: { bg: "rgba(16,185,129,0.1)", text: "#10B981", label: "Penumpang" },
  food_merchant: { bg: "rgba(245,158,11,0.1)", text: "#d97706", label: "Mitra Food" },
  rental_partner: { bg: "rgba(16,185,129,0.1)", text: "#059669", label: "Mitra Rental" },
  admin: { bg: "rgba(139,92,246,0.1)", text: "#8B5CF6", label: "Admin" }
};


export default function UsersPage() {
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState("");
  const [search, setSearch] = useState("");
  const [editUser, setEditUser] = useState(null);
  const [editForm, setEditForm] = useState({ name: "", email: "", role: "rider", balance: 0, rating: 5, password: "" });
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [limit, setLimit] = useState(10);
  const [totalRecords, setTotalRecords] = useState(0);
  // Berapa kali tiap driver melepas pesanan dalam 30 hari (per nomor HP).
  const [lepas, setLepas] = useState({});
  // Alasan suspend tiap driver nonaktif (per nomor HP), dan form menonaktifkan.
  const [alasanNonaktif, setAlasanNonaktif] = useState({});
  const [suspend, setSuspend] = useState(null); // { user, alasan }
  const [fotoWajah, setFotoWajah] = useState({}); // selfie driver per nomor HP
  const [menyimpan, setMenyimpan] = useState(false);
  const navigate = useNavigate();

  const load = (role = filter, p = page, l = limit) => {
    setLoading(true);
    api.getUsers(role, p, l).then(d => {
      setUsers(d.users || []);
      setLepas(d.lepas_30_hari || {});
      setAlasanNonaktif(d.alasan_nonaktif || {});
      setFotoWajah(d.foto_wajah || {});
      if (d.pagination) {
        setPage(d.pagination.page);
        setTotalPages(d.pagination.total_pages);
        setTotalRecords(d.pagination.total);
      }
      setLoading(false); 
    });
  };

  useEffect(() => { load(filter, 1, limit); }, []);

  const handleDelete = async (u) => {
    const ok = await confirmDialog({
      title: "Hapus pengguna?",
      message: `${u.name || u.phone_number} akan dihapus permanen beserta seluruh data terkaitnya.`,
      confirmText: "Hapus pengguna",
    });
    if (!ok) return;
    try {
      const res = await api.deleteUser(u.phone_number);
      if (res.status === "success") {
        toast.success("Pengguna berhasil dihapus");
        load(filter);
      } else {
        toast.error(res.error || "Gagal menghapus pengguna");
      }
    } catch (e) {
      toast.error("Terjadi kesalahan: " + e.message);
    }
  };

  const openEditModal = (u) => {
    setEditUser(u);
    setEditForm({
      name: u.name || "",
      email: u.email || "",
      role: u.role || "rider",
      balance: u.balance || 0,
      rating: u.rating || 5.0,
      password: u.password || ""
    });
  };

  const handleEditSubmit = async (e) => {
    e.preventDefault();
    if (!editUser) return;
    try {
      const res = await api.updateUser(editUser.phone_number, {
        name: editForm.name,
        email: editForm.email,
        role: editForm.role,
        // Saldo hanya dikirim kalau diubah: angkanya diambil saat modal dibuka,
        // dan komisi pesanan yang selesai sementara itu ikut tertimpa.
        ...(Number(editForm.balance) !== (editUser.balance || 0) && { balance: parseFloat(editForm.balance) }),
        rating: parseFloat(editForm.rating),
        password: editForm.password
      });
      if (res.status === "success") {
        toast.success("Data pengguna berhasil diperbarui");
        setEditUser(null);
        load(filter);
      } else {
        toast.error(res.error || "Gagal memperbarui pengguna");
      }
    } catch (err) {
      toast.error("Terjadi kesalahan: " + err.message);
    }
  };

  // Suspend: driver tidak bisa menerima orderan sampai diaktifkan lagi.
  const nonaktifkan = async (e) => {
    e.preventDefault();
    setMenyimpan(true);
    try {
      const res = await api.updateUser(suspend.user.phone_number, { is_driver_active: false, alasan_nonaktif: suspend.alasan });
      if (res.status !== "success") throw new Error(res.error || "Gagal menonaktifkan driver");
      toast.success(`${suspend.user.name || suspend.user.phone_number} dinonaktifkan`);
      setSuspend(null);
      load(filter);
    } catch (err) {
      toast.error(err.message);
    } finally {
      setMenyimpan(false);
    }
  };

  const aktifkan = async (u) => {
    const ok = await confirmDialog({
      title: "Aktifkan kembali driver ini?",
      message: `${u.name || u.phone_number} bisa menerima orderan lagi dan mendapat notifikasi bahwa akunnya aktif.`,
      confirmText: "Aktifkan",
    });
    if (!ok) return;
    try {
      const res = await api.updateUser(u.phone_number, { is_driver_active: true });
      if (res.status !== "success") throw new Error(res.error || "Gagal mengaktifkan driver");
      toast.success(`${u.name || u.phone_number} aktif lagi`);
      load(filter);
    } catch (err) {
      toast.error(err.message);
    }
  };

  // Foto wajah driver terkunci setelah terpasang. Membuka kunci = mengosongkan,
  // lalu driver mengambil selfie baru dari aplikasinya.
  const bukaKunciFoto = async (u) => {
    const ok = await confirmDialog({
      title: "Buka kunci foto wajah?",
      message: `Foto ${u.name || u.phone_number} dihapus dari kartu penjemputan, lalu driver diminta mengambil selfie baru di aplikasinya.`,
      confirmText: "Buka kunci",
    });
    if (!ok) return;
    try {
      const res = await api.updateUser(u.phone_number, { hapus_foto_wajah: true });
      if (res.status !== "success") throw new Error(res.error || "Gagal membuka kunci foto");
      toast.success(`${u.name || u.phone_number} bisa mengambil foto wajah baru`);
      load(filter);
    } catch (err) {
      toast.error(err.message);
    }
  };

  const filtered = users.filter(u =>
    u.name?.toLowerCase().includes(search.toLowerCase()) || 
    u.phone_number?.includes(search) || 
    u.email?.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <>
      <Topbar title="Manajemen Pengguna" />
      <div className="page">
        <div className="page-header">
          <h1>Pengguna</h1>
          <p>Kelola semua pengguna dalam sistem BohAntar</p>
        </div>
        <div className="filter-bar">
          <button className={`filter-btn${filter === "" ? " active" : ""}`} onClick={() => { setFilter(""); setPage(1); load("", 1, limit); }}>Semua</button>
          <button className={`filter-btn${filter === "driver" ? " active" : ""}`} onClick={() => { setFilter("driver"); setPage(1); load("driver", 1, limit); }} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
            <Bike size={14} /> Driver
          </button>
          <button className={`filter-btn${filter === "rider" ? " active" : ""}`} onClick={() => { setFilter("rider"); setPage(1); load("rider", 1, limit); }} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
            <User size={14} /> Penumpang
          </button>
          <button className={`filter-btn${filter === "food_merchant" ? " active" : ""}`} onClick={() => { setFilter("food_merchant"); setPage(1); load("food_merchant", 1, limit); }} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
            <Store size={14} /> Mitra Food
          </button>
          <button className={`filter-btn${filter === "rental_partner" ? " active" : ""}`} onClick={() => { setFilter("rental_partner"); setPage(1); load("rental_partner", 1, limit); }} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
            <KeyRound size={14} /> Mitra Rental
          </button>
          <div style={{ marginLeft: "auto" }}>
            <div className="search-bar">
              <Search size={15} style={{ color: "var(--text-muted)" }} />
              <input placeholder="Cari nama, nomor, email..." value={search} onChange={e => setSearch(e.target.value)} />
            </div>
          </div>
        </div>
        
        {loading ? (
          <div className="loading-overlay"><div className="spinner" /><p>Memuat...</p></div>
        ) : (
          <div className="table-wrap">
            <div className="table-header"><h3>Total: {filtered.length} pengguna</h3></div>
            <table>
              <thead>
                <tr>
                  <th>Pengguna</th>
                  <th>Nomor HP</th>
                  <th>Email</th>
                  <th>Role</th>
                  <th>Saldo</th>
                  <th>Total Order</th>
                  <th>Rating</th>
                  <th>Bergabung</th>
                  <th>Aksi</th>
                </tr>
              </thead>
              <tbody>
                {filtered.length === 0 ? (
                  <tr>
                    <td colSpan={9}>
                      <div className="empty-state">
                        <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                          <User size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                        </div>
                        <h3>Tidak ada pengguna</h3>
                        <p>Belum ada pengguna yang terdaftar</p>
                      </div>
                    </td>
                  </tr>
                ) : filtered.map(u => (
                  <tr key={u.phone_number}>
                    <td data-label="Pengguna">
                      <div className="user-cell">
                        {fotoWajah[u.phone_number] ? (
                          <a href={fileURL(fotoWajah[u.phone_number])} target="_blank" rel="noreferrer" title="Foto wajah yang dilihat penumpang">
                            <img className="user-avatar" src={fileURL(fotoWajah[u.phone_number])} alt="" style={{ objectFit: "cover" }} />
                          </a>
                        ) : (
                          <div className="user-avatar" style={{ background: ROLE_COLORS[u.role]?.bg || "rgba(148,163,184,0.1)", color: ROLE_COLORS[u.role]?.text || "#94A3B8" }}>
                            {u.role === "driver" ? <Bike size={14} /> : u.role === "food_merchant" ? <Store size={14} /> : u.role === "rental_partner" ? <KeyRound size={14} /> : <User size={14} />}
                          </div>
                        )}
                        <div><div className="user-name">{u.name}</div><div className="user-sub">{u.badge}</div></div>
                      </div>
                    </td>
                    <td data-label="Nomor HP">{u.phone_number}</td>
                    <td data-label="Email" style={{ color: "var(--text-secondary)" }}>{u.email}</td>
                    <td data-label="Role">
                      <span className="badge" style={{ background: ROLE_COLORS[u.role]?.bg || "rgba(148,163,184,0.1)", color: ROLE_COLORS[u.role]?.text || "#94A3B8" }}>
                        {ROLE_COLORS[u.role]?.label || u.role}
                      </span>
                      {u.role === "driver" && !u.is_driver_active && (
                        <div style={{ marginTop: 4 }}>
                          <span className="badge badge-danger">Nonaktif</span>
                          {alasanNonaktif[u.phone_number] && (
                            <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 3, maxWidth: 180 }}>{alasanNonaktif[u.phone_number]}</div>
                          )}
                        </div>
                      )}
                    </td>
                    <td data-label="Saldo" style={{ fontWeight: 600, color: "var(--success)" }}>
                      Rp {(u.balance || 0).toLocaleString("id-ID")}
                    </td>
                    <td data-label="Total Order">
                      {u.total_orders || 0}
                      {lepas[u.phone_number] > 0 && (
                        <div style={{ fontSize: 11, color: "#B45309", fontWeight: 600 }} title="Alasannya ada di halaman Pesanan">
                          lepas pesanan {lepas[u.phone_number]}× (30 hari)
                        </div>
                      )}
                    </td>
                    <td data-label="Rating">
                      <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
                        <Star size={12} fill="var(--warning)" stroke="var(--warning)" />
                        <span>{(u.rating || 0).toFixed(1)}</span>
                      </div>
                    </td>
                    <td data-label="Bergabung" style={{ color: "var(--text-muted)" }}>
                      {new Date(u.created_at).toLocaleDateString("id-ID")}
                    </td>
                    <td data-label="Aksi">
                      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                        <button className="btn btn-ghost btn-sm" onClick={() => openEditModal(u)} style={{ color: "var(--primary)" }}>
                          <Edit size={13} /> Edit
                        </button>
                        {u.role === "driver" && (u.is_driver_active ? (
                          <button className="btn btn-ghost btn-sm" onClick={() => setSuspend({ user: u, alasan: "" })} style={{ color: "#DC2626" }}>
                            <Ban size={13} /> Nonaktifkan
                          </button>
                        ) : (
                          <button className="btn btn-ghost btn-sm" onClick={() => aktifkan(u)} style={{ color: "#059669" }}>
                            <ShieldCheck size={13} /> Aktifkan
                          </button>
                        ))}
                        {fotoWajah[u.phone_number] && (
                          <button className="btn btn-ghost btn-sm" onClick={() => bukaKunciFoto(u)} title="Driver bisa mengambil selfie baru">
                            <Camera size={13} /> Buka kunci foto
                          </button>
                        )}
                        <button className="btn btn-danger btn-sm" onClick={() => handleDelete(u)}>
                          <Trash2 size={13} /> Hapus
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="table-pager">
              <div style={{ fontSize: 13, color: "var(--text-muted)", fontWeight: 500 }}>
                Menampilkan {users.length} dari {totalRecords} pengguna
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

      {suspend && (
        <div className="modal-overlay" onClick={() => setSuspend(null)}>
          <form className="modal" onClick={e => e.stopPropagation()} onSubmit={nonaktifkan} style={{ maxWidth: 460, position: "relative" }}>
            <button type="button" onClick={() => setSuspend(null)} style={{ position: "absolute", top: 16, right: 16, background: "none", border: "none", cursor: "pointer", color: "var(--text-muted)" }}>
              <X size={18} />
            </button>
            <h2 style={{ fontSize: 20, fontWeight: 800, color: "var(--text-primary)", marginBottom: 8 }}>Nonaktifkan Driver</h2>
            <p style={{ fontSize: 13, color: "var(--text-secondary)", marginBottom: 14 }}>
              <strong>{suspend.user.name || suspend.user.phone_number}</strong> · {suspend.user.phone_number}<br />
              Driver tidak bisa menerima orderan sampai diaktifkan lagi. Pesanan yang sedang berjalan tetap bisa diselesaikan.
              Driver mendapat notifikasi beserta alasannya.
            </p>
            <div className="input-group">
              <label>Alasan</label>
              <textarea className="input" rows={3} maxLength={255} required autoFocus
                placeholder="Contoh: Menagih ongkos di atas tarif aplikasi"
                value={suspend.alasan} onChange={e => setSuspend({ ...suspend, alasan: e.target.value })}
                style={{ resize: "vertical" }} />
            </div>
            <div className="modal-footer" style={{ marginTop: 16, gap: 10 }}>
              <button type="button" className="btn btn-ghost" onClick={() => setSuspend(null)}>Batal</button>
              <button type="submit" className="btn btn-danger" disabled={menyimpan || !suspend.alasan.trim()}>
                {menyimpan ? "Menyimpan…" : "Nonaktifkan"}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Modern Custom Edit User Modal */}
      {editUser && (
        <div className="modal-overlay" onClick={() => setEditUser(null)}>
          <div className="modal" onClick={e => e.stopPropagation()} style={{ maxWidth: 500, position: "relative" }}>
            <button onClick={() => setEditUser(null)} style={{ position: "absolute", top: 16, right: 16, background: "none", border: "none", cursor: "pointer", color: "var(--text-muted)" }}>
              <X size={18} />
            </button>
            <h2 style={{ fontSize: 20, fontWeight: 800, color: "var(--text-primary)", marginBottom: 16 }}>Edit Pengguna</h2>
            <form onSubmit={handleEditSubmit}>
              <div className="input-group">
                <label>Nama Lengkap</label>
                <input className="input" value={editForm.name} onChange={e => setEditForm({ ...editForm, name: e.target.value })} required />
              </div>
              
              <div className="grid-2">
                <div className="input-group">
                  <label>Alamat Email</label>
                  <input className="input" type="email" value={editForm.email} onChange={e => setEditForm({ ...editForm, email: e.target.value })} required />
                </div>
                <div className="input-group">
                  <label>Password Akun</label>
                  <input className="input" type="text" placeholder="Masukkan password baru..." value={editForm.password} onChange={e => setEditForm({ ...editForm, password: e.target.value })} />
                </div>
              </div>

              <div className="grid-3">
                <div className="input-group">
                  <label>Peran (Role)</label>
                  <select className="input" value={editForm.role} onChange={e => setEditForm({ ...editForm, role: e.target.value })}>
                    <option value="rider">Penumpang (Rider)</option>
                    <option value="driver">Driver</option>
                    <option value="food_merchant">Mitra Resto Food</option>
                    <option value="rental_partner">Mitra Rental Mobil</option>
                    <option value="admin">Super Admin</option>
                  </select>
                </div>
                <div className="input-group">
                  <label>Saldo (Rp)</label>
                  <input className="input" type="number" value={editForm.balance} onChange={e => setEditForm({ ...editForm, balance: e.target.value })} required />
                </div>
                <div className="input-group">
                  <label>Rating</label>
                  <input className="input" type="number" step="0.01" min="0" max="5" value={editForm.rating} onChange={e => setEditForm({ ...editForm, rating: e.target.value })} required />
                </div>
              </div>

              <div className="modal-footer" style={{ marginTop: 24, gap: 10 }}>
                <button type="button" className="btn btn-ghost" onClick={() => setEditUser(null)}>Batal</button>
                <button type="submit" className="btn btn-primary" style={{ background: "var(--primary)" }}>Simpan Perubahan</button>
              </div>
            </form>
          </div>
        </div>
      )}

    </>
  );
}
