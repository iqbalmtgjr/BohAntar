import { api, ADMIN_BALIK_KEY } from "./api";

/* Web Push dashboard mitra: browser menampilkan notifikasi sistem (chat
   penyewa, dll.) walau tab dashboard tertutup. Pasangannya backend/webpush.go
   dan public/sw.js. iPhone hanya mendukungnya untuk situs yang ditambahkan ke
   Layar Utama, jadi di Safari biasa pushDidukung() bernilai false. */

export const pushDidukung = () =>
  "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

// Admin yang sedang "Masuk Akun Mitra" tidak boleh berlangganan atas nama mitra.
export const sedangDimasukiAdmin = () => !!localStorage.getItem(ADMIN_BALIK_KEY);

const keBytes = (b64) => Uint8Array.from(atob(b64.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function langganan() {
  const reg = await navigator.serviceWorker.register("/sw.js");
  await navigator.serviceWorker.ready;
  const { kunci, error } = await api.webPushKunci();
  if (!kunci) throw new Error(error || "Notifikasi belum aktif di server");
  const k = keBytes(kunci);
  let sub = await reg.pushManager.getSubscription();
  // Kunci server berganti (vapid.pem baru): langganan lama tidak diterima lagi.
  const lama = sub && new Uint8Array(sub.options.applicationServerKey || []);
  if (lama && (lama.length !== k.length || lama.some((x, i) => x !== k[i]))) {
    await sub.unsubscribe();
    sub = null;
  }
  sub ||= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: k });
  const res = await api.webPushLangganan(sub.toJSON());
  if (res.status !== "success") throw new Error(res.error || "Gagal menyimpan langganan notifikasi");
}

// Dari ketukan pengguna: Safari/Firefox hanya mau meminta izin lewat ketukan.
export async function nyalakanNotifikasi() {
  if ((await Notification.requestPermission()) !== "granted") {
    throw new Error("Izin notifikasi ditolak. Izinkan lewat ikon gembok di samping alamat situs.");
  }
  await langganan();
}

// Tiap dashboard dibuka: perbarui langganan kalau izinnya sudah ada.
export function segarkanLangganan() {
  if (pushDidukung() && Notification.permission === "granted" && !sedangDimasukiAdmin()) langganan().catch(() => {});
}

// Keluar: browser ini berhenti menerima notifikasi akun tadi. Baris di server
// terhapus sendiri saat push berikutnya dijawab 410 oleh layanan push.
export function lepasLangganan() {
  navigator.serviceWorker?.getRegistration()
    .then((r) => r?.pushManager.getSubscription())
    .then((s) => s?.unsubscribe())
    .catch(() => {});
}
