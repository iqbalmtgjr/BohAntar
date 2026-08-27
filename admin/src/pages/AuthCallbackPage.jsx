import React, { useEffect, useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { api } from '../api';
import { Alert } from '../components/Feedback';

export default function AuthCallbackPage({ onLogin }) {
  const navigate = useNavigate();
  const location = useLocation();
  // LoginPage (alur Google Identity Services) mengirim datanya lewat router state,
  // jadi halaman ini tidak perlu membaca fragment URL sama sekali.
  const handoff = location.state;
  const [status, setStatus] = useState('Memproses autentikasi Google...');
  const [error, setError] = useState('');
  
  // State untuk form registrasi (jika email belum terdaftar)
  const [needPhone, setNeedPhone] = useState(false);
  const [phoneInput, setPhoneInput] = useState('');
  const [loginRole, setLoginRole] = useState('');
  const [registering, setRegistering] = useState(false);
  const [idToken, setIdToken] = useState('');
  const [nonce, setNonce] = useState('');

  // Halaman ini kini hanya dicapai dari tombol Google di halaman login, lewat
  // router state. Alur redirect lama (response_type=id_token) sudah dihapus
  // bersama pindahnya ke Google Identity Services.
  useEffect(() => {
    if (handoff?.idToken) {
      setIdToken(handoff.idToken);
      setNonce(handoff.nonce || '');
      setLoginRole(handoff.role || 'rental');
      setNeedPhone(true);
      setStatus('Lengkapi nomor handphone Anda untuk menyelesaikan pendaftaran.');
      return;
    }
    // Dibuka langsung tanpa konteks — kembalikan ke halaman awal.
    navigate('/', { replace: true });
  }, [handoff, navigate]);

  const handleRegister = async (e) => {
    e.preventDefault();
    if (!phoneInput) return;
    setRegistering(true);
    setError('');
    try {
      const backendRole = loginRole === "food" ? "food_merchant" : "rental_partner";
      
      let formattedPhone = phoneInput.trim();
      if (formattedPhone.startsWith('0')) {
        formattedPhone = '+62' + formattedPhone.substring(1);
      }
      if (!formattedPhone.startsWith('+62')) {
        formattedPhone = '+62' + formattedPhone;
      }

      setStatus('Mendaftarkan akun baru...');

      // id_token yang sama dikirim ulang bersama nomor HP untuk diverifikasi lagi.
      const data = await api.googleLogin(idToken, nonce, {
        phone_number: formattedPhone,
        role: backendRole,
      });
      if (data.error) {
        throw new Error(data.error);
      }
      if (data.status !== 'success' || !data.user || !data.token) {
        throw new Error('Respon server backend tidak valid setelah pendaftaran.');
      }

      const user = data.user;
      setStatus('Akun berhasil dibuat! Mengalihkan ke dashboard...');
      setNeedPhone(false);
      
      if (onLogin) {
        onLogin(loginRole, user.phone_number, data.token);
      }
      
      setTimeout(() => {
        navigate('/');
      }, 1000);

    } catch (err) {
      console.error(err);
      setError(err.message || 'Terjadi kesalahan saat mendaftarkan akun.');
    } finally {
      setRegistering(false);
    }
  };

  const handleBackToLogin = () => {
    navigate('/');
  };

  return (
    <div className="min-h-screen bg-[#f8fafc] text-slate-900 font-sans flex flex-col items-center justify-center p-6">
      <div className="max-w-md w-full bg-white border border-slate-200 rounded-3xl p-8 shadow-xl text-center space-y-6">
        
        {/* Form Input Nomor HP jika Email Belum Terdaftar */}
        {needPhone ? (
          <form onSubmit={handleRegister} className="space-y-6">
            <div className="text-center space-y-2">
              <span className="inline-flex items-center px-3 py-0.5 rounded-full bg-blue-50 border border-blue-100 text-blue-600 text-[10px] font-bold uppercase tracking-wider">
                Lengkapi Pendaftaran
              </span>
              <h2 className="text-2xl font-black text-slate-900 leading-none">
                Lengkapi Nomor HP
              </h2>
              <p className="text-xs text-slate-400">
                Email Google Anda belum terdaftar. Silakan masukkan nomor handphone Anda untuk menyelesaikan pendaftaran sebagai <strong>{loginRole === "food" ? "Mitra Resto Food" : "Mitra Rental Mobil"}</strong>.
              </p>
            </div>

            <div className="text-left">
              <label className="block text-xs font-bold text-slate-600 mb-1.5 uppercase tracking-wide">Nomor Handphone</label>
              <div className="flex items-center px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus-within:border-blue-500 focus-within:bg-white transition">
                <span className="text-sm font-bold text-slate-400 mr-2 border-r border-slate-200 pr-2">+62</span>
                <input
                  type="tel"
                  required
                  pattern="[0-9]*"
                  value={phoneInput}
                  onChange={(e) => setPhoneInput(e.target.value)}
                  placeholder="812 3456 7890"
                  className="w-full bg-transparent text-sm text-slate-900 font-bold focus:outline-none placeholder-slate-400"
                />
              </div>
            </div>

            <Alert type="error" style={{ marginBottom: 0 }}>{error}</Alert>

            <div className="flex gap-4">
              <button
                type="button"
                onClick={handleBackToLogin}
                className="w-1/2 py-3.5 bg-slate-100 hover:bg-slate-200 text-slate-700 font-bold text-sm rounded-xl transition cursor-pointer"
              >
                Batal
              </button>
              <button
                type="submit"
                disabled={registering}
                className="w-1/2 py-3.5 bg-gradient-to-r from-blue-600 to-blue-700 hover:brightness-105 font-bold text-sm text-white rounded-xl shadow-lg shadow-blue-600/25 transition cursor-pointer"
              >
                {registering ? 'Mendaftarkan...' : 'Simpan & Daftar'}
              </button>
            </div>
          </form>
        ) : (
          /* Tampilan Loading Awal */
          <>
            <div className="flex justify-center">
              <div className="w-16 h-16 rounded-2xl bg-blue-50 flex items-center justify-center text-blue-600 shadow-md">
                {error ? (
                  <svg className="w-8 h-8 text-red-500" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                  </svg>
                ) : (
                  <svg className="w-8 h-8 animate-spin text-blue-600" fill="none" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                  </svg>
                )}
              </div>
            </div>

            <div className="space-y-2">
              <h2 className="text-xl font-black text-slate-900">
                {error ? 'Login Gagal' : 'Autentikasi Google'}
              </h2>
              <p className="text-sm text-slate-500">
                {error ? error : status}
              </p>
            </div>

            {error && (
              <button
                onClick={handleBackToLogin}
                className="w-full py-3 bg-slate-900 hover:bg-slate-800 text-white font-bold text-sm rounded-xl transition cursor-pointer"
              >
                Kembali ke Login
              </button>
            )}
          </>
        )}
      </div>
    </div>
  );
}
