import React, { useState, useEffect, useRef, useCallback } from 'react';
import { motion, useInView, useScroll, useTransform, AnimatePresence, useMotionValue, useSpring } from 'motion/react';
import { useNavigate } from 'react-router-dom';
import bgImage from '../assets/bg.jpg';
import logoImg from '../assets/logo.png';
import {
    Bike, Car, Package, UtensilsCrossed, KeyRound, ShieldCheck, MapPin, Star,
    ArrowRight, Download, ExternalLink, ChevronDown, Clock, Sparkles, Smartphone,
    CheckCircle2, Menu, X, Wallet, Percent, Calculator, Users, CreditCard,
    Navigation, Zap, Globe, HeartHandshake, Play, ChevronRight, ArrowUpRight,
    Send, MousePointerClick, Mail, ShoppingBag, Grid, Home, FileText, HelpCircle, User
} from 'lucide-react';

/* â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
   REUSABLE HOOKS
   â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */

// Animated counter hook
function useAnimatedCounter(target, duration = 2000, startOnView = true) {
    const [count, setCount] = useState(0);
    const ref = useRef(null);
    const isInView = useInView(ref, { once: true, margin: '0px' });

    useEffect(() => {
        const shouldStart = startOnView ? isInView : true;
        if (!shouldStart) return;

        const startTime = performance.now();
        let rafId;
        let cancelled = false;

        const animate = (now) => {
            if (cancelled) return;
            const elapsed = now - startTime;
            const progress = Math.min(elapsed / duration, 1);
            const eased = 1 - Math.pow(1 - progress, 3);
            setCount(Math.floor(eased * target));
            if (progress < 1) {
                rafId = requestAnimationFrame(animate);
            } else {
                setCount(target);
            }
        };

        rafId = requestAnimationFrame(animate);
        return () => {
            cancelled = true;
            cancelAnimationFrame(rafId);
        };
    }, [isInView, target, duration, startOnView]);

    return { count, ref };
}

// Section reveal wrapper
function RevealSection({ children, className = '', delay = 0 }) {
    const ref = useRef(null);
    const isInView = useInView(ref, { once: true, margin: '-80px' });

    return (
        <motion.div
            ref={ref}
            initial={{ opacity: 0, y: 60 }}
            animate={isInView ? { opacity: 1, y: 0 } : { opacity: 0, y: 60 }}
            transition={{ duration: 0.7, delay, ease: [0.22, 1, 0.36, 1] }}
            className={className}
        >
            {children}
        </motion.div>
    );
}

// Stagger children wrapper
function StaggerContainer({ children, className = '', staggerDelay = 0.1 }) {
    const ref = useRef(null);
    const isInView = useInView(ref, { once: true, margin: '-60px' });

    return (
        <motion.div
            ref={ref}
            initial="hidden"
            animate={isInView ? 'visible' : 'hidden'}
            variants={{
                hidden: {},
                visible: { transition: { staggerChildren: staggerDelay } }
            }}
            className={className}
        >
            {children}
        </motion.div>
    );
}

const staggerItem = {
    hidden: { opacity: 0, y: 40, scale: 0.95 },
    visible: {
        opacity: 1, y: 0, scale: 1,
        transition: { duration: 0.55, ease: [0.22, 1, 0.36, 1] }
    }
};

/* â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
   MAGNETIC BUTTON COMPONENT
   â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */
/* Dipakai bersama oleh nav desktop dan drawer mobile supaya isinya tidak pernah
   berbeda saat salah satunya diubah. */
const NAV_LINKS = [
    { label: 'Layanan', href: '#layanan', icon: Grid, desc: 'bohFood, bohRide, bohCar & bohRental' },
    { label: 'Keunggulan', href: '#keunggulan', icon: Sparkles, desc: 'Alasan memilih bohAntar' },
    { label: 'Mulai Gabung Mitra', href: '#portal', icon: HeartHandshake, desc: 'Daftarkan usaha atau jadi driver' },
];

const NAV_SERVICES = [
    { label: 'bohFood', icon: UtensilsCrossed, cls: 'bg-amber-50 text-amber-600' },
    { label: 'bohRide', icon: Bike, cls: 'bg-blue-50 text-blue-600' },
    { label: 'bohCar', icon: Car, cls: 'bg-cyan-50 text-cyan-600' },
    { label: 'bohRental', icon: KeyRound, cls: 'bg-emerald-50 text-emerald-600' },
];

function MagneticButton({ children, className = '', ...props }) {

    const ref = useRef(null);
    const x = useMotionValue(0);
    const y = useMotionValue(0);
    const springX = useSpring(x, { stiffness: 300, damping: 20 });
    const springY = useSpring(y, { stiffness: 300, damping: 20 });

    const handleMouse = (e) => {
        const rect = ref.current?.getBoundingClientRect();
        if (!rect) return;
        x.set((e.clientX - rect.left - rect.width / 2) * 0.15);
        y.set((e.clientY - rect.top - rect.height / 2) * 0.15);
    };

    const handleLeave = () => {
        x.set(0);
        y.set(0);
    };

    return (
        <motion.button
            ref={ref}
            onMouseMove={handleMouse}
            onMouseLeave={handleLeave}
            style={{ x: springX, y: springY }}
            whileHover={{ scale: 1.04 }}
            whileTap={{ scale: 0.96 }}
            className={className}
            {...props}
        >
            {children}
        </motion.button>
    );
}


/* â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
   MAIN COMPONENT
   â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */
