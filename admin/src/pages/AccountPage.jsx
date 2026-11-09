import { useState, useEffect } from "react";
import { Link } from "react-router-dom";
import { CreditCard, ChevronRight } from "lucide-react";
import { api, fileURL } from "../api";
import { toast } from "../components/Feedback";
import { invalidateRentalName } from "./bohrental/invoice";

/* Halaman akun dipakai bersama portal bohFood dan bohRental.
   Identitas diambil dari token, jadi tidak perlu tahu portal mana yang memanggil. */

export default function AccountPage() {
  // App.jsx menyimpan portal_type di localStorage dan membacanya dari sana juga,
  // jadi tidak perlu prop baru cuma untuk satu kartu khusus rental.
  const isRental = localStorage.getItem("portal_type") === "rental";
  const [user, setUser] = useState(null);
  const [form, setForm] = useState({ name: "", email: "", business_name: "", business_address: "", business_logo: "", rek_nama: "", rek_bank: "", rek_nomor: "" });
  const [pass, setPass] = useState({ current_password: "", new_password: "", confirm: "" });
  const [saving, setSaving] = useState("");
  const [mengunggah, setMengunggah] = useState(false);

  useEffect(() => {
    api.getProfile().then(res => {
      if (res.user) {
        setUser(res.user);
        setForm({
          name: res.user.name || "",
          email: res.user.email || "",
          business_name: res.business_name || "",
          business_address: res.business_address || "",
          business_logo: res.business_logo || "",
          rek_nama: res.rek_nama || "",
          rek_bank: res.rek_bank || "",
          rek_nomor: res.rek_nomor || "",
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
        ...(isRental ? {
          business_name: form.business_name,
          business_address: form.business_address,
          business_logo: form.business_logo,
          rek_nama: form.rek_nama,
          rek_bank: form.rek_bank,
          rek_nomor: form.rek_nomor,
        } : {}),
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
          {isRental && (
            <div className="input-group">
              <label>Alamat Rental</label>
              <textarea
                className="input"
                rows={2}
                maxLength={255}
                placeholder="Contoh: Jl. MT Haryono No. 12, Sintang"
                value={form.business_address}
                onChange={e => setForm({ ...form, business_address: e.target.value })}
                style={{ resize: "vertical" }}
              />
              <small style={{ display: "block", fontSize: 11, color: "var(--text-muted)", marginTop: 6 }}>
                Tampil di kanan atas invoice bersama nomor HP akun ini.
              </small>
            </div>
          )}
          {isRental && (
            <div className="input-group">
              <label>Logo Rental</label>
              {form.business_logo && (
                <img
                  src={fileURL(form.business_logo)}
                  alt="Logo rental"
                  style={{ maxWidth: 120, maxHeight: 80, objectFit: "contain", display: "block", marginBottom: 8, borderRadius: 8, background: "#fff", padding: 4, border: "1px solid var(--border)" }}
                />
              )}
              <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                <label className="btn btn-sm" style={{ cursor: mengunggah ? "wait" : "pointer", display: "inline-flex" }}>
                  {mengunggah ? "Mengunggah..." : form.business_logo ? "Ganti logo" : "Unggah logo"}
                  <input
                    type="file" accept="image/png,image/jpeg,image/webp" hidden disabled={mengunggah}
                    onChange={e => {
                      const berkas = e.target.files?.[0];
                      e.target.value = "";
                      if (!berkas) return;
                      setMengunggah(true);
                      api.uploadFile(berkas)
                        .then(res => {
                          if (!res.url) throw new Error(res.error || "Gagal mengunggah logo");
                          setForm(f => ({ ...f, business_logo: res.url }));
                        })
                        .catch(err => toast.error(err.message || "Gagal mengunggah logo"))
                        .finally(() => setMengunggah(false));
                    }}
                  />
                </label>
                {form.business_logo && (
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setForm({ ...form, business_logo: "" })}>
                    Hapus logo
                  </button>
                )}
              </div>
              <small style={{ display: "block", fontSize: 11, color: "var(--text-muted)", marginTop: 6 }}>
                Tampil di kiri atas invoice. Tekan Simpan Profil setelah mengunggah.
              </small>
            </div>
          )}
          {isRental && (
            <div className="input-group">
              <label>Rekening Pembayaran</label>
              <div style={{ display: "grid", gap: 8 }}>
                <input className="input" maxLength={100} placeholder="Nama pemilik rekening" value={form.rek_nama}
                  onChange={e => setForm({ ...form, rek_nama: e.target.value })} />
                <div style={{ display: "grid", gap: 8, gridTemplateColumns: "minmax(0, 2fr) minmax(0, 3fr)" }}>
                  <input className="input" maxLength={50} placeholder="Bank (mis. BRI)" value={form.rek_bank}
                    onChange={e => setForm({ ...form, rek_bank: e.target.value })} />
                  <input className="input" maxLength={30} inputMode="numeric" pattern="[0-9 \-]*" title="Hanya angka" placeholder="No. rekening" value={form.rek_nomor}
                    onChange={e => setForm({ ...form, rek_nomor: e.target.value })} />
                </div>
              </div>
              <small style={{ display: "block", fontSize: 11, color: "var(--text-muted)", marginTop: 6 }}>
                Dicetak di bagian "Pembayaran" pada invoice. Kosongkan kalau tidak ingin ditampilkan.
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
