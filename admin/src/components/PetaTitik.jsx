import { useEffect, useRef } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";

// Titik bawaan sebelum warung punya lokasi: pusat kota Sintang.
const SINTANG = [-0.0784, 111.4933];

/* Pemilih titik: pin diam di tengah, petanya yang digeser — pola yang sama
   dengan aplikasi (_PetaPilihTitik) dan lebih mudah di layar sentuh daripada
   menyeret penanda kecil. Tanpa ikon penanda Leaflet, jadi tidak ada berkas
   gambar yang perlu dibundel. */
export default function PetaTitik({ lat, lng, onChange, tinggi = 260 }) {
  const wadah = useRef(null);
  const peta = useRef(null);
  const ubah = useRef(onChange);
  ubah.current = onChange;

  useEffect(() => {
    const ada = Number(lat) && Number(lng);
    const m = L.map(wadah.current, { zoomControl: true, attributionControl: true })
      .setView(ada ? [Number(lat), Number(lng)] : SINTANG, ada ? 17 : 14);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: "© OpenStreetMap"
    }).addTo(m);
    m.on("moveend", () => {
      const c = m.getCenter();
      ubah.current(c.lat.toFixed(6), c.lng.toFixed(6));
    });
    peta.current = m;
    return () => m.remove();
    // Peta dibuat sekali; perpindahan dari luar ditangani efek di bawah.
  }, []);

  // Titik dari luar (tombol "Gunakan lokasi saya") memindahkan peta.
  useEffect(() => {
    const m = peta.current;
    if (!m || !Number(lat) || !Number(lng)) return;
    const c = m.getCenter();
    if (Math.abs(c.lat - lat) > 1e-6 || Math.abs(c.lng - lng) > 1e-6) {
      m.setView([Number(lat), Number(lng)], Math.max(m.getZoom(), 17));
    }
  }, [lat, lng]);

  return (
    <div style={{ position: "relative", height: tinggi, borderRadius: 12, overflow: "hidden", border: "1px solid var(--border)" }}>
      <div ref={wadah} style={{ position: "absolute", inset: 0 }} />
      {/* Ujung pin tepat di pusat peta. */}
      <svg
        viewBox="0 0 24 36" width="30" height="45" aria-hidden="true"
        style={{ position: "absolute", left: "50%", top: "50%", transform: "translate(-50%, -100%)", zIndex: 500, pointerEvents: "none", filter: "drop-shadow(0 3px 3px rgba(0,0,0,0.35))" }}
      >
        <path d="M12 0C5.4 0 0 5.4 0 12c0 9 12 24 12 24s12-15 12-24C24 5.4 18.6 0 12 0z" fill="#EF4444" />
        <circle cx="12" cy="12" r="4.5" fill="#fff" />
      </svg>
    </div>
  );
}
