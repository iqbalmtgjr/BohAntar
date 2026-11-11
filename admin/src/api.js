export const BASE = import.meta.env.VITE_API_URL || (typeof window !== 'undefined' && (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') ? 'http://localhost:8080/api' : '/api');

const TOKEN_KEY = "auth_token";

export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (t) => localStorage.setItem(TOKEN_KEY, t);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

// Sesi super admin yang disimpan saat admin masuk ke akun mitra ({token, phone}),
// supaya bisa kembali tanpa login ulang.
export const ADMIN_BALIK_KEY = "admin_balik";

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
  localStorage.removeItem(ADMIN_BALIK_KEY);
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

// Foto dari HP bisa 3–5 MB dan 4000 px, padahal paling lebar tampil selebar
// layar HP. Dikecilkan di browser (kanvas) sebelum dikirim: unggahnya cepat,
// dan aplikasi pemesan tidak mengunduh megabita untuk satu kartu menu. PDF,
// HEIC, dan gambar yang sudah kecil dikirim apa adanya; gagal = kirim aslinya.
const SISI_MAKS = 1600;
export async function kecilkanGambar(file) {
  if (!/^image\/(jpeg|png|webp)$/.test(file?.type || "")) return file;
  try {
    const bmp = await createImageBitmap(file, { imageOrientation: "from-image" }); // ikut putaran EXIF foto HP
    const skala = Math.min(1, SISI_MAKS / Math.max(bmp.width, bmp.height));
    if (skala === 1 && file.size <= 500 * 1024) return file;
    const kanvas = document.createElement("canvas");
    kanvas.width = Math.round(bmp.width * skala);
    kanvas.height = Math.round(bmp.height * skala);
    const ctx = kanvas.getContext("2d");
    ctx.fillStyle = "#fff"; // PNG transparan jadi berlatar putih, bukan hitam
    ctx.fillRect(0, 0, kanvas.width, kanvas.height);
    ctx.drawImage(bmp, 0, 0, kanvas.width, kanvas.height);
    const blob = await new Promise((r) => kanvas.toBlob(r, "image/jpeg", 0.85));
    if (!blob || blob.size >= file.size) return file;
    return new File([blob], file.name.replace(/\.[^.]*$/, "") + ".jpg", { type: "image/jpeg" });
  } catch {
    return file;
  }
}

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
  // Pratinjau untuk angka yang belum disimpan. Rumusnya ada di backend supaya
  // kolom contoh di halaman tarif tidak pernah menghitung versinya sendiri.
  contohTarif: (data) => post(`/admin/tarif/contoh`, data),
  getPemakaianPeta: () => json(`/admin/peta/pemakaian`),
  // Kelola menu warung BohFood (backend/menu_warung.go). Balasan galat
  // membawa `error`; menu yang disimpan dikembalikan apa adanya.
  getMenuSemua: (mid) => json(`/food/menus?merchant_id=${mid}&semua=1`),
  simpanMenu: (data) => post(`/food/menus`, data),
  statusMenu: (id, data) => post(`/food/menus/${id}/status`, data),
  hapusMenu: (id) => json(`/food/menus/${id}`, { method: "DELETE" }),
  getKategori: (mid) => json(`/food/kategori?merchant_id=${mid}`),
  simpanKategori: (data) => post(`/food/kategori`, data),
  urutkanKategori: (mid, ids) => post(`/food/kategori/urutan`, { merchant_id: mid, ids }),
  hapusKategori: (id) => json(`/food/kategori/${id}`, { method: "DELETE" }),
  getVarian: (mid) => json(`/food/varian?merchant_id=${mid}`),
  simpanVarian: (data) => post(`/food/varian`, data),
  hapusVarian: (id) => json(`/food/varian/${id}`, { method: "DELETE" }),
  // Impor Excel (backend/menu_impor.go): simpan=false = pratinjau saja.
  templateImporMenu: () => authFetch(`${BASE}/food/menu-impor/template`).then((r) => { if (!r.ok) throw new Error("Gagal mengunduh template"); return r.blob(); }),
  imporMenu: (mid, berkas, simpan, perbarui) => {
    const fd = new FormData();
    fd.append("merchant_id", mid);
    fd.append("berkas", berkas);
    fd.append("simpan", simpan ? "1" : "0");
    fd.append("perbarui", perbarui ? "1" : "0");
    return json(`/food/menu-impor`, { method: "POST", body: fd });
  },
  // Pantau driver online + pesanan manual (backend/dispatch.go).
  getDriverOnline: () => json(`/admin/driver-online`),
  buatPesananManual: (data) => post(`/admin/pesanan-manual`, data),
  tujukanPesanan: (orderId, driverPhone) => post(`/admin/pesanan-tujukan`, { order_id: orderId, driver_phone: driverPhone }),
  cariAlamat: (q, sesi) => json(`/maps/autocomplete?q=${encodeURIComponent(q)}&lat=0.0785&lng=111.494&session=${sesi}`),
  detailTempat: (id, sesi) => json(`/maps/place?place_id=${encodeURIComponent(id)}&session=${sesi}`),
  estimasiTarif: (layanan, a, b) => json(`/tarif/estimasi?layanan=${layanan}&from_lat=${a.lat}&from_lng=${a.lng}&to_lat=${b.lat}&to_lng=${b.lng}`),
  // Banner beranda aplikasi. Id ada = ubah, kosong = banner baru.
  getBanner: () => json(`/admin/banner`),
  simpanBanner: (b) => b.id
    ? json(`/admin/banner/${b.id}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) })
    : post(`/admin/banner`, b),
  hapusBanner: (id) => json(`/admin/banner/${id}`, { method: "DELETE" }),
  // Voucher diskon, terpakai otomatis di aplikasi (backend/voucher.go).
  getVoucher: () => json(`/admin/voucher`),
  simpanVoucher: (v) => v.id
    ? json(`/admin/voucher/${v.id}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(v) })
    : post(`/admin/voucher`, v),
  hapusVoucher: (id) => json(`/admin/voucher/${id}`, { method: "DELETE" }),
  getApplications: (status) => json(`/admin/applications${status ? "?status=" + status : ""}`),
  registerDriver: (data) => post(`/admin/drivers/register`, data),
  // Content-Type sengaja tidak diset supaya browser menulis boundary multipart-nya sendiri.
  uploadFile: async (file) => {
    const fd = new FormData();
    fd.append("file", await kecilkanGambar(file));
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
  masukSebagai: (phone) => post(`/admin/masuk-sebagai`, { phone }),
  webPushKunci: () => json(`/webpush/kunci`),
  webPushLangganan: (sub) => post(`/webpush/langganan`, sub),
  approvePartner: (id) => json(`/admin/partner-applications/${id}/approve`, { method: "POST" }),
  rejectPartner: (id) => json(`/admin/partner-applications/${id}/reject`, { method: "POST" }),
  login: (email, password) => post(`/auth/login`, { email, password }),
  googleLogin: (idToken, nonce, extra = {}) => post(`/auth/google`, { id_token: idToken, nonce, ...extra }),
  updateUser: (phone, data) => json(`/admin/users/${phone.replace("+", "")}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }),
  // Tanpa parameter phone: backend memakai identitas pemanggil dari token.
  getSubscriptionStatus: () => json(`/subscription/status`),
  getRentalBookings: () => json(`/rental/bookings`),
  getProfile: () => json(`/users/profile`),
  // Pengajuan pencairan ditutup 31 Okt 2026; super admin tinggal menuntaskan
  // yang sudah menunggu. Saldonya sudah dipotong backend saat pengajuan lahir.
  adminPencairan: (status) => json(`/admin/pencairan?status=${status}`),
  prosesPencairan: (id, aksi, catatan) => post(`/admin/pencairan/${id}/${aksi}`, { catatan }),
  updateProfile: (data) => json(`/users/profile`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }),
};
