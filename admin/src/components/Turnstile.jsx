import { useEffect, useRef } from "react";
import { BASE } from "../api";

// Kotak "bukan robot" Cloudflare Turnstile untuk form publik (login, lupa
// password, daftar mitra). Kunci situs diambil dari backend (GET /api/turnstile,
// backend/turnstile.go); kosong = fitur mati dan komponen ini tidak tampil.
// Token sekali pakai: setelah dikirim, ganti `key` komponen ini supaya widget
// dibuat ulang dan memberi token baru.
let kunci, skrip;
const ambilKunci = () => (kunci ??= fetch(`${BASE}/turnstile`)
  .then((r) => r.json())
  .then((j) => j.sitekey || "")
  .catch(() => { kunci = null; return ""; }));
const muatSkrip = () => (skrip ??= new Promise((ok, gagal) => {
  const s = document.createElement("script");
  s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
  s.async = true;
  s.onload = ok;
  s.onerror = () => { skrip = null; s.remove(); gagal(); };
  document.head.appendChild(s);
}));

export default function Turnstile({ onToken }) {
  const wadah = useRef(null);
  useEffect(() => {
    let id, batal = false;
    ambilKunci()
      .then(async (sitekey) => {
        if (!sitekey) return;
        await muatSkrip();
        if (batal) return;
        id = window.turnstile.render(wadah.current, {
          sitekey,
          language: "id",
          theme: "light", // halaman login & daftar mitra selalu terang; "auto" ikut mode gelap Windows
          callback: onToken,
          "expired-callback": () => onToken(""),
          "error-callback": () => onToken(""),
        });
      })
      .catch(() => {}); // skrip Cloudflare gagal dimuat: backend yang akan menolak dengan pesan jelas
    return () => { batal = true; if (id !== undefined) window.turnstile?.remove(id); };
  }, []);
  return <div ref={wadah} className="flex justify-center empty:hidden" />;
}
