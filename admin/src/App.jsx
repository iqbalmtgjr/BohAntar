import { useState, useEffect } from "react";
import { HashRouter, Routes, Route, Navigate } from "react-router-dom";
import "./index.css";
import "./portal-mobile.css";
import { BASE, authFetch, getToken, setToken, clearToken, loginRouteFor } from "./api";

import LoginPage from "./pages/LoginPage";
import LandingPage from "./pages/LandingPage";
import PortalMitraPage from "./pages/PortalMitraPage";
import AuthCallbackPage from "./pages/AuthCallbackPage";
import PartnerRegisterPage from "./pages/PartnerRegisterPage";
import PartnerApplicationsPage from "./pages/PartnerApplicationsPage";
import ApprovedPartnersPage from "./pages/ApprovedPartnersPage";
import AccountPage from "./pages/AccountPage";


// Admin pages
import DashboardPage from "./pages/DashboardPage";
import UsersPage from "./pages/UsersPage";
import OrdersPage from "./pages/OrdersPage";
import AnalyticsPage from "./pages/AnalyticsPage";
import TarifPage from "./pages/TarifPage";
import KomisiPage from "./pages/KomisiPage";
import DriverRegistPage from "./pages/DriverRegistPage";
import ApplicationsPage from "./pages/ApplicationsPage";
import PaymentReportRental from "./pages/PaymentReportRental";
import Sidebar from "./components/Sidebar";
import PortalTopbar from "./components/PortalTopbar";

// Rental pages
import RentalDashboard from "./pages/bohrental/RentalDashboard";
import CarManagement from "./pages/bohrental/CarManagement";
import RentalCalendar from "./pages/bohrental/RentalCalendar";
import ServiceManagement from "./pages/bohrental/ServiceManagement";
import RentalOrders from "./pages/bohrental/RentalOrders";
import RentalReports from "./pages/bohrental/RentalReports";
import Subscription from "./pages/bohrental/Subscription";
import SidebarRentalPartner from "./components/SidebarRentalPartner";

// Food pages
import FoodDashboard from "./pages/bohfood/FoodDashboard";
import MenuManagement from "./pages/bohfood/MenuManagement";
import SidebarFoodMerchant from "./components/SidebarFoodMerchant";

function Layout({ children, portalType, onLogout, userPhone }) {
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

  const logout = () => {
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
        <Routes>
          <Route path="/" element={<LandingPage />} />
          <Route path="/portal-mitra" element={<PortalMitraPage />} />
          <Route path="/login-resto" element={<LoginPage onLogin={login} role="food" />} />
          <Route path="/login-rental" element={<LoginPage onLogin={login} role="rental" />} />
          <Route path="/super-admin-login" element={<LoginPage onLogin={login} role="admin" />} />
          <Route path="/auth/callback" element={<AuthCallbackPage onLogin={login} />} />
          <Route path="/register-partner" element={<PartnerRegisterPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
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
        <Route path="/komisi" element={<KomisiPage />} />
        <Route path="/driver-register" element={<DriverRegistPage />} />
        <Route path="/applications" element={<ApplicationsPage />} />
        <Route path="/partner-applications" element={<PartnerApplicationsPage />} />
        <Route path="/approved-partners" element={<ApprovedPartnersPage />} />
        <Route path="/payment-reports/rental" element={<PaymentReportRental />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    );
  };

  return (
    <HashRouter>
      <Layout portalType={portalType} onLogout={logout} userPhone={userPhone}>
        {renderRoutes()}
      </Layout>
    </HashRouter>
  );
}
