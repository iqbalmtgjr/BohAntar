// Tarik layar ke bawah untuk memuat ulang. Hanya saat dibuka dari ikon layar utama
// (standalone), karena di situ browser tidak menyediakan gerakan ini; di tab biasa
// browser sudah punya sendiri.
// ponytail: memuat ulang seluruh halaman seperti tarik-segarkan bawaan browser, bukan ambil ulang data per halaman.
const AMBANG = 70; // px tarikan (setelah diredam) sampai dilepas = muat ulang

const standalone = () =>
  matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

// Tolak bila jari mulai di peta, di lapisan fixed (modal, topbar, menu bawah),
// atau di dalam kotak gulir yang belum di posisi paling atas (mis. isi chat).
function bolehTarik(el) {
  if (window.scrollY > 0) return false;
  for (; el && el !== document.body; el = el.parentElement) {
    if (el.scrollTop > 0 || el.classList.contains("leaflet-container")) return false;
    if (getComputedStyle(el).position === "fixed") return false;
  }
  return true;
}

const ikon = document.createElement("div");
ikon.setAttribute("aria-hidden", "true");
ikon.textContent = "↻";
ikon.style.cssText =
  "position:fixed;left:50%;top:calc(env(safe-area-inset-top) + 10px);z-index:10002;" +
  "width:38px;height:38px;margin-left:-19px;border-radius:50%;display:flex;align-items:center;" +
  "justify-content:center;font:700 20px/1 system-ui,sans-serif;color:#0040E8;background:#fff;" +
  "box-shadow:0 4px 14px rgba(0,0,0,.18);pointer-events:none;opacity:0;transform:translateY(-60px)";

let awal = null; // clientY saat jari mulai, null = tidak sedang menarik
let tarik = 0;

function atur(jarak, putar, transisi) {
  ikon.style.transition = transisi ? "transform .2s, opacity .2s" : "none";
  ikon.style.opacity = jarak > 0 ? Math.min(1, jarak / AMBANG) : 0;
  ikon.style.transform = `translateY(${jarak > 0 ? jarak - 50 : -60}px) rotate(${putar}deg)`;
}

addEventListener("touchstart", (e) => {
  awal = e.touches.length === 1 && standalone() && bolehTarik(e.target) ? e.touches[0].clientY : null;
  tarik = 0;
}, { passive: true });

addEventListener("touchmove", (e) => {
  if (awal === null) return;
  const dy = e.touches[0].clientY - awal;
  if (dy <= 0 || window.scrollY > 0) { awal = null; atur(0, 0, true); return; }
  if (!ikon.isConnected) document.body.appendChild(ikon);
  tarik = Math.min(dy * 0.5, AMBANG * 1.5);
  atur(tarik, tarik * 4, false);
}, { passive: true });

addEventListener("touchend", () => {
  if (awal === null) return;
  awal = null;
  if (tarik >= AMBANG) {
    atur(AMBANG, 0, true);
    ikon.animate([{ rotate: "0deg" }, { rotate: "360deg" }], { duration: 700, iterations: Infinity });
    location.reload();
  } else {
    atur(0, 0, true);
  }
});
addEventListener("touchcancel", () => { awal = null; atur(0, 0, true); });
