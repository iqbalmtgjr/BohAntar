import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

/* Pemakaian pencarian alamat hari ini. Google tidak punya batas harian untuk
   Places API (New), jadi backend menghitung dan membatasinya sendiri (lihat
   backend/maps.go, "JATAH HARIAN"). Batasnya diatur lewat PLACES_BATAS_HARIAN
   di run.sh, bukan dari sini: mengubahnya jarang, dan salah ketik di sini
   langsung jadi tagihan. */

export default function PetaPage() {
  const [data, setData] = useState(null);
  const [galat, setGalat] = useState("");

  const muat = () => {
    api.getPemakaianPeta()
      .then((res) => {
        if (res.status !== "success") return setGalat(res.error || "Gagal memuat");
        setGalat("");
        setData(res);
      })
      .catch(() => setGalat("Gagal memuat"));
  };
  useEffect(muat, []);

  const p = data?.pemakaian || {};
  const google = (p.google_autocomplete || 0) + (p.google_detail || 0);
  const batas = data?.batas_harian || 0;
  const persen = batas > 0 ? Math.min(100, Math.round((google / batas) * 100)) : 100;
  const warna = persen >= 100 ? "var(--danger)" : persen >= 80 ? "var(--warning)" : "var(--success)";

  return (
    <>
      <Topbar title="Pemakaian Peta" />
      <div className="page">
        <div className="page-header">
          <h1>Pemakaian Peta</h1>
          <p>Pencarian alamat hari ini ({p.tanggal || "-"}, WIB). Hitungan mulai dari nol tiap tengah malam dan saat backend direstart.</p>
        </div>

        {galat && <div className="card" style={{ marginBottom: 16, borderLeft: "4px solid var(--danger)" }}>{galat}</div>}

        {data && (
          <>
            <div className="card" style={{ marginBottom: 16 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
                <div className="card-title">Jatah Google hari ini</div>
                <button className="btn" onClick={muat} aria-label="Muat ulang"><RefreshCw size={16} /></button>
              </div>
              {!data.kunci_google ? (
                <p>Kunci Google belum dipasang: semua pencarian lewat Photon (gratis).</p>
              ) : (
                <>
                  <div className="stat-value" style={{ color: warna }}>{google} / {batas}</div>
                  <div style={{ height: 10, borderRadius: 5, background: "var(--border)", margin: "12px 0" }}>
                    <div style={{ width: `${persen}%`, height: "100%", borderRadius: 5, background: warna }} />
                  </div>
                  <p>
                    {persen >= 100
                      ? "Batas tercapai — pencarian memakai Photon (gratis) sampai tengah malam."
                      : `Sisa ${batas - google} panggilan sebelum pencarian pindah ke Photon.`}
                  </p>
                </>
              )}
            </div>

            <div className="stats-grid">
              {[
                { label: "Cari ke Google", value: p.google_autocomplete || 0 },
                { label: "Detail tempat ke Google", value: p.google_detail || 0 },
                { label: "Google gagal → Photon", value: p.google_gagal || 0 },
                { label: "Dilayani Photon (gratis)", value: p.photon || 0 },
              ].map((s) => (
                <div key={s.label} className="stat-card">
                  <div style={{ minWidth: 0 }}><div className="stat-value">{s.value}</div><div className="stat-label">{s.label}</div></div>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </>
  );
}
