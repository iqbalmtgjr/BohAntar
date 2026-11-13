import { useState, useEffect, lazy, Suspense } from "react";
import { HashRouter, Routes, Route, Navigate } from "react-router-dom";
import "./index.css";
import "./portal-mobile.css";
import { BASE, authFetch, getToken, setToken, clearToken, loginRouteFor, ADMIN_BALIK_KEY } from "./api";
import { lepasLangganan } from "./webpush";

// Halaman depan dimuat langsung; halaman lain dipecah jadi berkas sendiri dan
// baru diunduh saat dibuka. Tanpa ini pengunjung halaman depan ikut mengunduh
// seluruh panel admin — grafik (recharts), peta (leaflet), dan semua halamannya.
import LandingPage from "./pages/LandingPage";
const LoginPage = lazy(() => import("./pages/LoginPage"));
const PortalMitraPage = lazy(() => import("./pages/PortalMitraPage"));
const PartnerRegisterPage = lazy(() => import("./pages/PartnerRegisterPage"));
const PartnerApplicationsPage = lazy(() => import("./pages/PartnerApplicationsPage"));
const ApprovedPartnersPage = lazy(() => import("./pages/ApprovedPartnersPage"));
const AccountPage = lazy(() => import("./pages/AccountPage"));

// Admin pages
const DashboardPage = lazy(() => import("./pages/DashboardPage"));
const UsersPage = lazy(() => import("./pages/UsersPage"));
const OrdersPage = lazy(() => import("./pages/OrdersPage"));
const AnalyticsPage = lazy(() => import("./pages/AnalyticsPage"));
const TarifPage = lazy(() => import("./pages/TarifPage"));
const PetaPage = lazy(() => import("./pages/PetaPage"));
const DriverOnlinePage = lazy(() => import("./pages/DriverOnlinePage"));
const BannerPage = lazy(() => import("./pages/BannerPage"));
const VoucherPage = lazy(() => import("./pages/VoucherPage"));
const KomisiPage = lazy(() => import("./pages/KomisiPage"));
const PencairanPage = lazy(() => import("./pages/PencairanPage"));
const DriverRegistPage = lazy(() => import("./pages/DriverRegistPage"));
const ApplicationsPage = lazy(() => import("./pages/ApplicationsPage"));
const PaymentReportRental = lazy(() => import("./pages/PaymentReportRental"));
const BeralihAkunPage = lazy(() => import("./pages/BeralihAkunPage"));
import Sidebar from "./components/Sidebar";
import PortalTopbar from "./components/PortalTopbar";

// Rental pages
const RentalDashboard = lazy(() => import("./pages/bohrental/RentalDashboard"));
const CarManagement = lazy(() => import("./pages/bohrental/CarManagement"));
const RentalCalendar = lazy(() => import("./pages/bohrental/RentalCalendar"));
const ServiceManagement = lazy(() => import("./pages/bohrental/ServiceManagement"));
const RentalOrders = lazy(() => import("./pages/bohrental/RentalOrders"));
const RentalReports = lazy(() => import("./pages/bohrental/RentalReports"));
const RentalChat = lazy(() => import("./pages/bohrental/RentalChat"));
const Subscription = lazy(() => import("./pages/bohrental/Subscription"));
import SidebarRentalPartner from "./components/SidebarRentalPartner";

// Food pages
const FoodDashboard = lazy(() => import("./pages/bohfood/FoodDashboard"));
const MenuManagement = lazy(() => import("./pages/bohfood/MenuManagement"));
import SidebarFoodMerchant from "./components/SidebarFoodMerchant";

const memuat = <div className="loading-overlay" style={{ minHeight: "60vh" }} role="status" aria-label="Memuat"><div className="spinner" /></div>;

