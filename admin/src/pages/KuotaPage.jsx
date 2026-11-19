import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

/* Jatah harian layanan pihak ketiga yang gratis/terbatas (backend/email.go,
   adminKuotaHandler). Batas Google diatur lewat PLACES_BATAS_HARIAN di run.sh,
   bukan dari sini: salah ketik di sini langsung jadi tagihan. Batas Brevo 300
   ditetapkan Brevo sendiri (paket gratis). */

function Bilah({ pakai, batas }) {
  const persen = batas > 0 ? Math.min(100, Math.round((pakai / batas) * 100)) : 100;
  const warna = persen >= 100 ? "var(--danger)" : persen >= 80 ? "var(--warning)" : "var(--success)";
  return (
    <>
      <div className="stat-value" style={{ color: warna }}>{pakai} / {batas}</div>
      <div style={{ height: 10, borderRadius: 5, background: "var(--border)", margin: "12px 0" }}>
        <div style={{ width: `${persen}%`, height: "100%", borderRadius: 5, background: warna }} />
      </div>
    </>
  );
}

function Angka({ isi }) {
  return (
    <div className="stats-grid" style={{ marginBottom: 24 }}>
      {isi.map((s) => (
        <div key={s.label} className="stat-card">
          <div style={{ minWidth: 0 }}><div className="stat-value">{s.value}</div><div className="stat-label">{s.label}</div></div>
        </div>
      ))}
    </div>
  );
}

export default function KuotaPage() {
  const [data, setData] = useState(null);
  const [galat, setGalat] = useState("");

  const muat = () => {
    api.getKuota()
      .then((res) => {
        if (res.status !== "success") return setGalat(res.error || "Gagal memuat");
        setGalat("");
        setData(res);
      })
      .catch(() => setGalat("Gagal memuat"));
  };
  useEffect(muat, []);

  const peta = data?.peta || {};
  const p = peta.pemakaian || {};
  const google = (p.google_autocomplete || 0) + (p.google_detail || 0);
  const batasPeta = peta.batas_harian || 0;

  const email = data?.email || {};
  const e = email.pemakaian || {};
  const batasEmail = email.batas_harian || 300;
  const dariBrevo = email.sisa_brevo >= 0;
  // Sisa dari Brevo mencakup semua kiriman akun (termasuk aplikasi lain dan
  // sebelum restart), jadi lebih jujur daripada hitungan backend sendiri.
  const pakaiEmail = dariBrevo ? Math.max(0, batasEmail - Math.round(email.sisa_brevo)) : (e.terkirim || 0);
  const paketGratis = !dariBrevo || email.paket_brevo === "free";

  return (
    <>
      <Topbar title="Kuota Layanan" />
      <div className="page">
        <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
          <div>
            <h1>Kuota Layanan</h1>
            <p>Jatah harian layanan luar hari ini ({p.tanggal || e.tanggal || "-"}, WIB). Hitungan backend mulai dari nol tiap tengah malam dan saat backend direstart.</p>
          </div>
          <button className="btn" onClick={muat} aria-label="Muat ulang"><RefreshCw size={16} /></button>
        </div>

        {galat && <div className="card" style={{ marginBottom: 16, borderLeft: "4px solid var(--danger)" }}>{galat}</div>}

        {data && (
          <>
            <div className="card" style={{ marginBottom: 16 }}>
              <div className="card-title">Pencarian alamat — Google Places</div>
              {!peta.kunci_google ? (
                <p>Kunci Google belum dipasang: semua pencarian lewat Photon (gratis).</p>
              ) : (
                <>
                  <Bilah pakai={google} batas={batasPeta} />
                  <p>
                    {google >= batasPeta
                      ? "Batas tercapai — pencarian memakai Photon (gratis) sampai tengah malam."
                      : `Sisa ${batasPeta - google} panggilan sebelum pencarian pindah ke Photon.`}
                  </p>
                </>
              )}
            </div>
            <Angka isi={[
              { label: "Cari ke Google", value: p.google_autocomplete || 0 },
              { label: "Detail tempat ke Google", value: p.google_detail || 0 },
              { label: "Google gagal → Photon", value: p.google_gagal || 0 },
              { label: "Dilayani Photon (gratis)", value: p.photon || 0 },
            ]} />

            <div className="card" style={{ marginBottom: 16 }}>
              <div className="card-title">Email — Brevo</div>
              {!email.aktif ? (
                <p>SMTP belum dipasang: tidak ada email yang dikirim (lupa password, kode daftar, notif admin).</p>
              ) : !paketGratis ? (
                <p>Paket Brevo berbayar ({email.paket_brevo}): sisa {Math.round(email.sisa_brevo)} kredit email.</p>
              ) : (
                <>
                  <Bilah pakai={pakaiEmail} batas={batasEmail} />
                  <p>
                    {pakaiEmail >= batasEmail
                      ? "Jatah habis — email lupa password, kode daftar, dan notif admin tertolak sampai Brevo mereset jatah besok."
                      : `Sisa ${batasEmail - pakaiEmail} email hari ini (paket gratis Brevo, 300/hari, sisa tidak terbawa ke besok).`}
                  </p>
                  <p className="stat-label">
                    {dariBrevo
                      ? "Angka dari akun Brevo, termasuk kiriman aplikasi lain di akun yang sama."
                      : "Angka dari hitungan backend saja. Isi BREVO_API_KEY di run.sh agar angkanya diambil dari Brevo."}
                  </p>
                </>
              )}
            </div>
            {email.aktif && (
              <Angka isi={[
                { label: "Terkirim dari BohAntar", value: e.terkirim || 0 },
                { label: "Gagal dikirim", value: e.gagal || 0 },
              ]} />
            )}
          </>
        )}
      </div>
    </>
  );
}
