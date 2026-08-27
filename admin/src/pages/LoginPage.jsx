import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { Lock, Mail, ArrowRight, ArrowLeft, Bike, Eye, EyeOff } from 'lucide-react';

import { motion } from 'motion/react';
import { api } from '../api';
import { Alert } from '../components/Feedback';
import logoImg from '../assets/logo.png';


// Google Identity Services itu singleton per halaman: initialize() kedua memicu
// peringatan "called multiple times" dan menimpa konfigurasi yang pertama.
// Pemicunya dua: StrictMode me-mount komponen dua kali di mode dev, dan tiga
// rute login (/login-resto, /login-rental, /super-admin-login) memakai komponen
// yang sama sehingga berpindah portal = mount ulang. Nonce dan handler ikut
// dinaikkan ke level modul supaya token yang terbit tetap cocok dengan nonce
// yang dipakai initialize, dan callback-nya selalu mengarah ke LoginPage yang
// sedang aktif (bukan instance lama yang sudah di-unmount).
let gisInitialized = false;
let gisNonce = '';
let gisHandler = null;

export default function LoginPage({ onLogin, role }) {
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');


  const handleFormSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setError('');
    try {
      const res = await api.login(email, password);
      if (res.status === 'success') {
        const expectedRole = role === 'food' ? 'food_merchant' : role === 'rental' ? 'rental_partner' : 'admin';
        if (res.role !== expectedRole) {
          setError(`Akun Anda terdaftar sebagai ${res.role === 'food_merchant' ? 'Mitra Resto Food' : res.role === 'rental_partner' ? 'Mitra Rental' : res.role}, tidak cocok dengan portal ini.`);
          return;
        }
        if (!res.token) {
          setError('Server tidak mengembalikan token sesi. Hubungi administrator.');
          return;
        }
        if (onLogin) {
          await onLogin(role, res.phone, res.token);
        }
      } else {
        setError(res.error || 'Login gagal. Periksa kembali email dan password Anda.');
      }
    } catch (err) {
      console.error(err);
      setError('Login gagal. Periksa kembali email dan password Anda.');
    } finally {
      setLoading(false);
    }
  };


  const getRoleTitle = () => {
    if (role === 'food') return 'Mitra Resto Food';
    if (role === 'rental') return 'Mitra Rental Mobil';
    return 'Super Admin';
  };

  const getRoleBadge = () => {
    if (role === 'food') return 'bohFood Portal';
    if (role === 'rental') return 'bohRental Portal';
    return 'Super Admin Access';
  };

  const handleBackClick = () => {
    if (role === 'admin') {
      navigate('/');
    } else {
      navigate('/portal-mitra');
    }
  };

  // Google Identity Services: tombol resmi Google yang mengembalikan ID token
  // lewat callback, tanpa redirect sama sekali. Ini menggantikan implicit flow
  // (response_type=id_token) yang sudah lama tidak dianjurkan Google.
  const googleBtnRef = useRef(null);
  const nonceRef = useRef('');
  const [googleReady, setGoogleReady] = useState(false);

  // Meneruskan hasil verifikasi backend ke portal yang sesuai.
  const applyGoogleResult = useCallback(async (data, idToken) => {
    if (data.error) throw new Error(data.error);

    if (data.status === 'need_phone') {
      // Nomor HP belum ada — lanjutkan di halaman pelengkapan pendaftaran.
      if (role === 'admin') {
        throw new Error('Akun Super Admin tidak terdaftar. Hubungi Administrator sistem.');
      }
      navigate('/auth/callback', {
        state: {
          idToken,
          nonce: nonceRef.current,
          email: data.email || '',
          name: data.name || '',
          role,
        },
      });
      return;
    }

    if (data.status !== 'success' || !data.user || !data.token) {
      throw new Error('Respon server backend tidak valid.');
    }

    const expectedRole = role === 'food' ? 'food_merchant' : role === 'rental' ? 'rental_partner' : 'admin';
    if (data.user.role !== expectedRole) {
      throw new Error(`Akun ini terdaftar sebagai ${data.user.role}, tidak cocok dengan portal ini.`);
    }
    if (onLogin) {
      await onLogin(role, data.user.phone_number, data.token);
    }
  }, [navigate, onLogin, role]);

  const handleCredential = useCallback(async (response) => {
    setError('');
    setLoading(true);
    try {
      const idToken = response?.credential;
      if (!idToken) throw new Error('Google tidak mengembalikan kredensial.');
      const data = await api.googleLogin(idToken, nonceRef.current);
      await applyGoogleResult(data, idToken);
    } catch (err) {
      console.error(err);
      setError(err.message || 'Gagal masuk dengan Google.');
    } finally {
      setLoading(false);
    }
  }, [applyGoogleResult]);

  // Callback GIS dipasang sekali di level modul, jadi ia harus selalu menunjuk
  // ke instance LoginPage yang sedang tampil -- bukan yang sudah di-unmount.
  gisHandler = handleCredential;

  useEffect(() => {
    const clientId = import.meta.env.VITE_GOOGLE_CLIENT_ID;
    if (!clientId) {
      setError('Login Google belum dikonfigurasi. Set VITE_GOOGLE_CLIENT_ID di admin/.env.');
      return;
    }

    // Nonce mengikat token ke satu percobaan login; backend yang mencocokkannya
    // dengan klaim di dalam token, jadi tidak bisa dilewati lewat browser.
    // Dibuat sekali saja — kalau berganti setelah Google menerbitkan token,
    // backend akan menolaknya karena tidak cocok dengan klaim di dalam token.
    if (!gisNonce) {
      gisNonce = crypto.randomUUID();
    }
    nonceRef.current = gisNonce;

    const render = () => {
      if (!window.google?.accounts?.id || !googleBtnRef.current) return;
      if (!gisInitialized) {
        window.google.accounts.id.initialize({
          client_id: clientId,
          nonce: gisNonce,
          callback: (response) => gisHandler?.(response),
          auto_select: false,
          cancel_on_tap_outside: true,
        });
        gisInitialized = true;
      }
      window.google.accounts.id.renderButton(googleBtnRef.current, {
        theme: 'outline',
        size: 'large',
        text: 'signin_with',
        shape: 'rectangular',
        width: 320,
        locale: 'id',
      });
      setGoogleReady(true);
    };

    if (window.google?.accounts?.id) {
      render();
      return;
    }

    const existing = document.getElementById('gsi-client');
    const script = existing || document.createElement('script');
    if (!existing) {
      script.id = 'gsi-client';
      script.src = 'https://accounts.google.com/gsi/client';
      script.async = true;
      document.head.appendChild(script);
    }
    script.addEventListener('load', render);
    return () => script.removeEventListener('load', render);
    // Sengaja tanpa dependensi: GIS hanya perlu dipasang sekali per halaman.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="min-h-screen bg-[#f8fafc] text-slate-900 font-sans antialiased relative overflow-hidden flex flex-col justify-between">

      {/* Ambient Background Grid & Orbs */}
      <div className="absolute inset-0 pointer-events-none z-0">
        <div className="absolute top-[-10%] right-[10%] w-[500px] h-[500px] bg-blue-100/40 rounded-full blur-[100px]" />
        <div className="absolute bottom-[-10%] left-[10%] w-[500px] h-[500px] bg-sky-100/40 rounded-full blur-[100px]" />
        <div className="absolute inset-0 opacity-[0.02]" style={{
          backgroundImage: 'radial-gradient(circle, #3b82f6 1px, transparent 1px)',
          backgroundSize: '24px 24px'
        }} />
      </div>

      {/* Header */}
      <header className="relative z-10 max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-20 w-full flex items-center justify-between">
        <div
          onClick={() => navigate('/')}
          className="cursor-pointer select-none"
        >
          <img 
            src={logoImg} 
            alt="bohAntar Logo" 
            className="h-10 w-auto object-contain"
          />
        </div>

        <button
          onClick={handleBackClick}
          className="flex items-center gap-2 px-4 py-2 text-sm font-semibold text-slate-600 hover:text-blue-600 transition-colors rounded-xl hover:bg-slate-50 border border-slate-200/60 bg-white shadow-sm"
        >
          <ArrowLeft className="w-4 h-4" />
          <span>Kembali</span>
        </button>
      </header>

      {/* Form Container */}
      <main className="flex-1 relative z-10 max-w-md w-full mx-auto px-4 py-12 flex flex-col justify-center">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
          className="bg-white border border-slate-200/80 rounded-3xl p-8 shadow-xl shadow-slate-200/50 space-y-6"
        >
          {/* Form Header */}
          <div className="text-center space-y-2">
            <span className="inline-flex items-center px-3 py-0.5 rounded-full bg-blue-50 border border-blue-100 text-blue-600 text-[10px] font-bold uppercase tracking-wider">
              {getRoleBadge()}
            </span>
            <h2 className="text-2xl font-black text-slate-900 leading-none">
              Login {getRoleTitle()}
            </h2>
            <p className="text-xs text-slate-400">
              Masukkan kredensial akun Anda untuk mengakses dashboard.
            </p>
          </div>

          {/* Form */}
          <form onSubmit={handleFormSubmit} className="space-y-4">
            <div>
              <label className="block text-xs font-bold text-slate-600 mb-1.5 uppercase tracking-wide">Email / Username</label>
              <div className="flex items-center px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus-within:border-blue-500 focus-within:bg-white transition">
                <Mail className="w-4.5 h-4.5 text-slate-400 mr-3 flex-shrink-0" />
                <input
                  type="email"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="nama@email.com"
                  className="w-full bg-transparent text-sm text-slate-900 focus:outline-none placeholder-slate-400"
                />
              </div>
            </div>

            <div>
              <label className="block text-xs font-bold text-slate-600 mb-1.5 uppercase tracking-wide">Password</label>
              <div className="flex items-center px-4 py-3 bg-slate-50 border border-slate-200 rounded-xl focus-within:border-blue-500 focus-within:bg-white transition">
                <Lock className="w-4.5 h-4.5 text-slate-400 mr-3 flex-shrink-0" />
                <input
                  type={showPassword ? "text" : "password"}
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  className="w-full bg-transparent text-sm text-slate-900 focus:outline-none placeholder-slate-400"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="text-slate-400 hover:text-slate-600 focus:outline-none ml-2 cursor-pointer flex items-center justify-center"
                >
                  {showPassword ? <EyeOff className="w-4.5 h-4.5" /> : <Eye className="w-4.5 h-4.5" />}
                </button>
              </div>
            </div>

            <Alert type="error" style={{ marginBottom: 0 }}>{error}</Alert>

            <button
              type="submit"
              disabled={loading}
              className="w-full py-3.5 mt-2 bg-gradient-to-r from-blue-600 to-blue-700 hover:brightness-105 font-bold text-sm text-white rounded-xl shadow-lg shadow-blue-600/25 transition flex items-center justify-center gap-2 cursor-pointer"
            >
              {loading ? 'Memproses...' : 'Masuk Dashboard'}
              <ArrowRight className="w-4 h-4" />
            </button>

            <div className="relative my-4">
              <div className="absolute inset-0 flex items-center">
                <div className="w-full border-t border-slate-200"></div>
              </div>
              <div className="relative flex justify-center text-[10px] uppercase">
                <span className="bg-white px-2 text-slate-400">Atau masuk dengan</span>
              </div>
            </div>

            <div className="flex justify-center">
              <div ref={googleBtnRef} />
            </div>
            {!googleReady && (
              <p className="text-[11px] text-slate-400 text-center">
                Memuat tombol Google...
              </p>
            )}
          </form>

          {role !== 'admin' && (
            <div className="pt-4 border-t border-slate-100 text-center space-y-2">
              <p className="text-[11px] text-slate-500">
                Belum terdaftar sebagai Mitra bohAntar?
              </p>
              <button
                type="button"
                onClick={() => navigate(`/register-partner?type=${role}`)}
                className="inline-flex items-center gap-1 text-xs font-bold text-blue-600 hover:text-blue-700 transition cursor-pointer bg-transparent border-none p-0"
              >
                <span>Daftar Sekarang Online</span>
                <ArrowRight className="w-3.5 h-3.5" />
              </button>
            </div>
          )}
        </motion.div>
      </main>

      {/* Footer */}
      <footer className="py-8 text-center text-[10px] text-slate-400">
        &copy; {new Date().getFullYear()} bohAntar. Semua hak cipta dilindungi.
      </footer>
    </div>
  );
}