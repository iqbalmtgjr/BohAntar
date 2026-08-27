import React from 'react';
import { useNavigate } from 'react-router-dom';
import { UtensilsCrossed, KeyRound, ArrowLeft, ArrowRight } from 'lucide-react';
import { motion } from 'motion/react';
import logoImg from '../assets/logo.png';

export default function PortalMitraPage() {
    const navigate = useNavigate();

    const portals = [
        {
            roleKey: 'food',
            title: 'Mitra Resto Food',
            badge: 'bohFood Merchant',
            desc: 'Kelola pesanan makanan, atur daftar menu, harga, jam buka, dan pantau omzet penjualan harian Anda secara praktis.',
            icon: UtensilsCrossed,
            color: 'from-amber-500 to-orange-600',
            bgLight: 'bg-amber-50/50',
            iconBg: 'bg-amber-100 text-amber-600',
            path: '/login-resto'
        },
        {
            roleKey: 'rental',
            title: 'Mitra Rental Mobil & Motor',
            badge: 'Fleet Owner Rental',
            desc: 'Kelola armada kendaraan mobil & motor, atur kalender pemesanan, verifikasi data penyewa, dan optimalkan pendapatan rental Anda.',
            icon: KeyRound,
            color: 'from-emerald-500 to-teal-600',
            bgLight: 'bg-emerald-50/50',
            iconBg: 'bg-emerald-100 text-emerald-600',
            path: '/login-rental'
        }
    ];

    return (
        <div className="min-h-screen bg-[#f8fafc] text-slate-900 font-sans antialiased relative overflow-hidden flex flex-col">
            
            {/* Ambient Background Grid & Orbs */}
            <div className="absolute inset-0 pointer-events-none z-0">
                <div className="absolute top-[-10%] left-[10%] w-[500px] h-[500px] bg-blue-100/50 rounded-full blur-[100px]" />
                <div className="absolute bottom-[-10%] right-[10%] w-[500px] h-[500px] bg-sky-100/50 rounded-full blur-[100px]" />
                <div className="absolute inset-0 opacity-[0.02]" style={{
                    backgroundImage: 'radial-gradient(circle, #3b82f6 1px, transparent 1px)',
                    backgroundSize: '24px 24px'
                }} />
            </div>

            {/* Header Navbar */}
            <header className="relative z-10 border-b border-slate-200/60 bg-white/80 backdrop-blur-md">
                <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-20 flex items-center justify-between">
                    {/* Logo */}
                    <div 
                        onClick={() => navigate('/')} 
                        className="flex items-center gap-3 cursor-pointer select-none"
                    >
                        <img
                            src={logoImg}
                            alt="bohAntar Logo"
                            className="h-10 w-auto object-contain"
                        />
                    </div>

                    {/* Back Button */}
                    <button
                        onClick={() => navigate('/')}
                        className="flex items-center gap-2 px-4 py-2 text-sm font-semibold text-slate-600 hover:text-blue-600 transition-colors rounded-xl hover:bg-slate-50 border border-slate-200/60 bg-white shadow-sm"
                    >
                        <ArrowLeft className="w-4 h-4" />
                        <span>Kembali ke Beranda</span>
                    </button>
                </div>
            </header>

            {/* Main Content */}
            <main className="flex-1 relative z-10 max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-16 flex flex-col justify-center items-center">
                
                {/* Section Header */}
                <div className="text-center space-y-4 max-w-2xl mb-12">
                    <span className="inline-flex items-center px-3.5 py-1 rounded-full bg-blue-50 border border-blue-100 text-blue-600 text-[11px] font-bold uppercase tracking-wider">
                        Portal Kemitraan
                    </span>
                    <h2 className="text-3xl sm:text-4xl font-black text-slate-900 tracking-tight leading-tight">
                        Masuk ke Dashboard Kemitraan Anda
                    </h2>
                    <p className="text-slate-500 text-sm sm:text-base">
                        Pilih jenis portal kemitraan bohAntar di bawah ini untuk mengakses dashboard pengelolaan bisnis Anda.
                    </p>
                </div>

                {/* Selection Cards Grid */}
                <div className="grid grid-cols-1 md:grid-cols-2 gap-8 w-full">
                    {portals.map((portal) => {
                        const IconComponent = portal.icon;
                        return (
                            <motion.div
                                key={portal.roleKey}
                                whileHover={{ y: -6, scale: 1.01 }}
                                transition={{ type: 'spring', stiffness: 300, damping: 20 }}
                                className="bg-white border border-slate-200/80 rounded-3xl p-8 shadow-md hover:shadow-xl shadow-slate-200/50 flex flex-col justify-between relative overflow-hidden"
                            >
                                <div className="space-y-6">
                                    {/* Icon & Badge */}
                                    <div className="flex items-center justify-between">
                                        <div className={`w-14 h-14 rounded-2xl ${portal.iconBg} flex items-center justify-center`}>
                                            <IconComponent className="w-7 h-7" />
                                        </div>
                                        <span className="text-[10px] font-bold uppercase tracking-widest text-slate-400 bg-slate-50 border border-slate-100 px-3 py-1 rounded-full">
                                            {portal.badge}
                                        </span>
                                    </div>

                                    {/* Title & Description */}
                                    <div className="space-y-2">
                                        <h3 className="text-2xl font-black text-slate-900">{portal.title}</h3>
                                        <p className="text-slate-500 text-sm leading-relaxed">{portal.desc}</p>
                                    </div>
                                </div>

                                {/* Action Buttons */}
                                <div className="pt-8 flex flex-col gap-2">
                                    <button
                                        onClick={() => navigate(portal.path)}
                                        className={`w-full py-3.5 px-6 rounded-2xl bg-gradient-to-r ${portal.color} text-white font-bold text-sm shadow-md transition-all hover:brightness-105 flex items-center justify-center gap-2 cursor-pointer`}
                                    >
                                        <span>Masuk Portal Mitra</span>
                                        <ArrowRight className="w-4 h-4" />
                                    </button>
                                    <button
                                        onClick={() => navigate(`/register-partner?type=${portal.roleKey}`)}
                                        className="w-full py-3 px-6 rounded-2xl bg-slate-50 border border-slate-200/80 hover:bg-slate-100/80 text-slate-700 font-bold text-xs shadow-sm transition-all flex items-center justify-center gap-2 cursor-pointer"
                                    >
                                        <span>Daftar Mitra Online</span>
                                    </button>
                                </div>
                            </motion.div>
                        );
                    })}
                </div>

                {/* Info Box: Registration Guide */}
                <div className="mt-12 bg-blue-50/50 border border-blue-100/60 p-6 rounded-3xl text-center max-w-2xl w-full">
                    <h4 className="text-sm font-bold text-slate-900">Belum menjadi Mitra bohAntar?</h4>
                    <p className="text-xs text-slate-500 mt-1 leading-relaxed">
                        Bergabunglah dengan ratusan pengusaha kuliner (Mitra Resto) dan pemilik rental mobil (Mitra Rental) di Kalimantan Barat. Hubungi tim kemitraan kami untuk melakukan pendaftaran secara gratis.
                    </p>
                    <div className="mt-4">
                        <a 
                            href="https://wa.me/628996979079?text=Halo%20Admin%20bohAntar,%20saya%20tertarik%20untuk%20mendaftar%20sebagai%20mitra."
                            target="_blank"
                            rel="noopener noreferrer"
                            className="inline-flex items-center gap-2 px-6 py-2.5 bg-blue-600 hover:bg-blue-700 text-white font-bold text-xs rounded-xl shadow-md transition cursor-pointer"
                        >
                            <span>Hubungi Tim Kemitraan</span>
                            <ArrowRight className="w-3.5 h-3.5" />
                        </a>
                    </div>
                </div>
            </main>

            {/* Footer Brand Label */}
            <footer className="py-8 text-center text-xs text-slate-400 border-t border-slate-200/30">
                &copy; {new Date().getFullYear()} bohAntar. Semua hak cipta dilindungi.
            </footer>
        </div>
    );
}
