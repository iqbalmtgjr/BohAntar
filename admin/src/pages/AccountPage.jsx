import { useState, useEffect } from "react";
import { Link } from "react-router-dom";
import { CreditCard, ChevronRight } from "lucide-react";
import { api } from "../api";
import { toast } from "../components/Feedback";
import { invalidateRentalName } from "./bohrental/invoice";

/* Halaman akun dipakai bersama portal bohFood dan bohRental.
   Identitas diambil dari token, jadi tidak perlu tahu portal mana yang memanggil. */

export default function AccountPage() {
  // App.jsx menyimpan portal_type di localStorage dan membacanya dari sana juga,
  // jadi tidak perlu prop baru cuma untuk satu kartu khusus rental.
  const isRental = localStorage.getItem("portal_type") === "rental";
  const [user, setUser] = useState(null);
  const [form, setForm] = useState({ name: "", email: "", business_name: "" });
  const [pass, setPass] = useState({ current_password: "", new_password: "", confirm: "" });
  const [saving, setSaving] = useState("");

  useEffect(() => {
    api.getProfile().then(res => {
      if (res.user) {
        setUser(res.user);
        setForm({
          name: res.user.name || "",
          email: res.user.email || "",
          business_name: res.business_name || "",
        });
      }
    });
  }, []);

  const saveProfile = async (e) => {
    e.preventDefault();
    setSaving("profile");
    try {
      const res = await api.updateProfile({
        name: form.name,
        email: form.email,
        ...(isRental ? { business_name: form.business_name } : {}),
      });
      if (res.status === "success") {
        setUser(res.user);
        // Kop invoice di-cache per sesi; buang cache-nya supaya nama baru langsung dipakai.
        invalidateRentalName();
        toast.success("Profil berhasil disimpan");
      } else {
        toast.error(res.error || "Gagal menyimpan profil");
      }
    } catch {
      toast.error("Terjadi kesalahan sistem");
    } finally {
      setSaving("");
    }
  };

  const savePassword = async (e) => {
    e.preventDefault();
    if (pass.new_password !== pass.confirm) {
      toast.error("Konfirmasi password tidak cocok");
      return;
    }
    setSaving("password");
    try {
      const res = await api.updateProfile({
        current_password: pass.current_password,
        new_password: pass.new_password,
      });
      if (res.status === "success") {
        setPass({ current_password: "", new_password: "", confirm: "" });
        toast.success("Password berhasil diganti");
      } else {
        toast.error(res.error || "Gagal mengganti password");
      }
    } catch {
      toast.error("Terjadi kesalahan sistem");
    } finally {
      setSaving("");
    }
  };

  if (!user) return <div className="page"><span className="spinner" /></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Akun Saya</h1>
        <p>Ubah data profil dan password login mitra.</p>
      </div>

      <div style={{ display: "grid", gap: 20, gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))" }}>
        <form className="card" onSubmit={saveProfile}>
          <div className="card-title">Data Profil</div>

          <div className="input-group">
            <label>Nomor HP</label>
            {/* Nomor HP adalah kunci akun di backend, jadi tidak bisa diubah sendiri. */}
            <input className="input" value={user.phone_number} disabled />
          </div>
          <div className="input-group">
            <label>Nama</label>
            <input className="input" value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} required />
          </div>
          {isRental && (
            <div className="input-group">
              <label>Nama Rental / Usaha</label>
              <input
                className="input"
                value={form.business_name}
                maxLength={100}
                placeholder="Contoh: Sentosa Rent Car"
                onChange={e => setForm({ ...form, business_name: e.target.value })}
              />
              <small style={{ display: "block", fontSize: 11, color: "var(--text-muted)", marginTop: 6 }}>
                Dipakai sebagai kop pada invoice yang dikirim ke penyewa.
              </small>
            </div>
          )}
          <div className="input-group">
            <label>Email (dipakai untuk login)</label>
            <input className="input" type="email" value={form.email} onChange={e => setForm({ ...form, email: e.target.value })} required />
          </div>

          <button className="btn btn-primary" disabled={saving === "profile"}>
            {saving === "profile" ? <span className="spinner" /> : "Simpan Profil"}
          </button>
        </form>

        <form className="card" onSubmit={savePassword}>
          <div className="card-title">Ganti Password</div>

          <div className="input-group">
            <label>Password Saat Ini</label>
            <input className="input" type="password" value={pass.current_password} onChange={e => setPass({ ...pass, current_password: e.target.value })} required />
          </div>
          <div className="input-group">
            <label>Password Baru (minimal 8 karakter)</label>
            <input className="input" type="password" minLength={8} value={pass.new_password} onChange={e => setPass({ ...pass, new_password: e.target.value })} required />
          </div>
          <div className="input-group">
            <label>Ulangi Password Baru</label>
            <input className="input" type="password" minLength={8} value={pass.confirm} onChange={e => setPass({ ...pass, confirm: e.target.value })} required />
          </div>

          <button className="btn btn-primary" disabled={saving === "password"}>
            {saving === "password" ? <span className="spinner" /> : "Ganti Password"}
          </button>
        </form>

        {isRental && (
          <Link to="/subscription" className="card" style={{ display: "flex", alignItems: "center", gap: 14, textDecoration: "none" }}>
            <CreditCard size={22} style={{ color: "var(--primary)", flexShrink: 0 }} />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 700, color: "var(--text-primary)" }}>Langganan &amp; Billing</div>
              <div style={{ fontSize: 12, color: "var(--text-secondary)", marginTop: 2 }}>Lihat status lisensi dan riwayat pembayaran.</div>
            </div>
            <ChevronRight size={18} style={{ color: "var(--text-muted)", flexShrink: 0 }} />
          </Link>
        )}
      </div>
    </div>
  );
}