function Layout({ children, portalType, onLogout, userPhone, onKembali }) {
  // Select which sidebar to show based on portalType
  const renderSidebar = () => {
    if (portalType === "food") {
      return <SidebarFoodMerchant onLogout={onLogout} />;
    }
    if (portalType === "rental") {
      return <SidebarRentalPartner onLogout={onLogout} />;
    }
    return <Sidebar onLogout={onLogout} />; // Default is Super Admin sidebar
  };

  return (
    <div className={`layout portal-ui ${
      portalType === "rental" ? "rental-portal" :
      portalType === "food" ? "food-portal" : "admin-portal"
    }`}>
      {renderSidebar()}
      <main className="main-content">
        {onKembali && (
          <div role="status" style={{ display: "flex", flexWrap: "wrap", alignItems: "center", justifyContent: "space-between", gap: 8, padding: "8px 16px", background: "#f59e0b", color: "#1f2937", fontSize: 13, fontWeight: 600 }}>
            <span>Super Admin sedang masuk sebagai mitra {userPhone}. Semua perubahan tersimpan di akun mitra ini.</span>
            <button className="btn" onClick={onKembali} style={{ padding: "4px 12px", fontSize: 13, height: "auto", background: "#1f2937", color: "#fff" }}>
              Kembali ke Super Admin
            </button>
          </div>
        )}
        {/* portal mitra tidak memakai Topbar admin, jadi dipasang topbar sendiri */}
        {(portalType === "rental" || portalType === "food") && (
          <PortalTopbar portalType={portalType} userPhone={userPhone} />
        )}
        {children}
      </main>
    </div>
  );
}

