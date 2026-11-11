// Service worker dashboard — hanya untuk Web Push (chat penyewa, dll.) dari
// backend/webpush.go. Tidak meng-cache apa pun.
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data.json(); } catch { /* push tanpa isi */ }
  const data = d.data || {};
  e.waitUntil(self.registration.showNotification(d.title || "BohAntar", {
    body: d.body || "Ada kabar baru di dashboard",
    icon: "/favicon-192.png",
    // Pesan berikutnya di sewa yang sama menggantikan notifikasi lama, tapi tetap berbunyi.
    tag: data.booking_id ? "sewa-" + data.booking_id : undefined,
    renotify: !!data.booking_id,
    data,
  }));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  // Chat → langsung ke percakapan sewanya; booking baru → Pesanan Masuk.
  const d = e.notification.data || {};
  const url = "/#" + (d.tipe === "chat_sewa" ? "/chat" + (d.booking_id ? "/" + encodeURIComponent(d.booking_id) : "")
    : d.tipe === "sewa_baru" ? "/orders" : "/");
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((ws) =>
    ws[0] ? ws[0].focus().then((w) => w.navigate(url)).catch(() => self.clients.openWindow(url))
          : self.clients.openWindow(url)));
});
