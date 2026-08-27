import { useEffect, useState } from "react";
import { Percent, Save } from "lucide-react";
import { api } from "../api";
import Topbar from "../components/Topbar";

/* Ongkos dan bagi hasil per layanan. Angkanya dulu konstanta di dalam binary Go,
   jadi menaikkan tarif karena BBM naik menuntut build ulang dan deploy. Sekarang
   tersimpan di tabel `tarif` dan berlaku untuk pesanan berikutnya.

   Pesanan yang sudah dibuat tidak ikut berubah: komisinya dikunci di baris
   pesanan masing-masing, supaya laporan pendapatan bulan lalu tetap utuh. */

// Jarak contoh untuk pratinjau. Tanpa ini super admin tidak punya cara melihat
// akibat dari mengubah per_km selain menunggu pesanan sungguhan masuk.
const CONTOH_KM = 5;

const rupiah = (n) => "Rp " + Math.round(n || 0).toLocaleString("id-ID");

export default function TarifPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState("");
  const [pesan, setPesan] = useState(null);

  useEffect(() => {
    api.getTarif().then(d => {
      if (d.status === "success") setRows(d.tarif || []);
      setLoading(false);
    });
  }, []);

  const ubah = (layanan, field, nilai) =>
    setRows(rows.map(r => r.layanan === layanan ? { ...r, [field]: nilai, dirty: true } : r));

  const simpan = async (row) => {
    setSaving(row.layanan);
    setPesan(null);
    const res = await api.saveTarif({
      layanan: row.layanan,
      base: Number(row.base) || 0,
      per_km: Number(row.per_km) || 0,
      komisi_persen: Number(row.komisi_persen) || 0,
    });
    setSaving("");
    if (res.status === "success") {
      setRows(rows.map(r => r.layanan === row.layanan ? { ...res.tarif, dirty: false } : r));
      setPesan({ tipe: "ok", teks: `Tarif ${row.layanan} tersimpan. Berlaku untuk pesanan berikutnya.` });
    } else {
      setPesan({ tipe: "error", teks: res.error || "Gagal menyimpan tarif" });
    }
  };

  if (loading) return (<><Topbar title="Tarif & Bagi Hasil" /><div className="loading-overlay"><div className="spinner" /><p>Memuat tarif...</p></div></>);

  return (
    <>
      <Topbar title="Tarif & Bagi Hasil" />
      <div className="page">
        <div className="page-header">
          <h1>Tarif &amp; Bagi Hasil</h1>
          <p>Ongkos per layanan dan pembagian antara driver dan bohAntar</p>
        </div>

        {pesan && (
          <div className="card" style={{ marginBottom: 16, borderLeft: `4px solid ${pesan.tipe === "ok" ? "var(--success)" : "var(--danger, #EF4444)"}` }}>
            {pesan.teks}
          </div>
        )}

        <div className="card">
          <div className="card-title" style={{ marginBottom: 16 }}>Daftar Layanan</div>
          <table style={{ width: "100%" }}>
            <thead>
              <tr>
                <th>Layanan</th>
                <th>Buka Pintu</th>
                <th>Per Km</th>
                <th>Komisi bohAntar</th>
                <th>Contoh {CONTOH_KM} km</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? (
                <tr>
                  <td colSpan={6}>
                    <div className="empty-state">
                      <div className="icon" style={{ display: "flex", justifyContent: "center", marginBottom: 12 }}>
                        <Percent size={40} style={{ color: "var(--text-muted)", opacity: 0.5 }} />
                      </div>
                      <h3>Belum ada tarif</h3>
                      <p>Tabel tarif diisi otomatis saat backend dijalankan</p>
                    </div>
                  </td>
                </tr>
              ) : rows.map(r => {
                const base = Number(r.base) || 0;
                const perKm = Number(r.per_km) || 0;
                const persen = Number(r.komisi_persen) || 0;
                // Rumus ini harus sama dengan hitungTarif() di backend/tarif.go
                // dan penaksir di aplikasi Flutter.
                const contoh = Math.round((base + CONTOH_KM * perKm) / 100) * 100;
                const komisi = Math.round(contoh * persen / 100);
                const bagianDriver = contoh - komisi;
                return (
                  <tr key={r.layanan}>
                    <td data-label="Layanan" style={{ fontWeight: 700 }}>{r.layanan}</td>
                    <td data-label="Buka Pintu">
                      <input
                        type="number" min="0" step="500" value={r.base}
                        onChange={e => ubah(r.layanan, "base", e.target.value)}
                        style={{ width: 110 }}
                      />
                    </td>
                    <td data-label="Per Km">
                      <input
                        type="number" min="0" step="100" value={r.per_km}
                        onChange={e => ubah(r.layanan, "per_km", e.target.value)}
                        style={{ width: 110 }}
                      />
                    </td>
                    <td data-label="Komisi">
                      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                        <input
                          type="number" min="0" max="100" step="1" value={r.komisi_persen}
                          onChange={e => ubah(r.layanan, "komisi_persen", e.target.value)}
                          style={{ width: 80 }}
                        />
                        <span style={{ color: "var(--text-muted)" }}>%</span>
                      </div>
                    </td>
                    <td data-label={`Contoh ${CONTOH_KM} km`}>
                      <div style={{ fontWeight: 700 }}>{rupiah(contoh)}</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)" }}>
                        driver {rupiah(bagianDriver)} &middot; bohAntar {rupiah(komisi)}
                      </div>
                    </td>
                    <td data-label="">
                      <button
                        className="btn btn-primary"
                        disabled={!r.dirty || saving === r.layanan}
                        onClick={() => simpan(r)}
                        style={{ display: "flex", alignItems: "center", gap: 6 }}
                      >
                        <Save size={15} />
                        {saving === r.layanan ? "Menyimpan..." : "Simpan"}
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <div className="card" style={{ marginTop: 16, color: "var(--text-secondary)", fontSize: 13, lineHeight: 1.7 }}>
          <strong>Cara angkanya bekerja</strong>
          <div>Ongkos = buka pintu + (jarak km &times; tarif per km), dibulatkan ke ratusan terdekat.</div>
          <div>Komisi dipotong dari ongkos, bukan ditambahkan di atasnya — penumpang membayar angka yang sama, driver menerima sisanya.</div>
          <div>Perubahan hanya berlaku untuk pesanan baru. Pesanan yang sudah berjalan memakai komisi yang terkunci saat dibuat.</div>
        </div>
      </div>
    </>
  );
}