export default function App() {
  const [auth, setAuth] = useState(() => !!getToken());
  const [portalType, setPortalType] = useState(() => localStorage.getItem("portal_type") || "admin");
  const [userPhone, setUserPhone] = useState(() => localStorage.getItem("user_phone") || "");
  const [subStatus, setSubStatus] = useState("TRIAL");

  // Semua panel default terang; kalau pengguna pernah memilih tema, pilihannya
  // dihormati. Atributnya selalu ditulis eksplisit supaya ThemeToggle tidak
  // menebak "dark" saat atributnya kosong sementara tampilannya sudah terang.
  useEffect(() => {
    document.documentElement.setAttribute(
      "data-theme",
      localStorage.getItem("admin_theme") || "light"
    );
  }, []);

  useEffect(() => {
    const checkSubStatus = () => {
      if (auth && portalType === "rental" && userPhone) {
        authFetch(`${BASE}/subscription/status?phone=${encodeURIComponent(userPhone)}`)
          .then(r => r.json())
          .then(data => {
            if (data && data.status) {
              setSubStatus(data.status);
            }
          })
          .catch(err => console.error("Gagal memuat status langganan:", err));
      }
    };

    checkSubStatus();

    // Dengarkan perubahan rute hash secara real-time
    window.addEventListener("hashchange", checkSubStatus);
    return () => {
      window.removeEventListener("hashchange", checkSubStatus);
    };
  }, [auth, portalType, userPhone]);

  const login = (type, phone, token) => {
    setToken(token);
    localStorage.setItem("portal_type", type);
    localStorage.setItem("user_phone", phone);
    setAuth(true);
    setPortalType(type);
    setUserPhone(phone);
  };

  // Admin masuk ke akun mitra: sesi admin disimpan dulu supaya bisa kembali.
  const masukSebagai = (type, phone, token) => {
    localStorage.setItem(ADMIN_BALIK_KEY, JSON.stringify({ token: getToken(), phone: userPhone }));
    login(type, phone, token);
    window.location.hash = "/";
  };

  const balik = (() => {
    try { return JSON.parse(localStorage.getItem(ADMIN_BALIK_KEY)); } catch { return null; }
  })();

  const kembaliKeAdmin = () => {
    localStorage.removeItem(ADMIN_BALIK_KEY);
    login("admin", balik.phone, balik.token);
    window.location.hash = "/";
  };

  const logout = () => {
    // Keluar dari portal mitra yang dibuka admin = kembali ke Super Admin.
    if (balik && portalType !== "admin") return kembaliKeAdmin();
    localStorage.removeItem(ADMIN_BALIK_KEY);
    lepasLangganan();
    // Rute tujuan ditentukan sebelum portalType dibersihkan.
    const target = loginRouteFor(portalType);
    clearToken();
    localStorage.removeItem("portal_type");
    localStorage.removeItem("user_phone");
    setAuth(false);
    setPortalType("admin");
    setUserPhone("");
    window.location.hash = target;
  };

  if (!auth) {
    return (
      <HashRouter>
        <Suspense fallback={memuat}>
          <Routes>
            <Route path="/" element={<LandingPage />} />
            <Route path="/portal-mitra" element={<PortalMitraPage />} />
            <Route path="/login-resto" element={<LoginPage onLogin={login} role="food" />} />
            <Route path="/login-rental" element={<LoginPage onLogin={login} role="rental" />} />
            <Route path="/super-admin-login" element={<LoginPage onLogin={login} role="admin" />} />
            <Route path="/register-partner" element={<PartnerRegisterPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </Suspense>
      </HashRouter>
    );
  }

  // Select routes based on portalType
  const renderRoutes = () => {
    if (portalType === "food") {
      return (
        <Routes>
          <Route path="/" element={<FoodDashboard ownerPhone={userPhone} />} />
          <Route path="/menu" element={<MenuManagement ownerPhone={userPhone} />} />
          <Route path="/account" element={<AccountPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      );
    }
    if (portalType === "rental") {
      const isExpired = subStatus === "EXPIRED";
      if (isExpired) {
        return (
          <Routes>
            <Route path="/subscription" element={<Subscription ownerPhone={userPhone} />} />
            {/* Langganan habis tetap boleh urus akun sendiri, terutama ganti password. */}
            <Route path="/account" element={<AccountPage />} />
            <Route path="*" element={<Navigate to="/subscription" replace />} />
          </Routes>
        );
      }
      return (
        <Routes>
          <Route path="/" element={<RentalDashboard ownerPhone={userPhone} />} />
          <Route path="/cars" element={<CarManagement ownerPhone={userPhone} />} />
          <Route path="/calendar" element={<RentalCalendar ownerPhone={userPhone} />} />
          <Route path="/services" element={<ServiceManagement />} />
          <Route path="/orders" element={<RentalOrders ownerPhone={userPhone} />} />
          <Route path="/reports" element={<RentalReports ownerPhone={userPhone} />} />
          <Route path="/chat/:id?" element={<RentalChat ownerPhone={userPhone} />} />
          <Route path="/subscription" element={<Subscription ownerPhone={userPhone} />} />
          <Route path="/account" element={<AccountPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      );
    }
    // Super Admin Routes (Original)
    return (
      <Routes>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/users" element={<UsersPage />} />
        <Route path="/orders" element={<OrdersPage />} />
        <Route path="/analytics" element={<AnalyticsPage />} />
        <Route path="/tarif" element={<TarifPage />} />
        <Route path="/peta" element={<PetaPage />} />
        <Route path="/driver-online" element={<DriverOnlinePage />} />
        <Route path="/banner" element={<BannerPage />} />
        <Route path="/voucher" element={<VoucherPage />} />
        <Route path="/komisi" element={<KomisiPage />} />
        <Route path="/pencairan" element={<PencairanPage />} />
        <Route path="/driver-register" element={<DriverRegistPage />} />
        <Route path="/applications" element={<ApplicationsPage />} />
        <Route path="/partner-applications" element={<PartnerApplicationsPage />} />
        <Route path="/approved-partners" element={<ApprovedPartnersPage />} />
        <Route path="/payment-reports/rental" element={<PaymentReportRental />} />
        <Route path="/beralih-akun" element={<BeralihAkunPage onMasuk={masukSebagai} />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    );
  };

  return (
    <HashRouter>
      <Layout portalType={portalType} onLogout={logout} userPhone={userPhone}
        onKembali={balik && portalType !== "admin" ? kembaliKeAdmin : null}>
        <Suspense fallback={memuat}>{renderRoutes()}</Suspense>
      </Layout>
    </HashRouter>
  );
}
