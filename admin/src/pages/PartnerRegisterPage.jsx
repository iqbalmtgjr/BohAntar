import React, { useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { ArrowLeft, ArrowRight, CheckCircle, User, Building2 } from "lucide-react";
import { api } from "../api";
import { Alert } from "../components/Feedback";
import { motion } from "motion/react";
import logoImg from "../assets/logo.png";

export default function PartnerRegisterPage() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const type = searchParams.get("type") === "food" ? "food" : "rental";

  const [form, setForm] = useState({
    name: "",
    phone_number: "",
    email: "",
    ktp_number: "",
    business_name: "",
    address: "",
    notes: "",
  });

  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(false);
  const [error, setError] = useState("");

  const set = (key, value) => {
    setForm((f) => ({ ...f, [key]: value }));
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setError("");
    try {
      let phone = form.phone_number.trim();
      if (phone.startsWith("0")) {
        phone = "+62" + phone.substring(1);
      } else if (phone.startsWith("62")) {
        phone = "+" + phone;
      } else if (!phone.startsWith("+62")) {
        phone = "+62" + phone;
      }

      const res = await api.registerPartner({
        type,
        name: form.name,
        phone_number: phone,
        email: form.email,
        ktp_number: form.ktp_number,
        business_name: form.business_name,
        address: form.address,
        notes: form.notes,
      });

      if (res.status === "success") {
        setSuccess(true);
        setForm({
          name: "",
          phone_number: "",
          email: "",
          ktp_number: "",
          business_name: "",
          address: "",
          notes: "",
        });
      } else {
        setError(res.error || "Gagal mengirim pendaftaran");
      }
    } catch (err) {
      console.error(err);
      setError("Terjadi kesalahan koneksi ke server.");
    } finally {
      setLoading(false);
    }
  };

  const getPortalTitle = () => {
    return type === "food" ? "Mitra Resto Food" : "Mitra Rental Mobil";
  };

  const getPortalColor = () => {
    return type === "food" ? "from-amber-500 to-orange-600" : "from-emerald-500 to-teal-600";
  };

  return (
    <div className="min-h-screen bg-[#f8fafc] text-slate-900 font-sans antialiased relative overflow-hidden flex flex-col justify-between">
      {/* Ambient Background Grid & Orbs */}
      <div className="absolute inset-0 pointer-events-none z-0">
        <div className={`absolute top-[-10%] right-[10%] w-[500px] h-[500px] ${type === "food" ? "bg-amber-100/40" : "bg-emerald-100/40"} rounded-full blur-[100px]`} />
        <div className="absolute bottom-[-10%] left-[10%] w-[500px] h-[500px] bg-blue-100/40 rounded-full blur-[100px]" />
        <div className="absolute inset-0 opacity-[0.02]" style={{
          backgroundImage: 'radial-gradient(circle, #3b82f6 1px, transparent 1px)',
          backgroundSize: '24px 24px'
        }} />
      </div>

      {/* Header */}
      <header className="relative z-10 max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-20 w-full flex items-center justify-between">
        <div onClick={() => navigate("/")} className="flex items-center gap-3 cursor-pointer select-none">
          <img
            src={logoImg}
            alt="bohAntar Logo"
            className="h-10 w-auto object-contain"
          />
        </div>

        <button
          onClick={() => navigate("/portal-mitra")}
          className="flex items-center gap-2 px-4 py-2 text-sm font-semibold text-slate-600 hover:text-blue-600 transition-colors rounded-xl hover:bg-slate-50 border border-slate-200/60 bg-white shadow-sm"
        >
          <ArrowLeft className="w-4 h-4" />
          <span>Batal</span>
        </button>
      </header>

      {/* Main Content */}
      <main className="flex-1 relative z-10 max-w-4xl w-full mx-auto px-4 py-12 flex flex-col justify-center">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="bg-white border border-slate-200/80 rounded-3xl p-8 md:p-12 shadow-xl shadow-slate-200/50"
        >
          {success ? (
            <div className="text-center space-y-6 py-12 max-w-md mx-auto">
              <div className="w-20 h-20 rounded-full bg-emerald-50 border border-emerald-100 flex items-center justify-center text-emerald-500 mx-auto shadow-md">
                <CheckCircle className="w-10 h-10" />
              </div>
              <div className="space-y-2">
                <h2 className="text-2xl font-black text-slate-900 leading-none">Pendaftaran Berhasil Dikirim!</h2>
                <p className="text-sm text-slate-500 leading-relaxed">
                  Terima kasih telah mengajukan pendaftaran sebagai {getPortalTitle()}. Permohonan Anda saat ini dalam proses peninjauan oleh tim Super Admin bohAntar.
                </p>
              </div>
              <div className="bg-slate-50 border border-slate-200/60 p-4 rounded-2xl text-xs text-slate-500 leading-relaxed text-left">
                <strong>Catatan Penting:</strong>
                <ul className="list-disc pl-4 mt-2 space-y-1">
                  <li>Proses peninjauan biasanya memakan waktu 1-3 hari kerja.</li>
                  <li>Jika pendaftaran disetujui, Anda akan otomatis terdaftar dan dapat masuk menggunakan akun Google yang didaftarkan.</li>
                  <li>Tim kami juga akan menghubungi Anda via WhatsApp/Telepon untuk konfirmasi kelengkapan berkas fisik.</li>
                </ul>
              </div>
              <button
                onClick={() => navigate("/portal-mitra")}
                className="w-full py-3.5 bg-slate-900 hover:bg-slate-800 text-white font-bold text-sm rounded-xl transition shadow-md cursor-pointer"
              >
                Kembali ke Portal Kemitraan
              </button>
            </div>
          ) : (
            <div className="space-y-8">
              {/* Header Title */}
              <div className="text-center md:text-left space-y-2 pb-6 border-b border-slate-100">
                <span className={`inline-flex items-center px-3 py-0.5 rounded-full bg-blue-50 border border-blue-100 text-blue-600 text-[10px] font-bold uppercase tracking-wider`}>
                  Registrasi Online
                </span>
                <h2 className="text-3xl font-black text-slate-900 leading-tight">
                  Gabung Sebagai {getPortalTitle()}
                </h2>
                <p className="text-sm text-slate-500">
                  Lengkapi formulir di bawah ini untuk mengirimkan pengajuan kemitraan baru Anda.
                </p>
              </div>

              <Alert type="error" style={{ marginBottom: 0 }}>{error}</Alert>

              {/* Form Input fields */}
              <form onSubmit={handleSubmit} className="space-y-6">
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  {/* Owner Info Group */}
                  <div className="space-y-4">
                    <h3 className="text-sm font-bold text-slate-800 uppercase tracking-wider flex items-center gap-2">
                      <User className="w-4 h-4 text-blue-600" />
                      <span>Data Pemilik (Owner)</span>
                    </h3>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">Nama Pemilik / Penanggung Jawab</label>
                      <input
                        type="text"
                        required
                        value={form.name}
                        onChange={(e) => set("name", e.target.value)}
                        placeholder="Nama Lengkap Pemilik"
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium"
                      />
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">Nomor HP (WhatsApp Aktif)</label>
                      <input
                        type="tel"
                        required
                        value={form.phone_number}
                        onChange={(e) => set("phone_number", e.target.value)}
                        placeholder="Contoh: 081234567890"
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium"
                      />
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">Email Aktif</label>
                      <input
                        type="email"
                        required
                        value={form.email}
                        onChange={(e) => set("email", e.target.value)}
                        placeholder="email@bisnis.com"
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium"
                      />
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">Nomor KTP Pemilik</label>
                      <input
                        type="text"
                        required
                        value={form.ktp_number}
                        onChange={(e) => set("ktp_number", e.target.value)}
                        placeholder="3201xxxxxxxxxxxx"
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium"
                      />
                    </div>
                  </div>

                  {/* Business Info Group */}
                  <div className="space-y-4">
                    <h3 className="text-sm font-bold text-slate-800 uppercase tracking-wider flex items-center gap-2">
                      <Building2 className="w-4 h-4 text-blue-600" />
                      <span>Data Restoran / Perusahaan Rental</span>
                    </h3>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">
                        {type === "food" ? "Nama Restoran" : "Nama Rental Mobil"}
                      </label>
                      <input
                        type="text"
                        required
                        value={form.business_name}
                        onChange={(e) => set("business_name", e.target.value)}
                        placeholder={type === "food" ? "Contoh: Warung Bakso Maknyus" : "Contoh: Sentosa Jaya Rent Car"}
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium"
                      />
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">
                        {type === "food" ? "Alamat Lengkap Restoran" : "Alamat Lengkap Kantor Rental"}
                      </label>
                      <textarea
                        required
                        rows={3}
                        value={form.address}
                        onChange={(e) => set("address", e.target.value)}
                        placeholder="Jalan, RT/RW, Kelurahan, Kecamatan, Kota/Kabupaten"
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium resize-none"
                      />
                    </div>

                    <div>
                      <label className="block text-xs font-bold text-slate-500 mb-1.5 uppercase">Catatan Tambahan (Opsional)</label>
                      <textarea
                        rows={2}
                        value={form.notes}
                        onChange={(e) => set("notes", e.target.value)}
                        placeholder="Sebutkan kapasitas armada kendaraan (rental) / jenis spesialisasi kuliner (resto) Anda."
                        className="w-full px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus:border-blue-500 focus:bg-white focus:outline-none transition text-sm placeholder-slate-400 font-medium resize-none"
                      />
                    </div>
                  </div>
                </div>

                <div className="pt-6 border-t border-slate-100 flex flex-col md:flex-row gap-4 items-center justify-between">
                  <p className="text-xs text-slate-400 text-center md:text-left leading-relaxed">
                    Dengan menekan tombol kirim pendaftaran, Anda menyatakan bahwa seluruh data yang dimasukkan adalah sah dan menyetujui ketentuan kemitraan kami.
                  </p>
                  <button
                    type="submit"
                    disabled={loading}
                    className={`w-full md:w-auto px-8 py-3.5 bg-gradient-to-r ${getPortalColor()} text-white font-bold text-sm rounded-xl shadow-lg transition-all hover:brightness-105 flex items-center justify-center gap-2 cursor-pointer whitespace-nowrap`}
                  >
                    {loading ? (
                      <span className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin" />
                    ) : (
                      <>
                        <span>Kirim Pendaftaran</span>
                        <ArrowRight className="w-4 h-4" />
                      </>
                    )}
                  </button>
                </div>
              </form>
            </div>
          )}
        </motion.div>
      </main>

      {/* Footer */}
      <footer className="py-8 text-center text-xs text-slate-400 border-t border-slate-200/30 relative z-10">
        &copy; {new Date().getFullYear()} bohAntar. Semua hak cipta dilindungi.
      </footer>
    </div>
  );
}