export default function LandingPage({ onSelectPortal }) {
    const navigate = useNavigate();
    const [activeTab, setActiveTab] = useState('ride');
    const [activeFaq, setActiveFaq] = useState(null);
    const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
    const [scrolled, setScrolled] = useState(false);
    const [isMobile, setIsMobile] = useState(false);

    useEffect(() => {
        const checkMobile = () => setIsMobile(window.innerWidth < 768);
        checkMobile();
        window.addEventListener('resize', checkMobile, { passive: true });
        return () => window.removeEventListener('resize', checkMobile);
    }, []);

    // Fare estimator state
    const [pickup, setPickup] = useState('Jl. Gajah Mada, Pontianak');
    const [dropoff, setDropoff] = useState('Kantor Gubernur Kalbar');
    const [selectedFleet, setSelectedFleet] = useState('ride');
    const [distanceKm] = useState(6.5);
    const [estimatedPrice, setEstimatedPrice] = useState(14000);

    // Parallax refs
    const heroRef = useRef(null);
    const { scrollYProgress } = useScroll({ target: heroRef, offset: ['start start', 'end start'] });
    const heroY = useTransform(scrollYProgress, [0, 1], [0, isMobile ? 0 : 150]);
    const bgY = useTransform(scrollYProgress, [0, 1], [0, isMobile ? 0 : 80]);
    const bgScale = useTransform(scrollYProgress, [0, 1], [1, isMobile ? 1 : 1.05]);
    const heroOpacity = useTransform(scrollYProgress, [0, 0.8], [1, 0]);

    // Scroll detection for navbar
    useEffect(() => {
        const handler = () => setScrolled(window.scrollY > 20);
        window.addEventListener('scroll', handler, { passive: true });
        return () => window.removeEventListener('scroll', handler);
    }, []);

    // Menu mobile: kunci scroll halaman, tutup dengan Esc, dan tutup sendiri
    // begitu layar melebar ke breakpoint desktop (md) supaya panel tidak
    // menggantung di atas nav desktop.
    useEffect(() => {
        if (!mobileMenuOpen) return;
        const prevOverflow = document.body.style.overflow;
        document.body.style.overflow = 'hidden';
        const onKey = (e) => { if (e.key === 'Escape') setMobileMenuOpen(false); };
        const mq = window.matchMedia('(min-width: 768px)');
        const onWide = (e) => { if (e.matches) setMobileMenuOpen(false); };
        window.addEventListener('keydown', onKey);
        mq.addEventListener('change', onWide);
        return () => {
            document.body.style.overflow = prevOverflow;
            window.removeEventListener('keydown', onKey);
            mq.removeEventListener('change', onWide);
        };
    }, [mobileMenuOpen]);


    const handleCalculateFare = (e) => {
        e.preventDefault();
        let baseRate = 8000, perKm = 2000;
        if (selectedFleet === 'car') { baseRate = 20000; perKm = 6000; }
        else if (selectedFleet === 'send') { baseRate = 9000; perKm = 2500; }
        else if (selectedFleet === 'rental') { setEstimatedPrice(450000); return; }
        setEstimatedPrice(Math.round(baseRate + distanceKm * perKm));
    };

    /* â”€â”€â”€â”€ DATA â”€â”€â”€â”€ */
    const services = [
        {
            key: 'food', name: 'bohFood', tagline: 'Pesan makanan kuliner khas Kalbar, dari warung legendaris hingga resto hits.',
            icon: UtensilsCrossed, color: 'from-amber-500 to-orange-500', iconBg: 'bg-amber-50 text-amber-600 border-amber-100',
            img: 'https://images.unsplash.com/photo-1504674900247-0877df9cc836?auto=format&fit=crop&w=800&q=80',
            features: ['Ratusan resto & UMKM pilihan', 'Promo voucher harian', 'Pengantaran higienis'],
        },
        {
            key: 'ride', name: 'bohRide', tagline: 'Ojek motor cepat tembus kemacetan dengan tarif transparan & driver terverifikasi.',
            icon: Bike, color: 'from-blue-500 to-blue-600', iconBg: 'bg-blue-50 text-blue-600 border-blue-100',
            img: 'https://images.unsplash.com/photo-1558981806-ec527fa84c39?auto=format&fit=crop&w=800&q=80',
            features: ['Tarif transparan', 'Mitra terlatih', 'Pelacakan GPS real-time'],
        },
        {
            key: 'car', name: 'bohCar', tagline: 'Taksi mobil sejuk & nyaman berkapasitas hingga 6 penumpang.',
            icon: Car, color: 'from-blue-500 to-blue-600', iconBg: 'bg-blue-50 text-blue-600 border-blue-100',
            img: 'https://images.unsplash.com/photo-1549317661-bd32c8ce0db2?auto=format&fit=crop&w=800&q=80',
            features: ['Kabin bersih & wangi', 'Reguler & Eksekutif', 'Hingga 6 penumpang'],
        },
        {
            key: 'send', name: 'bohSend', tagline: 'Kurir on-demand kilat, kirim dokumen & paket dalam hitungan menit.',
            icon: Package, color: 'from-cyan-500 to-blue-600', iconBg: 'bg-sky-50 text-sky-600 border-sky-100',
            img: 'https://images.unsplash.com/photo-1586528116311-ad8dd3c8310d?auto=format&fit=crop&w=800&q=80',
            features: ['Same-day delivery', 'Asuransi proteksi', 'Tanda terima digital'],
        },
        {
            key: 'rental', name: 'bohRental', tagline: 'Sewa mobil lepas kunci atau dengan driver berpengalaman.',
            icon: KeyRound, color: 'from-emerald-500 to-teal-600', iconBg: 'bg-emerald-50 text-emerald-600 border-emerald-100',
            img: 'https://images.unsplash.com/photo-1503376780353-7e6692767b70?auto=format&fit=crop&w=800&q=80',
            features: ['Avanza, Innova, Fortuner', 'Lepas kunci / dengan driver', 'Konfirmasi instan'],
        }
    ];

    const mockupData = {
        ride: { label: 'BOHRIDE', status: 'Driver Menuju Titik Jemput', time: '3 Menit lagi', driver: 'Pak Hendra (Yamaha NMAX)', plate: 'KB 4821 QA', from: 'Jl. Gajah Mada No. 12', to: 'Kantor Gubernur Kalbar', price: 'Rp 14.000' },
        food: { label: 'BOHFOOD', status: 'Resto Menyiapkan Pesanan', time: 'Tiba pukul 12:40', driver: 'Driver Andre (bohFood)', plate: 'KB 5190 WP', from: 'Kwetiau Apollo Pontianak', to: 'Jl. Ahmad Yani No. 42', price: 'Rp 48.500' },
        car: { label: 'BOHCAR', status: 'Mobil Siap Menjemput', time: '5 Menit lagi', driver: 'Bpk. Ridwan (Toyota Avanza)', plate: 'KB 1902 XX', from: 'Bandara Supadio', to: 'Hotel Mercure Pontianak', price: 'Rp 65.000' },
        send: { label: 'BOHSEND', status: 'Kurir Sedang Antar Paket', time: 'Estimasi 15 Menit', driver: 'Kurir Anton (Express)', plate: 'KB 3312 LK', from: 'Ayani Megamal', to: 'Kubu Raya Sentral', price: 'Rp 16.000' },
        rental: { label: 'BOHRENTAL', status: 'Booking Terkonfirmasi', time: 'Durasi: 3 Hari', driver: 'All New Avanza 2024', plate: 'KB 1001 WZ', from: 'Garasi Mitra Kalbar', to: 'Tour Kota Singkawang', price: 'Rp 450.000/Hari' }
    };
    const currentMockup = mockupData[activeTab];

    const portals = [
        { roleKey: 'food', title: 'Portal Mitra Resto', badge: 'bohFood Merchant', desc: 'Kelola katalog menu, update harga & stok, aktifkan promo, dan pantau pesanan.', icon: UtensilsCrossed, color: 'from-amber-500 to-orange-600', btnClass: 'bg-amber-600 hover:bg-amber-700 shadow-amber-200', path: '/login-resto' },
        { roleKey: 'rental', title: 'Portal Mitra Rental', badge: 'Fleet Owner', desc: 'Kelola inventaris armada, kalender booking, penetapan tarif, dan status unit.', icon: KeyRound, color: 'from-emerald-500 to-teal-600', btnClass: 'bg-emerald-600 hover:bg-emerald-700 shadow-emerald-200', path: '/login-rental' }
    ];

    const faqs = [
        { q: 'Bagaimana cara mulai menggunakan aplikasi bohAntar?', a: 'Unduh aplikasi bohAntar di Play Store atau App Store, daftar akun dengan nomor HP aktif, dan langsung pilih layanan Ride, Car, Send, Food, atau Rental sesuai kebutuhan.' },
        { q: 'Apakah semua mitra pengemudi dan armada terverifikasi?', a: 'Ya, seluruh mitra driver melewati verifikasi identitas resmi (KTP, SIM aktif, SKCK) serta inspeksi kelayakan kendaraan untuk menjamin keamanan perjalanan.' },
        { q: 'Bagaimana cara bergabung menjadi Mitra Resto atau Rental?', a: 'Klik tombol "Portal Mitra" di navigasi atas atau pilih card portal yang sesuai, lalu lakukan login / pendaftaran mitra baru.' },
        { q: 'Metode pembayaran apa saja yang didukung?', a: 'Tunai (Cash), Saldo Dompet Digital bohPay, Transfer Bank (Virtual Account), serta QRIS untuk semua bank & e-wallet.' }
    ];

    // Animated counters
    const downloads = useAnimatedCounter(10000, 2000, false);
    const rating = useAnimatedCounter(49, 1500, false); // will display as 4.9
    const partners = useAnimatedCounter(500, 2000, false);

    // Phone service tab icons
    const serviceTabIcons = [
        { key: 'ride', Icon: Bike, label: 'Ride' },
        { key: 'car', Icon: Car, label: 'Car' },
        { key: 'send', Icon: Package, label: 'Send' },
        { key: 'food', Icon: UtensilsCrossed, label: 'Food' },
        { key: 'rental', Icon: KeyRound, label: 'Rental' },
    ];

    return (
        <div className="min-h-screen bg-[#f8fafc] text-slate-900 font-sans antialiased overflow-x-hidden relative">

            {/* ── AMBIENT BACKGROUND (Hidden on mobile for performance) ── */}
            <div className="fixed inset-0 pointer-events-none z-0 hidden md:block">
                <div className="absolute -top-32 left-1/4 w-[800px] h-[500px] bg-gradient-to-br from-blue-100/60 via-blue-50/40 to-transparent blur-[120px] rounded-full animate-pulse" style={{ animationDuration: '8s' }} />
                <div className="absolute top-1/3 -right-32 w-[500px] h-[500px] bg-gradient-to-bl from-blue-100/40 to-transparent blur-[100px] rounded-full animate-pulse" style={{ animationDuration: '12s' }} />
                <div className="absolute bottom-1/4 -left-32 w-[500px] h-[500px] bg-gradient-to-tr from-cyan-100/30 to-transparent blur-[100px] rounded-full animate-pulse" style={{ animationDuration: '10s' }} />
            </div>

            {/* â”€â”€â”€â”€â”€ NAVBAR â”€â”€â”€â”€â”€ */}
            <motion.header
                initial={{ y: -100 }}
                animate={{ y: 0 }}
                transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
                className={`fixed top-0 left-0 right-0 z-50 transition-all duration-500 ${scrolled
                    ? 'bg-white/90 backdrop-blur-2xl shadow-lg shadow-slate-900/5 border-b border-slate-200/60'
                    : 'bg-transparent'
                    }`}
            >
                <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-20 flex items-center justify-between">
                    {/* Logo */}
                    <motion.div
                        onDoubleClick={() => navigate('/super-admin-login')}
                        className="cursor-pointer select-none"
                        whileHover={{ scale: 1.01 }}
                    >
                        <img 
                            src={logoImg} 
                            alt="bohAntar Logo" 
                            className="h-10 w-auto object-contain"
                        />
                    </motion.div>

                    {/* Desktop Nav */}
                    <nav className="hidden md:flex items-center gap-1">
                        {NAV_LINKS.map((link) => (
                            <a
                                key={link.href}
                                href={link.href}
                                className="relative px-4 py-2 text-sm font-semibold text-slate-600 hover:text-blue-600 transition-colors group"
                            >
                                {link.label}
                                <span className="absolute bottom-0 left-1/2 -translate-x-1/2 w-0 h-0.5 bg-blue-600 rounded-full group-hover:w-3/4 transition-all duration-300" />
                            </a>
                        ))}
                    </nav>

                    {/* CTA */}
                    <div className="hidden md:flex items-center gap-3">
                        <MagneticButton
                            onClick={() => navigate('/portal-mitra')}
                            className="px-5 py-2.5 text-xs font-bold text-white bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 rounded-xl shadow-lg shadow-blue-500/20 transition-all duration-300 flex items-center gap-2 cursor-pointer"
                        >
                            <span>Masuk Portal Mitra</span>
                            <ArrowUpRight className="w-3.5 h-3.5" />
                        </MagneticButton>
                    </div>

                    {/* Mobile toggle */}
                    <button
                        onClick={() => setMobileMenuOpen(true)}
                        className="md:hidden w-11 h-11 flex items-center justify-center text-slate-700 bg-white/90 rounded-2xl border border-slate-200/80 shadow-sm active:scale-95 transition-transform"
                        aria-label="Buka menu"
                        aria-expanded={mobileMenuOpen}
                    >
                        <Menu className="w-5 h-5" />
                    </button>
                </div>
            </motion.header>

            {/* MOBILE MENU (drawer)
                Drawer sengaja di luar <header>: header-nya fixed setinggi 80px,
                jadi panel yang bersarang di dalamnya ikut terpotong dan tidak
                pernah bisa setinggi layar. */}
            <AnimatePresence>
                {mobileMenuOpen && (
                    <>
                        <motion.div
                            key="nav-backdrop"
                            initial={{ opacity: 0 }}
                            animate={{ opacity: 1 }}
                            exit={{ opacity: 0 }}
                            transition={{ duration: 0.25 }}
                            onClick={() => setMobileMenuOpen(false)}
                            className="md:hidden fixed inset-0 z-[60] bg-slate-950/45 backdrop-blur-[3px]"
                        />

                        <motion.aside
                            key="nav-panel"
                            role="dialog"
                            aria-modal="true"
                            aria-label="Menu navigasi"
                            initial={{ x: "100%" }}
                            animate={{ x: 0 }}
                            exit={{ x: "100%" }}
                            transition={{ type: "spring", stiffness: 420, damping: 40, mass: 0.9 }}
                            className="md:hidden fixed top-0 right-0 z-[70] w-[87vw] max-w-[370px] bg-white shadow-2xl shadow-slate-950/30 rounded-l-[28px] flex flex-col"
                            style={{ height: "100dvh" }}
                        >
                            {/* Kepala panel */}
                            <div className="flex items-center justify-between px-5 h-20 border-b border-slate-100 shrink-0">
                                <img src={logoImg} alt="bohAntar" className="h-9 w-auto object-contain" />
                                <button
                                    onClick={() => setMobileMenuOpen(false)}
                                    className="w-11 h-11 flex items-center justify-center rounded-2xl text-slate-500 bg-slate-50 border border-slate-200/70 active:scale-95 transition-transform"
                                    aria-label="Tutup menu"
                                >
                                    <X className="w-5 h-5" />
                                </button>
                            </div>

                            {/* Isi panel */}
                            <div className="flex-1 overflow-y-auto overscroll-contain px-5 py-5">
                                <p className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-400 mb-3 px-1">
                                    Navigasi
                                </p>

                                <div className="space-y-2">
                                    {NAV_LINKS.map((link, i) => (
                                        <motion.a
                                            key={link.href}
                                            href={link.href}
                                            onClick={() => setMobileMenuOpen(false)}
                                            initial={{ opacity: 0, x: 24 }}
                                            animate={{ opacity: 1, x: 0 }}
                                            transition={{ delay: 0.08 + i * 0.06, duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
                                            className="flex items-center gap-3.5 min-h-[60px] px-3.5 py-3 rounded-2xl bg-slate-50/80 border border-slate-100 active:bg-blue-50 active:border-blue-100 transition-colors"
                                        >
                                            <span className="w-10 h-10 shrink-0 rounded-xl bg-white border border-slate-200/80 shadow-sm flex items-center justify-center text-blue-600">
                                                <link.icon className="w-[18px] h-[18px]" />
                                            </span>
                                            <span className="min-w-0 flex-1">
                                                <span className="block text-[14px] font-bold text-slate-800 leading-tight">{link.label}</span>
                                                <span className="block text-[11px] text-slate-400 truncate mt-0.5">{link.desc}</span>
                                            </span>
                                            <ChevronRight className="w-4 h-4 text-slate-300 shrink-0" />
                                        </motion.a>
                                    ))}
                                </div>

                                <p className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-400 mt-7 mb-3 px-1">
                                    Layanan Kami
                                </p>
                                <div className="grid grid-cols-4 gap-2">
                                    {NAV_SERVICES.map((s, i) => (
                                        <motion.a
                                            key={s.label}
                                            href="#layanan"
                                            onClick={() => setMobileMenuOpen(false)}
                                            initial={{ opacity: 0, y: 12 }}
                                            animate={{ opacity: 1, y: 0 }}
                                            transition={{ delay: 0.24 + i * 0.05, duration: 0.3 }}
                                            className="flex flex-col items-center gap-1.5 py-3 px-1 rounded-2xl border border-slate-100 bg-white active:scale-95 transition-transform"
                                        >
                                            <span className={`w-9 h-9 rounded-xl flex items-center justify-center ${s.cls}`}>
                                                <s.icon className="w-[17px] h-[17px]" />
                                            </span>
                                            <span className="text-[9.5px] font-bold text-slate-600 leading-none text-center">{s.label}</span>
                                        </motion.a>
                                    ))}
                                </div>

                                <p className="text-[10px] font-bold uppercase tracking-[0.14em] text-slate-400 mt-7 mb-3 px-1">
                                    Portal &amp; Bantuan
                                </p>
                                <div className="rounded-2xl border border-slate-100 overflow-hidden">
                                    {[
                                        { label: 'Login Mitra bohFood', icon: UtensilsCrossed, run: () => navigate('/login-resto') },
                                        { label: 'Login Mitra bohRental', icon: KeyRound, run: () => navigate('/login-rental') },
                                        { label: 'FAQ & Pusat Bantuan', icon: HelpCircle, run: () => { window.location.hash = '#faq'; } },
                                    ].map((r, i) => (
                                        <button
                                            key={r.label}
                                            onClick={() => { setMobileMenuOpen(false); r.run(); }}
                                            className={`w-full min-h-[46px] flex items-center gap-3 px-3.5 text-left active:bg-slate-50 transition-colors ${i ? 'border-t border-slate-100' : ''}`}
                                        >
                                            <r.icon className="w-4 h-4 text-slate-400 shrink-0" />
                                            <span className="flex-1 text-[12.5px] font-semibold text-slate-600">{r.label}</span>
                                            <ChevronRight className="w-3.5 h-3.5 text-slate-300 shrink-0" />
                                        </button>
                                    ))}
                                </div>
                            </div>


                            {/* Aksi utama, selalu terlihat tanpa perlu scroll */}
                            <div
                                className="shrink-0 px-5 pt-4 border-t border-slate-100 bg-white space-y-2.5"
                                style={{ paddingBottom: "calc(1rem + env(safe-area-inset-bottom))" }}
                            >
                                <button
                                    onClick={() => { setMobileMenuOpen(false); navigate('/portal-mitra'); }}
                                    className="w-full min-h-[52px] flex items-center justify-center gap-2 bg-gradient-to-r from-blue-600 to-blue-700 text-white font-bold text-sm rounded-2xl shadow-lg shadow-blue-600/25 active:scale-[0.98] transition-transform"
                                >
                                    Masuk Portal Mitra
                                    <ArrowUpRight className="w-4 h-4" />
                                </button>
                                <a
                                    href="#download"
                                    onClick={() => setMobileMenuOpen(false)}
                                    className="w-full min-h-[52px] flex items-center justify-center gap-2 text-slate-700 font-bold text-sm rounded-2xl border border-slate-200 bg-slate-50 active:scale-[0.98] transition-transform"
                                >
                                    <Download className="w-4 h-4" />
                                    Unduh Aplikasi
                                </a>
                            </div>
                        </motion.aside>
                    </>
                )}
            </AnimatePresence>



            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                HERO SECTION
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <section ref={heroRef} className="relative pt-28 pb-20 lg:pt-36 lg:pb-28 z-10 overflow-hidden">

                {/* ── Beautiful Hero Background ── */}
                <div className="absolute inset-0 pointer-events-none">
                    {/* Background image from assets with parallax scroll and zoom */}
                    <motion.div
                        style={{ y: bgY, scale: bgScale, backgroundImage: `url(${bgImage})` }}
                        className="absolute inset-0 bg-cover bg-center bg-no-repeat opacity-100"
                    />
                    {/* Main gradient overlay to keep text readable on the left and show the image on the right */}
                    <div className="absolute inset-0 bg-gradient-to-r from-white via-white/90 via-white/60 to-transparent" />
                    <div className="absolute inset-0 bg-gradient-to-b from-white/10 via-transparent to-[#f8fafc]" />

                    {/* Animated gradient orbs (Disabled on mobile for performance) */}
                    {!isMobile && (
                        <>
                            <motion.div
                                animate={{ x: [0, 30, 0], y: [0, -20, 0] }}
                                transition={{ repeat: Infinity, duration: 15, ease: 'easeInOut' }}
                                className="absolute -top-20 right-1/4 w-[500px] h-[500px] bg-gradient-to-br from-blue-200/50 to-cyan-200/30 rounded-full blur-[100px]"
                            />
                            <motion.div
                                animate={{ x: [0, -20, 0], y: [0, 30, 0] }}
                                transition={{ repeat: Infinity, duration: 18, ease: 'easeInOut' }}
                                className="absolute top-1/3 -left-20 w-[400px] h-[400px] bg-gradient-to-tr from-sky-200/40 to-blue-100/30 rounded-full blur-[100px]"
                            />
                            <motion.div
                                animate={{ scale: [1, 1.1, 1], opacity: [0.3, 0.5, 0.3] }}
                                transition={{ repeat: Infinity, duration: 10, ease: 'easeInOut' }}
                                className="absolute bottom-0 right-0 w-[600px] h-[400px] bg-gradient-to-tl from-blue-100/40 via-cyan-50/30 to-transparent rounded-full blur-[80px]"
                            />
                        </>
                    )}

                    {/* Subtle grid pattern overlay */}
                    <div className="absolute inset-0 opacity-[0.03]" style={{
                        backgroundImage: 'radial-gradient(circle, #3b82f6 1px, transparent 1px)',
                        backgroundSize: '32px 32px'
                    }} />

                    {/* Decorative geometric shapes (Disabled on mobile for performance) */}
                    {!isMobile && (
                        <>
                            <motion.div
                                animate={{ rotate: 360 }}
                                transition={{ repeat: Infinity, duration: 60, ease: 'linear' }}
                                className="absolute top-20 right-[15%] w-32 h-32 border border-blue-200/20 rounded-3xl"
                            />
                            <motion.div
                                animate={{ rotate: -360 }}
                                transition={{ repeat: Infinity, duration: 45, ease: 'linear' }}
                                className="absolute bottom-32 left-[10%] w-24 h-24 border border-sky-200/25 rounded-full"
                            />
                            <motion.div
                                animate={{ rotate: 360 }}
                                transition={{ repeat: Infinity, duration: 50, ease: 'linear' }}
                                className="absolute top-1/2 right-[5%] w-16 h-16 border border-blue-200/15 rounded-2xl"
                            />
                        </>
                    )}

                    {/* Bottom fade to white */}
                    <div className="absolute bottom-0 left-0 right-0 h-32 bg-gradient-to-t from-[#f8fafc] to-transparent" />
                </div>

                <motion.div style={{ y: heroY, opacity: heroOpacity }} className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 relative">
                    <div className="grid grid-cols-1 lg:grid-cols-12 gap-12 lg:gap-16 items-center">

                        {/* â”€â”€ Left Column â”€â”€ */}
                        <div className="lg:col-span-7 space-y-8">

                            {/* Badge */}
                            <motion.div
                                initial={{ opacity: 0, x: -30 }}
                                animate={{ opacity: 1, x: 0 }}
                                transition={{ duration: 0.6, delay: 0.2 }}
                                className="inline-flex items-center gap-2 px-4 py-1.5 rounded-full bg-blue-50/80 border border-blue-100 text-blue-600 text-xs font-semibold backdrop-blur-sm"
                            >
                                <motion.div animate={{ rotate: [0, 15, -15, 0] }} transition={{ repeat: Infinity, duration: 3, ease: 'easeInOut' }}>
                                    <Sparkles className="w-3.5 h-3.5" />
                                </motion.div>
                                <span>SuperApp Mobilitas Kalbar v2.0</span>
                            </motion.div>

                            {/* Animated Title */}
                            <div className="space-y-1">
                                {['Satu Aplikasi,', 'Semua Solusi Mobilitas', 'Anda'].map((line, i) => (
                                    <motion.div
                                        key={i}
                                        initial={{ opacity: 0, y: 40, clipPath: 'inset(100% 0 0 0)' }}
                                        animate={{ opacity: 1, y: 0, clipPath: 'inset(0% 0 0 0)' }}
                                        transition={{ duration: 0.8, delay: 0.3 + i * 0.15, ease: [0.22, 1, 0.36, 1] }}
                                    >
                                        <h1 className={`text-4xl sm:text-5xl lg:text-[3.5rem] font-black tracking-tight leading-[1.1] ${i === 1
                                            ? 'text-transparent bg-clip-text bg-gradient-to-r from-blue-600 via-blue-600 to-blue-600 bg-[length:200%_auto] animate-[shimmer_3s_linear_infinite]'
                                            : 'text-slate-900'
                                            }`}>
                                            {line}
                                        </h1>
                                    </motion.div>
                                ))}
                            </div>

                            {/* Subtitle */}
                            <motion.p
                                initial={{ opacity: 0, y: 20 }}
                                animate={{ opacity: 1, y: 0 }}
                                transition={{ duration: 0.7, delay: 0.8 }}
                                className="text-base sm:text-lg text-slate-500 max-w-xl leading-relaxed"
                            >
                                Pesan ojek online, kirim paket cepat, pesan makanan terdekat, hingga sewa mobil harian & jam-jaman langsung secara praktis dari HP Anda.
                            </motion.p>

                            {/* Hero Buttons */}
                            <motion.div
                                initial={{ opacity: 0, y: 20 }}
                                animate={{ opacity: 1, y: 0 }}
                                transition={{ duration: 0.7, delay: 1 }}
                                className="flex flex-wrap gap-4 pt-2"
                            >
                                <MagneticButton
                                    className="group px-7 py-4 bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 text-white font-bold text-sm rounded-2xl shadow-xl shadow-blue-500/25 transition-all duration-300 flex items-center gap-2.5 cursor-pointer"
                                >
                                    <Download className="w-4.5 h-4.5 transition-transform group-hover:-translate-y-0.5" />
                                    <span>Unduh Aplikasi</span>
                                </MagneticButton>

                                <MagneticButton
                                    onClick={() => navigate('/portal-mitra')}
                                    className="group px-7 py-4 bg-white hover:bg-slate-50 text-blue-600 font-bold text-sm rounded-2xl border-2 border-blue-100 hover:border-blue-200 shadow-sm transition-all duration-300 flex items-center gap-2 cursor-pointer"
                                >
                                    <span>Gabung Mitra</span>
                                    <ArrowRight className="w-4 h-4 transition-transform group-hover:translate-x-1" />
                                </MagneticButton>
                            </motion.div>

                            {/* ── Stats Row ── */}
                            <motion.div
                                initial={{ opacity: 0, y: 30 }}
                                animate={{ opacity: 1, y: 0 }}
                                transition={{ duration: 0.8, delay: 1.2 }}
                                className="bg-white/80 backdrop-blur-xl border border-slate-100 rounded-3xl p-5 shadow-xl shadow-slate-200/50 grid grid-cols-1 sm:grid-cols-3 gap-4 max-w-xl"
                            >
                                {[
                                    { ref: downloads.ref, value: `${Math.floor(downloads.count / 1000)}K+`, label: 'Unduhan', icon: Download, iconBg: 'bg-blue-50 text-blue-600' },
                                    { ref: rating.ref, value: `${(rating.count / 10).toFixed(1)}/5`, label: 'Rating Pengguna', icon: Star, iconBg: 'bg-amber-50 text-amber-500', fill: true },
                                    { ref: partners.ref, value: `${partners.count}+`, label: 'Mitra Aktif', icon: Users, iconBg: 'bg-emerald-50 text-emerald-600' }
                                ].map((stat, i) => (
                                    <div key={i} ref={stat.ref} className={`flex items-center gap-3 ${i > 0 ? 'pl-1 border-t pt-4 border-slate-100 sm:pt-0 sm:border-t-0 sm:pl-4 sm:border-l' : 'pl-1'}`}>
                                        <div className={`w-10 h-10 rounded-xl ${stat.iconBg} flex items-center justify-center flex-shrink-0`}>
                                            <stat.icon className={`w-4.5 h-4.5 ${stat.fill ? 'fill-amber-400' : ''}`} />
                                        </div>
                                        <div>
                                            <div className="text-lg font-black text-slate-900 leading-none tabular-nums">{stat.value}</div>
                                            <div className="text-[10px] font-medium text-slate-400 mt-0.5">{stat.label}</div>
                                        </div>
                                    </div>
                                ))}
                            </motion.div>
                        </div>

                        {/* ── Right Column: Interactive Phone (Flutter / Gojek Light Style) ── */}
                        <motion.div
                            initial={{ opacity: 0, x: 80, rotateY: -8 }}
                            animate={{ opacity: 1, x: 0, rotateY: 0 }}
                            transition={{ duration: 1, delay: 0.5, ease: [0.22, 1, 0.36, 1] }}
                            className="lg:col-span-5 flex justify-center items-center relative perspective-[1200px]"
                        >
                            {/* Glow behind phone */}
                            <motion.div
                                animate={{ scale: [0.85, 1, 0.85], opacity: [0.3, 0.5, 0.3] }}
                                transition={{ repeat: Infinity, duration: 6, ease: 'easeInOut' }}
                                className="absolute inset-0 bg-gradient-to-tr from-blue-400/25 via-cyan-300/20 to-blue-500/25 blur-[90px] rounded-full pointer-events-none"
                            />

                            {/* Floating Card 1: Live Status Driver */}
                            <motion.div
                                animate={{ y: [0, -8, 0] }}
                                transition={{ repeat: Infinity, duration: 3.5, ease: 'easeInOut' }}
                                className="absolute -left-6 top-24 z-30 hidden sm:flex items-center gap-3 bg-white/95 backdrop-blur-md p-3.5 rounded-2xl shadow-xl shadow-slate-900/10 border border-slate-100"
                            >
                                <div className="w-10 h-10 rounded-xl bg-blue-600 flex items-center justify-center text-white shadow-md shadow-blue-500/30">
                                    <Bike className="w-5 h-5" />
                                </div>
                                <div>
                                    <div className="flex items-center gap-1.5">
                                        <span className="w-2 h-2 rounded-full bg-emerald-500 animate-ping"></span>
                                        <span className="text-[11px] font-bold text-slate-800">Driver Ditemukan</span>
                                    </div>
                                    <div className="text-[10px] text-slate-500 font-medium">Pak Hendra (Yamaha NMAX)</div>
                                </div>
                            </motion.div>

                            {/* Floating Card 2: Promo Diskon */}
                            <motion.div
                                animate={{ y: [0, 8, 0] }}
                                transition={{ repeat: Infinity, duration: 4, ease: 'easeInOut', delay: 0.5 }}
                                className="absolute -right-6 bottom-16 z-30 hidden sm:flex items-center gap-2.5 bg-white/95 backdrop-blur-md px-4 py-3 rounded-2xl shadow-xl shadow-slate-900/10 border border-slate-100"
                            >
                                <div className="w-8 h-8 rounded-full bg-amber-100 flex items-center justify-center text-amber-600 font-black text-xs">
                                    %
                                </div>
                                <div>
                                    <div className="text-[11px] font-bold text-slate-800">Diskon Ongkir 30%</div>
                                    <div className="text-[10px] text-emerald-600 font-semibold">Otomatis Terpasang</div>
                                </div>
                            </motion.div>

                            {/* 3D Realistic Floor Shadow (Disabled animation on mobile) */}
                            <motion.div
                                animate={isMobile ? {} : { 
                                    scale: [0.85, 1.02, 0.85],
                                    opacity: [0.55, 0.28, 0.55] 
                                }}
                                transition={{ repeat: Infinity, duration: 5, ease: 'easeInOut' }}
                                className="absolute -bottom-8 left-12 right-12 h-6 bg-slate-950/40 blur-xl rounded-full pointer-events-none z-0"
                            />

                            {/* Smartphone Container with floating motion (Disabled on mobile) */}
                            <motion.div
                                animate={isMobile ? { y: 0 } : { y: [0, -12, 0] }}
                                transition={{ repeat: Infinity, duration: 5, ease: 'easeInOut' }}
                                className="relative z-10 flex justify-center items-center"
                            >
                                {/* Smartphone Frame with 3D Hover Tilt (Disabled on mobile) */}
                                <motion.div
                                    whileHover={isMobile ? {} : { rotateY: 18, rotateX: -12, scale: 1.04 }}
                                    transition={{ type: 'spring', stiffness: 180, damping: 18 }}
                                    className="relative w-[320px] bg-slate-900 p-3.5 rounded-[48px] shadow-[0_25px_50px_-12px_rgba(0,0,0,0.4)] border-[6px] border-slate-800 ring-1 ring-white/10 z-10 cursor-pointer"
                                    style={{ transformStyle: 'preserve-3d', perspective: '1000px' }}
                                >
                                    {/* 3D Glassmorphic Backdrop Card (Simplified bg & disabled backdrop filter on mobile for performance) */}
                                    <div 
                                        className="absolute inset-y-1 left-8 -right-8 bg-white/95 md:bg-white/25 border border-white/35 backdrop-blur-none md:backdrop-blur-md rounded-[48px] shadow-lg shadow-slate-900/10 pointer-events-none"
                                        style={{ transform: 'translateZ(-35px)', zIndex: -1 }}
                                    />
                                {/* Dynamic Island */}
                                <div className="w-28 h-5 bg-black mx-auto rounded-full mb-3 flex items-center justify-between px-3 border border-slate-800/50">
                                    <div className="w-2 h-2 rounded-full bg-slate-700" />
                                    <motion.div animate={{ opacity: [1, 0.3, 1] }} transition={{ repeat: Infinity, duration: 2 }} className="w-2 h-2 rounded-full bg-blue-500" />
                                </div>

                                {/* Screen (Light App SuperApp UI) */}
                                <div className="bg-gradient-to-b from-blue-50/80 via-white to-white rounded-[36px] overflow-hidden text-slate-800 font-sans shadow-inner pt-2 pb-3">

                                    {/* 1. App Top Header */}
                                    <div className="px-4 pb-2.5 flex items-center justify-between border-b border-slate-100/60">
                                        <img src={logoImg} alt="bohAntar" className="h-8 w-auto" />
                                        <div className="w-7 h-7 rounded-full bg-slate-100 flex items-center justify-center text-slate-600">
                                            <ArrowRight className="w-3.5 h-3.5" />
                                        </div>
                                    </div>

                                    {/* 2. User & Location Greeting */}
                                    <div className="px-4 pt-2 pb-2.5">
                                        <div className="flex items-center gap-1 text-[10px] font-semibold text-slate-500">
                                            <MapPin className="w-3 h-3 text-blue-600 flex-shrink-0" />
                                            <span className="truncate">Jl. Merdeka No. 10, Pontianak</span>
                                        </div>
                                        <div className="text-base font-extrabold text-slate-900 mt-0.5">
                                            Halo, Aloy 👋
                                        </div>
                                        <div className="text-[11px] text-slate-400 font-medium">Mau antar apa hari ini?</div>
                                    </div>

                                    {/* 3. bohPay Wallet Card */}
                                    <div className="mx-4 mb-3 p-2.5 bg-white rounded-2xl border border-slate-100 shadow-sm flex items-center justify-between">
                                        <div className="flex items-center gap-2">
                                            <div className="w-8 h-8 rounded-xl bg-blue-50 border border-blue-100 flex items-center justify-center text-blue-600">
                                                <Wallet className="w-4 h-4" />
                                            </div>
                                            <div>
                                                <div className="text-[9px] font-bold text-blue-600 uppercase tracking-wider">bohPay</div>
                                                <div className="text-xs font-black text-slate-900">Rp 75.000</div>
                                            </div>
                                        </div>
                                        <button className="px-3 py-1 bg-blue-600 hover:bg-blue-700 text-white font-bold text-[10px] rounded-lg shadow-sm transition">
                                            Top Up
                                        </button>
                                    </div>

                                    {/* 4. Grid 6 Service Icons */}
                                    <div className="px-4 grid grid-cols-3 gap-y-2.5 gap-x-2 text-center mb-3">
                                        {[
                                            { key: 'car', name: 'BohAntar', icon: Package, bg: 'bg-blue-500' },
                                            { key: 'ride', name: 'BohRide', icon: Bike, bg: 'bg-blue-600' },
                                            { key: 'food', name: 'BohFood', icon: UtensilsCrossed, bg: 'bg-rose-500' },
                                            { key: 'send', name: 'BohSend', icon: Mail, bg: 'bg-cyan-500' },
                                            { key: 'rental', name: 'BohMart', icon: ShoppingBag, bg: 'bg-amber-500' },
                                            { key: 'rental', name: 'Lainnya', icon: Grid, bg: 'bg-slate-600' }
                                        ].map((item, idx) => {
                                            const Icon = item.icon;
                                            const isSelected = activeTab === item.key;
                                            return (
                                                <motion.div
                                                    key={idx}
                                                    whileTap={{ scale: 0.95 }}
                                                    onClick={() => setActiveTab(item.key)}
                                                    className="flex flex-col items-center gap-1 cursor-pointer group"
                                                >
                                                    <div className={`w-11 h-11 ${item.bg} rounded-2xl flex items-center justify-center text-white shadow-sm transition group-hover:scale-105 ${isSelected ? 'ring-2 ring-blue-600 ring-offset-2' : ''}`}>
                                                        <Icon className="w-5 h-5" />
                                                    </div>
                                                    <span className="text-[10px] font-bold text-slate-700">{item.name}</span>
                                                </motion.div>
                                            );
                                        })}
                                    </div>

                                    {/* 5. Promo Banner Card */}
                                    <div className="mx-4 p-2.5 bg-gradient-to-r from-blue-600 to-indigo-600 rounded-xl text-white shadow-sm relative overflow-hidden">
                                        <div className="text-[8px] font-bold uppercase tracking-wider text-blue-200">Promo Spesial</div>
                                        <div className="text-[11px] font-black leading-tight">DISKON ONGKIR bohAntar</div>
                                        <div className="text-[9px] text-blue-100">Khusus pengguna baru se-Kalbar</div>
                                    </div>

                                    {/* 6. Bottom Navigation Bar */}
                                    <div className="mt-3 pt-2 px-5 border-t border-slate-100 flex justify-between items-center text-[9px] font-bold text-slate-400">
                                        <div className="flex flex-col items-center gap-0.5 text-blue-600">
                                            <Home className="w-3.5 h-3.5" />
                                            <span>Home</span>
                                        </div>
                                        <div className="flex flex-col items-center gap-0.5 hover:text-slate-700">
                                            <FileText className="w-3.5 h-3.5" />
                                            <span>Aktivitas</span>
                                        </div>
                                        <div className="flex flex-col items-center gap-0.5 hover:text-slate-700">
                                            <HelpCircle className="w-3.5 h-3.5" />
                                            <span>Bantuan</span>
                                        </div>
                                        <div className="flex flex-col items-center gap-0.5 hover:text-slate-700">
                                            <User className="w-3.5 h-3.5" />
                                            <span>Akun</span>
                                        </div>
                                    </div>

                                </div>
                            </motion.div>
                        </motion.div>
                    </motion.div>
                    </div>
                </motion.div>

                {/* Scroll indicator */}
                <motion.div
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    transition={{ delay: 2 }}
                    className="flex justify-center mt-12"
                >
                    <motion.div
                        animate={{ y: [0, 8, 0] }}
                        transition={{ repeat: Infinity, duration: 2, ease: 'easeInOut' }}
                        className="flex flex-col items-center gap-2 text-slate-400"
                    >
                        <MousePointerClick className="w-4 h-4" />
                        <span className="text-[10px] font-medium tracking-wider uppercase">Scroll untuk eksplorasi</span>
                    </motion.div>
                </motion.div>
            </section>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                FARE ESTIMATOR
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <RevealSection>
                <section id="estimasi" className="py-16 bg-white/60 backdrop-blur-sm border-y border-slate-100 relative z-10">
                    <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
                        <div className="bg-gradient-to-br from-slate-50 to-white p-6 sm:p-10 rounded-3xl border border-slate-100 shadow-lg shadow-slate-200/40">

                            <div className="flex flex-col lg:flex-row lg:items-center justify-between gap-6 mb-8">
                                <div>
                                    <div className="inline-flex items-center gap-1.5 text-blue-600 text-xs font-bold uppercase tracking-wider mb-2">
                                        <Calculator className="w-3.5 h-3.5" />
                                        <span>Simulasi Cepat</span>
                                    </div>
                                    <h2 className="text-2xl sm:text-3xl font-extrabold text-slate-900">Cek Perkiraan Tarif Perjalanan</h2>
                                    <p className="text-sm text-slate-500 mt-1">Transparan dan tanpa biaya tersembunyi.</p>
                                </div>
                                <motion.div
                                    layout
                                    className="bg-white border border-slate-200 px-6 py-4 rounded-2xl flex items-center gap-4 shadow-sm"
                                >
                                    <div>
                                        <div className="text-[10px] uppercase font-bold text-slate-400 tracking-wider">Perkiraan Tarif</div>
                                        <AnimatePresence mode="wait">
                                            <motion.div
                                                key={estimatedPrice}
                                                initial={{ opacity: 0, y: 10 }}
                                                animate={{ opacity: 1, y: 0 }}
                                                exit={{ opacity: 0, y: -10 }}
                                                className="text-xl sm:text-2xl font-black text-blue-600"
                                            >
                                                {selectedFleet === 'rental' ? 'Rp 450.000/Hari' : `Rp ${estimatedPrice.toLocaleString('id-ID')}`}
                                            </motion.div>
                                        </AnimatePresence>
                                    </div>
                                    <div className="w-10 h-10 rounded-xl bg-blue-50 flex items-center justify-center text-blue-600">
                                        <CreditCard className="w-5 h-5" />
                                    </div>
                                </motion.div>
                            </div>

                            <form onSubmit={handleCalculateFare} className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                                {[
                                    { icon: MapPin, label: 'Titik Jemput', value: pickup, onChange: setPickup, placeholder: 'Lokasi jemput' },
                                    { icon: Navigation, label: 'Titik Tujuan', value: dropoff, onChange: setDropoff, placeholder: 'Lokasi tujuan' }
                                ].map((field, i) => (
                                    <motion.div
                                        key={i}
                                        whileFocus={{ scale: 1.02 }}
                                        className="bg-white border border-slate-200 rounded-2xl p-3 flex items-center gap-3 focus-within:border-blue-400 focus-within:ring-2 focus-within:ring-blue-100 transition-all shadow-sm"
                                    >
                                        <field.icon className="w-5 h-5 text-blue-600 flex-shrink-0" />
                                        <div className="w-full">
                                            <label className="block text-[9px] font-bold text-slate-400 uppercase">{field.label}</label>
                                            <input type="text" value={field.value} onChange={(e) => field.onChange(e.target.value)}
                                                className="w-full bg-transparent text-xs font-semibold text-slate-800 focus:outline-none placeholder:text-slate-400"
                                                placeholder={field.placeholder} />
                                        </div>
                                    </motion.div>
                                ))}
                                <div className="bg-white border border-slate-200 rounded-2xl p-3 flex items-center gap-3 focus-within:border-blue-400 focus-within:ring-2 focus-within:ring-blue-100 transition-all shadow-sm">
                                    <Car className="w-5 h-5 text-blue-600 flex-shrink-0" />
                                    <div className="w-full">
                                        <label className="block text-[9px] font-bold text-slate-400 uppercase">Armada</label>
                                        <select value={selectedFleet} onChange={(e) => setSelectedFleet(e.target.value)}
                                            className="w-full bg-transparent text-xs font-semibold text-slate-800 focus:outline-none cursor-pointer">
                                            <option value="ride">bohRide (Motor)</option>
                                            <option value="car">bohCar (Mobil)</option>
                                            <option value="send">bohSend (Kurir)</option>
                                            <option value="rental">bohRental (Sewa)</option>
                                        </select>
                                    </div>
                                </div>
                                <MagneticButton type="submit"
                                    className="w-full py-3.5 bg-gradient-to-r from-blue-600 to-blue-700 hover:from-blue-700 hover:to-blue-800 text-white font-bold text-sm rounded-2xl shadow-lg shadow-blue-200 transition-all flex items-center justify-center gap-2 cursor-pointer">
                                    <span>Hitung Estimasi</span>
                                    <ArrowRight className="w-4 h-4" />
                                </MagneticButton>
                            </form>
                        </div>
                    </div>
                </section>
            </RevealSection>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                SERVICES SECTION
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <section id="layanan" className="py-20 lg:py-28 max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 relative z-10">
                <RevealSection className="text-center max-w-3xl mx-auto mb-16 space-y-3">
                    <div className="inline-flex items-center gap-1.5 text-xs font-bold uppercase tracking-wider text-blue-600">
                        <Sparkles className="w-3.5 h-3.5" />
                        <span>Ekosistem Terlengkap</span>
                    </div>
                    <h2 className="text-3xl sm:text-4xl font-extrabold text-slate-900 tracking-tight">
                        Layanan Kami untuk Anda
                    </h2>
                    <p className="text-slate-500 text-sm sm:text-base">Lima layanan terintegrasi dalam satu platform mobilitas digital.</p>
                </RevealSection>

                <StaggerContainer className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 sm:gap-8">
                    {services.map((item) => {
                        const Icon = item.icon;
                        return (
                            <motion.div
                                key={item.key}
                                variants={staggerItem}
                                whileHover={{ y: -8, transition: { duration: 0.3 } }}
                                className="group bg-white rounded-3xl overflow-hidden border border-slate-100 shadow-sm hover:shadow-xl hover:shadow-slate-200/60 transition-all duration-500 flex flex-col justify-between h-full"
                            >
                                <div className="p-6 space-y-4">
                                    <motion.div
                                        whileHover={{ rotate: [0, -10, 10, 0] }}
                                        transition={{ duration: 0.5 }}
                                        className={`w-11 h-11 rounded-xl border flex items-center justify-center shadow-sm ${item.iconBg}`}
                                    >
                                        <Icon className="w-5 h-5" />
                                    </motion.div>
                                    <div>
                                        <h3 className="text-lg font-black text-slate-900">{item.name}</h3>
                                        <p className="text-xs text-slate-500 leading-relaxed mt-1">{item.tagline}</p>
                                    </div>

                                    {/* Feature chips */}
                                    <div className="flex flex-wrap gap-1.5">
                                        {item.features.map((feat, fi) => (
                                            <span key={fi} className="px-2.5 py-1 bg-slate-50 text-slate-500 text-[10px] font-medium rounded-lg border border-slate-100">
                                                {feat}
                                            </span>
                                        ))}
                                    </div>

                                    <button className="px-4 py-2 text-xs font-bold text-blue-600 bg-blue-50 border border-blue-100 rounded-xl hover:bg-blue-100 transition-all duration-300 group-hover:bg-blue-600 group-hover:text-white group-hover:border-blue-600 group-hover:shadow-lg group-hover:shadow-blue-200">
                                        Pesan Sekarang
                                    </button>
                                </div>

                                <div className="h-36 bg-slate-50 overflow-hidden border-t border-slate-100 relative">
                                    <motion.img
                                        src={item.img}
                                        alt={item.name}
                                        className="w-full h-full object-cover transition-transform duration-700 group-hover:scale-110"
                                        loading="lazy"
                                    />
                                    <div className="absolute inset-0 bg-gradient-to-t from-black/20 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500" />
                                </div>
                            </motion.div>
                        );
                    })}
                </StaggerContainer>
            </section>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                WHY CHOOSE US
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <section id="keunggulan" className="py-20 bg-white/60 backdrop-blur-sm border-y border-slate-100 relative z-10">
                <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
                    <RevealSection className="text-center max-w-3xl mx-auto mb-16 space-y-3">
                        <div className="text-xs font-bold uppercase tracking-wider text-blue-600">Standar Tertinggi</div>
                        <h2 className="text-3xl sm:text-4xl font-extrabold text-slate-900">Mengapa Memilih bohAntar?</h2>
                        <p className="text-slate-500 text-sm sm:text-base">Standar layanan terbaik untuk mobilitas Anda di Kalimantan Barat.</p>
                    </RevealSection>

                    <StaggerContainer className="grid grid-cols-1 md:grid-cols-3 gap-6 sm:gap-8">
                        {[
                            { title: 'Aman & Terverifikasi', desc: 'Seluruh mitra pengemudi melewati inspeksi fisik, SIM sah, dan kelayakan jalan resmi.', icon: ShieldCheck, color: 'text-emerald-600 bg-emerald-50 border-emerald-200', glow: 'group-hover:shadow-emerald-200/50' },
                            { title: 'Navigasi Akurat', desc: 'Penentuan titik jemput dan rute tercepat berbasis koordinat GPS satelit real-time.', icon: MapPin, color: 'text-blue-600 bg-blue-50 border-blue-200', glow: 'group-hover:shadow-blue-200/50' },
                            { title: 'Rating Prima', desc: 'Komitmen pelayanan berkualitas tinggi untuk kenyamanan dan keamanan optimal Anda.', icon: Star, color: 'text-amber-500 bg-amber-50 border-amber-200', glow: 'group-hover:shadow-amber-200/50' }
                        ].map((feat, idx) => {
                            const Icon = feat.icon;
                            return (
                                <motion.div
                                    key={idx}
                                    variants={staggerItem}
                                    whileHover={{ y: -6 }}
                                    className={`group p-8 rounded-3xl bg-gradient-to-br from-white to-slate-50/50 border border-slate-100 text-center space-y-5 hover:shadow-xl ${feat.glow} transition-all duration-500`}
                                >
                                    <motion.div
                                        whileHover={{ scale: 1.1, rotate: 5 }}
                                        className={`w-16 h-16 mx-auto rounded-2xl flex items-center justify-center border-2 shadow-sm ${feat.color}`}
                                    >
                                        <Icon className="w-7 h-7" />
                                    </motion.div>
                                    <h3 className="text-lg font-bold text-slate-900">{feat.title}</h3>
                                    <p className="text-sm text-slate-500 leading-relaxed">{feat.desc}</p>
                                </motion.div>
                            );
                        })}
                    </StaggerContainer>
                </div>
            </section>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                PORTAL DASHBOARD CARDS
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <section id="portal" className="py-20 lg:py-28 relative z-10">
                <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
                    <RevealSection className="text-center max-w-3xl mx-auto mb-16 space-y-3">
                        <div className="inline-flex items-center gap-1.5 text-xs font-bold uppercase tracking-wider text-blue-600">
                            <Users className="w-3.5 h-3.5" />
                            <span>Akses Portal Mitra & Manajemen</span>
                        </div>
                        <h2 className="text-3xl sm:text-4xl font-extrabold text-slate-900">Portal Dashboard Admin & Mitra</h2>
                        <p className="text-slate-500 text-sm sm:text-base">Pilih portal untuk masuk ke sistem dashboard manajemen.</p>
                    </RevealSection>

                    <StaggerContainer className="grid grid-cols-1 md:grid-cols-2 gap-6 sm:gap-8 max-w-4xl mx-auto">
                        {portals.map((portal, idx) => {
                            const Icon = portal.icon;
                            return (
                                <motion.div
                                    key={idx}
                                    variants={staggerItem}
                                    whileHover={{ y: -8 }}
                                    className="group bg-white rounded-3xl p-6 sm:p-8 border border-slate-100 shadow-sm hover:shadow-2xl hover:shadow-slate-200/50 flex flex-col justify-between transition-all duration-500"
                                  >
                                      <div className="space-y-5">
                                          <div className="flex justify-between items-start">
                                              <motion.div
                                                  whileHover={{ scale: 1.1, rotate: -5 }}
                                                  className={`w-13 h-13 rounded-2xl bg-gradient-to-br ${portal.color} flex items-center justify-center text-white shadow-lg`}
                                              >
                                                  <Icon className="w-6 h-6" />
                                              </motion.div>
                                              <span className="text-[9px] font-bold uppercase tracking-wider px-3 py-1.5 bg-slate-50 text-slate-600 rounded-full border border-slate-100">
                                                  {portal.badge}
                                              </span>
                                          </div>
                                          <div>
                                              <h3 className="text-xl font-black text-slate-900">{portal.title}</h3>
                                              <p className="text-xs text-slate-500 mt-2 leading-relaxed">{portal.desc}</p>
                                          </div>
                                      </div>
                                      <div className="pt-8">
                                          <MagneticButton
                                              onClick={() => navigate(portal.path)}
                                              className={`w-full py-3.5 px-4 ${portal.btnClass} text-white font-bold text-sm rounded-xl flex items-center justify-center gap-2 shadow-lg transition-all duration-300 cursor-pointer`}
                                          >
                                              <span>Masuk Dashboard</span>
                                              <ExternalLink className="w-4 h-4" />
                                          </MagneticButton>
                                      </div>
                                  </motion.div>
                              );
                          })}
                      </StaggerContainer>
                </div>
            </section>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                FAQ ACCORDION
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <RevealSection>
                <section id="faq" className="py-20 bg-white/60 backdrop-blur-sm border-t border-slate-100 relative z-10">
                    <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
                        <div className="text-center mb-12 space-y-2">
                            <div className="text-xs font-bold uppercase tracking-wider text-blue-600">Pusat Informasi</div>
                            <h2 className="text-3xl font-extrabold text-slate-900">Pertanyaan yang Sering Diajukan</h2>
                        </div>

                        <div className="space-y-3">
                            {faqs.map((faq, idx) => (
                                <motion.div
                                    key={idx}
                                    initial={false}
                                    className="bg-white border border-slate-100 rounded-2xl overflow-hidden shadow-sm hover:shadow-md transition-shadow duration-300"
                                >
                                    <button
                                        onClick={() => setActiveFaq(activeFaq === idx ? null : idx)}
                                        className="w-full p-5 sm:p-6 text-left flex justify-between items-center gap-4 font-semibold text-sm sm:text-base text-slate-800 hover:text-blue-600 transition cursor-pointer"
                                        aria-expanded={activeFaq === idx}
                                    >
                                        <span>{faq.q}</span>
                                        <motion.div
                                            animate={{ rotate: activeFaq === idx ? 180 : 0 }}
                                            transition={{ duration: 0.3 }}
                                        >
                                            <ChevronDown className={`w-5 h-5 flex-shrink-0 ${activeFaq === idx ? 'text-blue-600' : 'text-slate-400'}`} />
                                        </motion.div>
                                    </button>
                                    <AnimatePresence>
                                        {activeFaq === idx && (
                                            <motion.div
                                                initial={{ height: 0, opacity: 0 }}
                                                animate={{ height: 'auto', opacity: 1 }}
                                                exit={{ height: 0, opacity: 0 }}
                                                transition={{ duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
                                                className="overflow-hidden"
                                            >
                                                <div className="px-5 sm:px-6 pb-6 text-sm text-slate-500 leading-relaxed border-t border-slate-100 pt-4">
                                                    {faq.a}
                                                </div>
                                            </motion.div>
                                        )}
                                    </AnimatePresence>
                                </motion.div>
                            ))}
                        </div>
                    </div>
                </section>
            </RevealSection>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                DOWNLOAD CTA BANNER
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <RevealSection>
                <section id="download" className="py-20 px-4 sm:px-6 lg:px-8 max-w-7xl mx-auto relative z-10">
                    <motion.div
                        whileHover={{ scale: 1.005 }}
                        className="relative overflow-hidden bg-gradient-to-r from-blue-600 via-blue-500 to-blue-600 rounded-3xl p-8 sm:p-14 text-white shadow-2xl shadow-blue-500/30"
                    >
                        {/* Animated bg pattern */}
                        <div className="absolute inset-0 opacity-10">
                            <div className="absolute -top-20 -right-20 w-80 h-80 rounded-full bg-white/20 blur-3xl animate-pulse" style={{ animationDuration: '5s' }} />
                            <div className="absolute -bottom-20 -left-20 w-80 h-80 rounded-full bg-white/20 blur-3xl animate-pulse" style={{ animationDuration: '7s' }} />
                        </div>

                        <div className="flex flex-col lg:flex-row items-center justify-between gap-8 relative z-10">
                            <div className="space-y-4 max-w-xl text-center lg:text-left">
                                <span className="text-xs font-bold uppercase tracking-widest text-blue-200">Download Aplikasi Sekarang</span>
                                <h2 className="text-3xl sm:text-4xl font-black leading-tight">
                                    Mulai Perjalanan <br className="hidden sm:inline" />
                                    Pertamamu Bersama bohAntar
                                </h2>
                                <p className="text-blue-200 text-sm leading-relaxed">
                                    Tersedia di Google Play Store dan Apple App Store. Gratis, cepat, dan terpercaya.
                                </p>
                            </div>

                            <div className="flex flex-wrap justify-center gap-4">
                                <MagneticButton className="group px-6 py-4 bg-white text-slate-900 rounded-2xl text-sm font-bold flex items-center gap-3 shadow-xl hover:shadow-2xl transition-all cursor-pointer">
                                    <div className="w-8 h-8 rounded-lg bg-slate-100 flex items-center justify-center">
                                        <Play className="w-4 h-4 text-slate-700 fill-slate-700" />
                                    </div>
                                    <div className="text-left">
                                        <div className="text-[9px] text-slate-500 font-medium uppercase tracking-wider">Dapatkan di</div>
                                        <div className="text-sm font-black">Google Play</div>
                                    </div>
                                </MagneticButton>

                                <MagneticButton className="group px-6 py-4 bg-slate-900 text-white rounded-2xl text-sm font-bold flex items-center gap-3 shadow-xl hover:shadow-2xl transition-all cursor-pointer border border-white/10">
                                    <div className="w-8 h-8 rounded-lg bg-white/10 flex items-center justify-center">
                                        <Smartphone className="w-4 h-4 text-white" />
                                    </div>
                                    <div className="text-left">
                                        <div className="text-[9px] text-slate-400 font-medium uppercase tracking-wider">Unduh dari</div>
                                        <div className="text-sm font-black">App Store</div>
                                    </div>
                                </MagneticButton>
                            </div>
                        </div>
                    </motion.div>
                </section>
            </RevealSection>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                FOOTER
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <footer className="bg-slate-900 text-slate-400 pt-16 pb-10 border-t border-slate-800 relative z-10">
                <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
                    <div className="grid grid-cols-1 md:grid-cols-4 gap-10 mb-12">
                        {/* Brand */}
                        <div className="space-y-4">
                            <div className="bg-white px-3.5 py-1.5 rounded-xl inline-flex items-center shadow-sm">
                                <img 
                                    src={logoImg} 
                                    alt="bohAntar Logo" 
                                    className="h-7 w-auto object-contain"
                                />
                            </div>
                            <p className="text-slate-500 leading-relaxed text-xs">
                                Platform mobilitas, ekspedisi instan, dan logistik digital terdepan di Kalimantan Barat.
                            </p>
                        </div>

                        {/* Links columns */}
                        {[
                            {
                                title: 'Layanan', links: [
                                    { label: 'bohRide (Ojek Motor)', href: '#layanan' },
                                    { label: 'bohCar (Taksi Mobil)', href: '#layanan' },
                                    { label: 'bohSend (Kurir Instan)', href: '#layanan' },
                                    { label: 'bohFood (Kuliner Kalbar)', href: '#layanan' },
                                    { label: 'bohRental (Sewa Mobil)', href: '#layanan' },
                                ]
                            },
                            {
                                title: 'Kemitraan', links: [
                                    { label: 'Mitra Merchant Food', onClick: () => navigate('/login-resto') },
                                    { label: 'Mitra Rental Mobil', onClick: () => navigate('/login-rental') },
                                    { label: 'Pendaftaran Driver', href: '#portal' },
                                ]
                            },
                            {
                                title: 'Bantuan & Legal', links: [
                                    { label: 'FAQ & Pusat Bantuan', href: '#faq' },
                                    { label: 'Syarat & Ketentuan', href: '#' },
                                    { label: 'Kebijakan Privasi', href: '#' },
                                    { label: 'Hubungi Kami', href: '#' },
                                ]
                            }
                        ].map((col, ci) => (
                            <div key={ci} className="space-y-3">
                                <div className="font-bold text-white text-xs uppercase tracking-wider">{col.title}</div>
                                <ul className="space-y-2">
                                    {col.links.map((link, li) => (
                                        <li key={li}>
                                            {link.onClick ? (
                                                <button onClick={link.onClick} className="text-xs text-slate-500 hover:text-white transition-colors cursor-pointer text-left">
                                                    {link.label}
                                                </button>
                                            ) : (
                                                <a href={link.href} className="text-xs text-slate-500 hover:text-white transition-colors">
                                                    {link.label}
                                                </a>
                                            )}
                                        </li>
                                    ))}
                                </ul>
                            </div>
                        ))}
                    </div>

                    {/* Copyright */}
                    <div className="pt-8 border-t border-slate-800/60 flex flex-col sm:flex-row justify-between items-center gap-4 text-xs text-slate-600">
                        <div>&copy; 2026 <strong className="text-slate-400">bohAntar</strong>. Seluruh hak cipta dilindungi.</div>
                        <div className="flex items-center gap-1.5">
                            <span>Dibuat dengan</span>
                            <motion.span animate={{ scale: [1, 1.2, 1] }} transition={{ repeat: Infinity, duration: 1.5 }}>â¤ï¸</motion.span>
                            <span>untuk Kalimantan Barat</span>
                        </div>
                    </div>
                </div>
            </footer>


            {/* â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
                GLOBAL STYLES (injected)
            â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â• */}
            <style>{`
                @keyframes shimmer {
                    0% { background-position: 200% center; }
                    100% { background-position: -200% center; }
                }
                html { scroll-behavior: smooth; }
            `}</style>

        </div>
    );
}
