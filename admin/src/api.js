export const BASE = import.meta.env.VITE_API_URL || (typeof window !== 'undefined' && (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') ? 'http://localhost:8080/api' : '/api');

const TOKEN_KEY = "auth_token";

export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (t) => localStorage.setItem(TOKEN_KEY, t);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

// Rute login yang sesuai dengan portal yang sedang dipakai, supaya setelah keluar
// pengguna kembali ke pintu masuk portalnya sendiri, bukan ke landing page umum.
export const loginRouteFor = (portalType) =>
  portalType === "food" ? "/login-resto"
  : portalType === "rental" ? "/login-rental"
  : "/super-admin-login";

// Token kedaluwarsa atau dicabut: bersihkan sesi dan kembalikan ke halaman login.
// Sekali jalan saja: satu halaman biasanya menembak beberapa endpoint sekaligus
// (Promise.all di dashboard, polling notifikasi, hashchange), jadi 401-nya datang
// berbarengan. Tanpa penjaga ini panggilan kedua membaca portal_type yang sudah
// dihapus panggilan pertama, lalu menimpa hash-nya dengan /super-admin-login.
let sessionExpiredHandled = false;
function sessionExpired() {
  if (sessionExpiredHandled) return;
  sessionExpiredHandled = true;
  const portalType = localStorage.getItem("portal_type");
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem("admin_auth");
  localStorage.removeItem("portal_type");
  localStorage.removeItem("user_phone");
  window.location.hash = loginRouteFor(portalType);
  window.location.reload();
}

// authFetch punya signature yang sama dengan fetch, hanya menyisipkan token.
export async function authFetch(url, opts = {}) {
  const headers = { ...(opts.headers || {}) };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(url, { ...opts, headers });
  // Endpoint login: 401 berarti kredensial salah, bukan sesi kedaluwarsa,
  // jadi jangan lempar pengguna ke rute login portal lain.
  if (res.status === 401 && !url.includes("/auth/")) sessionExpired();
  return res;
}

const json = (path, opts) => authFetch(`${BASE}${path}`, opts).then(r => r.json());

// Backend mengembalikan "/uploads/xxx"; BASE berakhiran "/api" yang harus dilepas.
export const fileURL = (path) => (path ? BASE.replace(/\/api$/, "") + path : "");
const post = (path, data) => json(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) });

export const api = {
  getUsers: (role, page = 1, limit = 10) => json(`/admin/users?role=${role || ""}&page=${page}&limit=${limit}`),
  getUserDetail: (phone) => json(`/admin/users/${phone.replace("+", "")}`),
  getOrders: (params = {}) => {
    const q = new URLSearchParams(params).toString();
    return json(`/admin/orders${q ? "?" + q : ""}`);
  },
  getKomisi: (from, to) => json(`/admin/komisi?from=${from}&to=${to}`),
  buatSetoran: (driverPhone, amount) => post(`/admin/setoran`, { driver_phone: driverPhone, amount }),
  cekSetoran: (id) => json(`/admin/setoran?id=${encodeURIComponent(id)}`),
  // QR-nya digambar server dan endpointnya butuh token admin, jadi tidak bisa
  // dipasang langsung sebagai src <img>; diambil sebagai blob lalu jadi objectURL.
  qrSetoran: (id) => authFetch(`${BASE}/admin/setoran/qr/${id}`).then(r => r.blob()).then(b => URL.createObjectURL(b)),
  getAnalytics: () => json(`/admin/analytics`),
  getTarif: () => json(`/admin/tarif`),
  saveTarif: (data) => json(`/admin/tarif`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }),
  getApplications: (status) => json(`/admin/applications${status ? "?status=" + status : ""}`),
  registerDriver: (data) => post(`/admin/drivers/register`, data),
  // Content-Type sengaja tidak diset supaya browser menulis boundary multipart-nya sendiri.
  uploadFile: (file) => {
    const fd = new FormData();
    fd.append("file", file);
    return json(`/upload`, { method: "POST", body: fd });
  },
  approveDriver: (id) => json(`/admin/drivers/${id}/approve`, { method: "POST" }),
  rejectDriver: (id) => json(`/admin/drivers/${id}/reject`, { method: "POST" }),
  deleteUser: (phone) => json(`/admin/users/${phone.replace("+", "")}`, { method: "DELETE" }),
  registerPartner: (data) => post(`/partner/register`, data),
  getPartnerApplications: (params = {}) => {
    const q = new URLSearchParams(params).toString();
    return json(`/admin/partner-applications${q ? "?" + q : ""}`);
  },
  approvePartner: (id) => json(`/admin/partner-applications/${id}/approve`, { method: "POST" }),
  rejectPartner: (id) => json(`/admin/partner-applications/${id}/reject`, { method: "POST" }),
  login: (email, password) => post(`/auth/login`, { email, password }),
  googleLogin: (idToken, nonce, extra = {}) => post(`/auth/google`, { id_token: idToken, nonce, ...extra }),
  updateUser: (phone, data) => json(`/admin/users/${phone.replace("+", "")}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }),
  // Tanpa parameter phone: backend memakai identitas pemanggil dari token.
  getSubscriptionStatus: () => json(`/subscription/status`),
  getRentalBookings: () => json(`/rental/bookings`),
  getProfile: () => json(`/users/profile`),
  updateProfile: (data) => json(`/users/profile`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }),
};
